package Plugins::Spotty::API::AsyncRequest;

=pod
	This class extends Slim::Networking::SimpleAsyncHTTP to add PUT support,
	and deal with the 429 error (rate limiting) on LMS before 8.5.1.

	Unfortunately the only method we'd need to override (onError) is not a class
	method. Therefore we have to duplicate _createHTTPRequest, too.
=cut

use strict;

use base qw(Slim::Networking::SimpleAsyncHTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use HTTP::Date ();
use HTTP::Request;

my $prefs = preferences('server');

my $log = logger('network.asynchttp');

# SPOTTY
my $spottyLog = logger('plugin.spotty');
# /SPOTTY


sub put { shift->_createHTTPRequest( PUT => @_ ) }

# Parameters are passed to Net::HTTP::NB::formatRequest, meaning you
# can override default headers, and pass in content.
# Examples:
# $http->post("www.somewhere.net", 'conent goes here');
# $http->post("www.somewhere.net", 'Content-Type' => 'application/x-foo', 'Other-Header' => 'Other Value', 'conent goes here');
sub _createHTTPRequest {
	my $self = shift;
	my $type = shift;
	my $url  = shift;

	$self->type( $type );
	$self->url( $url );

	my $params = $self->_params;
	my $client = $params->{params}->{client};

	main::DEBUGLOG && $log->debug("${type}ing $url");

	# Check for cached response
	if ( $params->{cache} ) {

		my $cache = Slim::Utils::Cache->new();

		if ( my $data = $cache->get( Slim::Networking::SimpleAsyncHTTP::_cacheKey($url, $client) ) ) {
			$self->cachedResponse( $data );

# SPOTTY - specific change starts here
#			# If the data was cached within the past 5 minutes,
#			# return it immediately without revalidation, to improve
#			# UI experience
#			if ( $data->{_no_revalidate} || time - $data->{_time} < 300 ) {
#
#			if we got a 304 (data not change) on the first of a series of requests, return
#			cached follow up requests without re-validation
			if ( delete $params->{no_revalidate} ) {

				main::INFOLOG && $spottyLog->is_info && $spottyLog->info("Using cached response [$url]");
# /SPOTTY

				return $self->sendCachedResponse();
			}
		}
	}

	my $timeout
		=  $params->{Timeout}
		|| $params->{timeout}
		|| $prefs->get('remotestreamtimeout');

	my $request = HTTP::Request->new( $type => $url );

	if ( @_ % 2 ) {
		$request->content( pop @_ );
	}

	# If cached, add If-None-Match and If-Modified-Since headers
	my $data = $self->cachedResponse;
	if ( $data && ref $data && $data->{headers} ) {
		# gzip encoded results come with a -gzip postfix which needs to be removed, or the etag would not match
		my $etag = $data->{headers}->header('ETag') || undef;
		$etag =~ s/-gzip// if $etag;

		# if the last_modified value is a UNIX timestamp, convert it
		my $lastModified = $data->{headers}->last_modified || undef;
		$lastModified = HTTP::Date::time2str($lastModified) if $lastModified && $lastModified !~ /\D/;

		unshift @_, (
			'If-None-Match'     => $etag,
			'If-Modified-Since' => $lastModified
		);
	}

	# request compressed data if we have zlib
	if ( Slim::Networking::SimpleAsyncHTTP::hasZlib() && !$params->{saveAs} ) {
		unshift @_, (
			'Accept-Encoding' => 'deflate, gzip', # deflate is less overhead than gzip
		);
	}

	# Add Accept-Language header
	my $lang;
	if ( $client ) {
		$lang = $client->languageOverride(); # override from comet request
	}

	$lang ||= $prefs->get('language') || 'en';
	$lang =~ s/_/-/g;

	unshift @_, (
		'Accept-Language' => lc($lang),
	);

	if ( @_ ) {
		$request->header( @_ );
	}

	my $http = Slim::Networking::Async::HTTP->new;
	$http->send_request( {
		request     => $request,
		maxRedirect => $params->{maxRedirect},
		saveAs      => $params->{saveAs},
		Timeout     => $timeout,
		onError     => \&onError,
		onBody      => \&Slim::Networking::SimpleAsyncHTTP::onBody,
		passthrough => [ $self ],
	} );
}


sub onError {
	my ( $http, $error, $self ) = @_;

	my $uri = $http->request->uri;

	# If we have a cached copy of this request, we can use it
	if ( $self->cachedResponse ) {

		$log->warn("Failed to connect to $uri, using cached copy. ($error)");

		# SPOTTY-NG (Phase 2.6, plan 04 / HARDEN-06): note — the cached-response branch
		# delegates to $self->sendCachedResponse(), which itself is overridden in this
		# file to call _spottyNgDecCounters. We therefore do NOT decrement counters
		# here directly; doing so would double-decrement. The override is responsible
		# for the counter accounting on this path.
		return $self->sendCachedResponse();
	}
	else {
		$log->warn("Failed to connect to $uri ($error)");
	}

	$self->error( $error );

	main::PERFMON && (my $now = AnyEvent->time);

	# SPOTTY-NG (Phase 2.6, plan 04 / HARDEN-06 / closes 02-REVIEW.md WR-03): emit RES log
	# line + decrement plugin-global and per-pipeline inflight counters BEFORE invoking
	# the user error-callback. Pre-fix legacy onError dispatched directly to $self->ecb,
	# leaving _spottyNgGlobalInflight monotonically incremented (since _callOneShot
	# always increments at REQ time). The completion path (onBody) is NOT wrapped here —
	# see the file's docstring above for why; the partial fix gives correct counter
	# values on every error case, which is the case where the leak was fastest.
	_spottyNgEmitRes($http, $error, $http->response);
	_spottyNgDecCounters($http);

	# return the response object in addition to the standard values from SimpleAsyncHTTP
	# SPOTTY
	$self->ecb->( $self, $error, $http->response );
	# /SPOTTY

	main::PERFMON && $now && Slim::Utils::PerfMon->check('async', AnyEvent->time - $now, undef, $self->ecb);

	return;
}

# if we send a cached response, tell the callback about it
# SPOTTY
sub sendCachedResponse {
	my $self = shift;

	$self->cachedResponse->{headers}->{'x-spotty-cached-response'} = 1;

	# SPOTTY-NG (Phase 2.6, plan 04 / HARDEN-06): decrement counters before delegating
	# to SUPER — this closes the cached-response success branch which would otherwise
	# leak counters monotonically (REQ was incremented at _callOneShot time; without
	# this dec, the cached response never balances the increment). $self IS-A
	# Slim::Networking::SimpleAsyncHTTP so $self->_params is the correct accessor for
	# the SPOTTY-NG correlation params stashed at issue time.
	_spottyNgDecCounters($self);

	$self->SUPER::sendCachedResponse();

	return;
}
# /SPOTTY


# SPOTTY-NG instrumentation (Phase 1, plan 04 / D-09 — mirror of AsyncRequest.pm).
# Dead code on Lyrion 8.5.1+ (which uses the modern AsyncRequest.pm). Kept text-equivalent
# to the modern implementation so the upstream PR diff is symmetric.
#
# SPOTTY-NG (Phase 2.6, plan 04 / HARDEN-06 / closes 02-REVIEW.md WR-03 — partial): the
# `onError` callback path AND the `sendCachedResponse` override in this file ARE wrapped —
# they directly invoke `_spottyNgEmitRes` and `_spottyNgDecCounters` before dispatching
# downstream. This restores counter balance on the legacy LMS path (<8.5.1) for both
# error branches (network failure, HTTP-error response with no cached fallback) AND for
# the cached-response success branch.
#
# KNOWN GAP: the network-success `onBody` path is NOT wrapped — that's a SUPER::-class
# method invoked from `Slim::Networking::Async::HTTP::send_request`, and wrapping it
# without rewriting `Slim::Networking::SimpleAsyncHTTP::onBody` is impractical. Per
# WR-03 review note ("simplest fix is `onError` + `sendCachedResponse`; the success
# path is harder; document the gap if you can't close it"), this partial coverage is
# the accepted scope for Phase 2.6. On modern LMS (this dev box, 9.2.0) this file is
# not loaded at all, so the gap has zero runtime impact in the v1 milestone. Phase 3
# daily-use validation may surface whether the legacy success-path leak is reachable;
# if so, a follow-up patch can rewrap onBody. See 01-04-SUMMARY.md for the original
# wiring outcome.

use POSIX qw(strftime);
use Time::HiRes ();

# SPOTTY-NG (Phase 2.6, plan 04 / HARDEN-15 / closes 02-REVIEW.md IN-07): the function body
# of `_spottyNgEmitRes` below is byte-equivalent to AsyncRequest.pm's `_spottyNgEmitRes`
# (modulo the inherent `$log` vs `$spottyLog` lexical and whitespace differences). Verify
# with: awk '/^sub _spottyNgEmitRes /,/^}/' on each file, normalize $spottyLog → $log in
# the legacy extract, then diff — non-whitespace diff should be empty.
sub _spottyNgEmitRes {
	my ($http, $errStr, $maybeResponse) = @_;

	return unless main::DEBUGLOG && $spottyLog->is_debug;

	# Pull the SPOTTY-NG correlation fields stashed at issue time (plan 03).
	my $params      = $http->_params || {};
	my $issuedAt    = $params->{_spottyNgIssuedAt} || 0;
	my $pipeId      = $params->{_spottyNgPipeId}   || '--------';
	my $pipe        = $params->{_spottyNgPipe};
	my $perPipe     = (ref $pipe && $pipe->can('_inflight')) ? $pipe->_inflight : 0;
	my $global      = Plugins::Spotty::API::_spottyNgGlobalInflight();

	# dt in ms, computed against high-res clock (Time::HiRes is core perl).
	my $now    = int(Time::HiRes::time() * 1000);
	my $dtMs   = $issuedAt ? ($now - $issuedAt) : 0;

	# status: from $http->code on the success path; on the error path
	# ($http->code unpopulated) fall back to $maybeResponse->code (HTTP::Response
	# passed by Slim::Networking::SimpleAsyncHTTP::onError as the third callback
	# arg) and finally to a leading 3-digit token in $errStr.
	# SPOTTY-NG (Phase 2, plan 03 / D-13 / FIX-12) — closes Phase 1 SC4 instrumentation gap.
	my $code = eval { $http->code };
	if (!defined $code || !$code) {
		$code = eval { $maybeResponse && $maybeResponse->code };
	}
	if ((!defined $code || !$code) && defined $errStr && $errStr =~ /^(\d{3})\b/) {
		$code = $1;
	}
	my $status = (defined $code && $code) ? $code : (defined $errStr ? 'ERR' : 'unknown');

	# Retry-After header — present on 429 (rate limit) and may be absent on 403/410.
	# On error path, $http->headers is empty; use $maybeResponse->headers as fallback.
	# SPOTTY-NG (Phase 2, plan 03 / D-13 / FIX-12) — same gap close as $status above.
	my $retryAfter = '-';
	my $headers = eval { $http->headers } || eval { $maybeResponse && $maybeResponse->headers };
	if ($headers) {
		my $ra = $headers->header('Retry-After');
		$retryAfter = $ra if defined $ra && $ra ne '';
	}

	# Body capture: first 2KB on non-2xx, omitted on 2xx (D-12). Don't dump huge JSON arrays.
	my $bodyField = '<omitted>';
	my $isSuccess = (defined $status && $status =~ /^2\d\d$/);
	if (!$isSuccess) {
		my $contentRef = eval { $http->contentRef };
		my $bodyLen    = $contentRef ? length($$contentRef) : 0;
		if ($bodyLen > 0) {
			my $excerpt = substr($$contentRef, 0, 2048);
			# Strip control chars except space/tab to keep the log line readable.
			$excerpt =~ s/[\x00-\x08\x0A-\x1F\x7F]/./g;
			$bodyField = $excerpt . ($bodyLen > 2048 ? sprintf(' ... [truncated, body=%d bytes total]', $bodyLen) : '');
		}
		elsif (defined $errStr) {
			$bodyField = "<error: $errStr>";
		}
	}

	my $ts = strftime('%Y-%m-%dT%H:%M:%S', localtime) . sprintf('.%03dZ', $now % 1000);

	# Format per D-16 — exact line schema for greppability.
	$spottyLog->debug(sprintf('[%s] [SPOTTY-NG pipe=%s inflight=%d/%d dt=%dms] RES %s retry_after=%s body=%s',
		$ts, $pipeId, $perPipe, $global, $dtMs, $status, $retryAfter, $bodyField));
}

sub _spottyNgDecCounters {
	my ($http) = @_;
	Plugins::Spotty::API::_spottyNgDecGlobalInflight();
	my $params = $http->_params || {};
	my $pipe   = $params->{_spottyNgPipe};
	if (ref $pipe && $pipe->can('_inflight')) {
		my $cur = $pipe->_inflight || 0;
		$pipe->_inflight($cur > 0 ? $cur - 1 : 0);
	}
}


1;
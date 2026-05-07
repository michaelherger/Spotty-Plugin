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

		return $self->sendCachedResponse();
	}
	else {
		$log->warn("Failed to connect to $uri ($error)");
	}

	$self->error( $error );

	main::PERFMON && (my $now = AnyEvent->time);

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

	$self->SUPER::sendCachedResponse();

	return;
}
# /SPOTTY


# SPOTTY-NG instrumentation (Phase 1, plan 04 / D-09 — mirror of AsyncRequest.pm).
# Dead code on Lyrion 8.5.1+ (which uses the modern AsyncRequest.pm). Kept text-equivalent
# to the modern implementation so the upstream PR diff is symmetric. Wiring outcome:
# FALLBACK — helper subs added below; the legacy onError/onBody callback dispatch is NOT
# wrapped, because doing so requires rewriting Slim::Networking::SimpleAsyncHTTP::onBody
# (a SUPER::-class method invoked by Slim::Networking::Async::HTTP::send_request, not a
# closure we can swap). On modern LMS this file is not loaded at all, so the gap has zero
# runtime impact on the dev box. See 01-04-SUMMARY.md for the recorded outcome.

use POSIX qw(strftime);
use Time::HiRes ();

sub _spottyNgEmitRes {
	my ($http, $errStr, $maybeResponse) = @_;
	return unless main::DEBUGLOG && $spottyLog->is_debug;
	my $params      = $http->_params || {};
	my $issuedAt    = $params->{_spottyNgIssuedAt} || 0;
	my $pipeId      = $params->{_spottyNgPipeId}   || '--------';
	my $pipe        = $params->{_spottyNgPipe};
	my $perPipe     = (ref $pipe && $pipe->can('_inflight')) ? $pipe->_inflight : 0;
	my $global      = Plugins::Spotty::API::_spottyNgGlobalInflight();
	my $now         = int(Time::HiRes::time() * 1000);
	my $dtMs        = $issuedAt ? ($now - $issuedAt) : 0;
	# status: from $http->code on the success path; on the error path
	# ($http->code unpopulated) fall back to $maybeResponse->code (HTTP::Response
	# passed by Slim::Networking::SimpleAsyncHTTP::onError as the third callback
	# arg) and finally to a leading 3-digit token in $errStr.
	# SPOTTY-NG (Phase 2, plan 03 / D-13 / FIX-12 / mirror of AsyncRequest.pm per FIX-06).
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
	# SPOTTY-NG (Phase 2, plan 03 / D-13 / FIX-12 / mirror of AsyncRequest.pm per FIX-06).
	my $retryAfter = '-';
	my $headers = eval { $http->headers } || eval { $maybeResponse && $maybeResponse->headers };
	if ($headers) {
		my $ra = $headers->header('Retry-After');
		$retryAfter = $ra if defined $ra && $ra ne '';
	}
	my $bodyField = '<omitted>';
	my $isSuccess = (defined $status && $status =~ /^2\d\d$/);
	if (!$isSuccess) {
		my $contentRef = eval { $http->contentRef };
		my $bodyLen    = $contentRef ? length($$contentRef) : 0;
		if ($bodyLen > 0) {
			my $excerpt = substr($$contentRef, 0, 2048);
			$excerpt =~ s/[\x00-\x08\x0A-\x1F\x7F]/./g;
			$bodyField = $excerpt . ($bodyLen > 2048 ? sprintf(' ... [truncated, body=%d bytes total]', $bodyLen) : '');
		}
		elsif (defined $errStr) {
			$bodyField = "<error: $errStr>";
		}
	}
	my $ts = strftime('%Y-%m-%dT%H:%M:%S', localtime) . sprintf('.%03dZ', $now % 1000);
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
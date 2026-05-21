package Plugins::Spotty::API::AsyncRequest;

=pod
	This class extends Slim::Networking::SimpleAsyncHTTP to deal with the 429 error (rate limiting).
	It requires LMS 8.5.1 or newer.

	Additions for debug-level request/response tracing:
	  - The constructor wraps onComplete/onError to emit a RES log line at DEBUG level,
	    paired with the REQ line (emitted by API::_call) via params->{_pipeId}.
	  - On non-2xx responses the first 2KB of the body is included for 429/403/410/401 disambiguation.
	  - The plugin-global inflight counter (declared in API.pm) is decremented here.
	  - The per-Pipeline inflight counter (declared in Pipeline.pm) is decremented here as well.
	  - Mirror this implementation in AsyncRequestLegacy.pm — kept symmetric for upstream
	    PR mergeability even though legacy is dead code on Lyrion 9.2.0.
=cut

use strict;

use base qw(Slim::Networking::SimpleAsyncHTTP);

use POSIX qw(strftime);
use Time::HiRes ();

use Slim::Utils::Log;

my $log = logger('plugin.spotty');

sub new {
	my ($class, $onComplete, $onError, $params) = @_;

	# Wrap callbacks to emit a RES trace line + decrement inflight counters before delegating.
	my $wrappedComplete = sub {
		my $http = shift;
		_emitResLog($http, undef, undef);
		_decInflightCounters($http);
		$onComplete->($http, @_);
	};
	my $wrappedError = sub {
		my ($http, $err, $maybeResponse) = @_;
		_emitResLog($http, $err, $maybeResponse);
		_decInflightCounters($http);
		$onError->($http, $err, $maybeResponse);
	};

	my $self = $class->SUPER::new($wrappedComplete, $wrappedError, $params);
	return $self;
}

sub shouldNotRevalidate {
	my ($self, $data) = @_;
	return delete $self->_params->{no_revalidate};
}

# if we send a cached response, tell the callback about it
sub sendCachedResponse {
	my $self = shift;

	$self->cachedResponse->{headers}->{'x-spotty-cached-response'} = 1;

	$self->SUPER::sendCachedResponse();

	return;
}

# Emit the per-response RES trace line. NOT a class method by design —
# called from the wrapped callback closures. Always guarded by main::DEBUGLOG && $log->is_debug.
# Function body must remain byte-equivalent to AsyncRequestLegacy.pm's _emitResLog
# (modulo the $log vs $spottyLog lexical difference). Verify with:
#   awk '/^sub _emitResLog /,/^}/' AsyncRequest.pm AsyncRequestLegacy.pm | diff
sub _emitResLog {
	my ($http, $errStr, $maybeResponse) = @_;

	return unless main::DEBUGLOG && $log->is_debug;

	# Pull the correlation fields stashed at issue time by API::_call.
	my $params      = $http->_params || {};
	my $issuedAt    = $params->{_issuedAt} || 0;
	my $pipeId      = $params->{_pipeId}   || '--------';
	my $pipe        = $params->{_pipe};
	my $perPipe     = (ref $pipe && $pipe->can('_inflight')) ? $pipe->_inflight : 0;
	my $global      = Plugins::Spotty::API::_globalInflight();

	# dt in ms, computed against high-res clock (Time::HiRes is core perl).
	my $now    = int(Time::HiRes::time() * 1000);
	my $dtMs   = $issuedAt ? ($now - $issuedAt) : 0;

	# status: from $http->code on the success path; on the error path
	# ($http->code unpopulated) fall back to $maybeResponse->code (HTTP::Response
	# passed by Slim::Networking::SimpleAsyncHTTP::onError as the third callback
	# arg) and finally to a leading 3-digit token in $errStr.
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
	my $retryAfter = '-';
	my $headers = eval { $http->headers } || eval { $maybeResponse && $maybeResponse->headers };
	if ($headers) {
		my $ra = $headers->header('Retry-After');
		$retryAfter = $ra if defined $ra && $ra ne '';
	}

	# Body capture: first 2KB on non-2xx, omitted on 2xx. Don't dump huge JSON arrays.
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

	$log->debug(sprintf('[%s] [spotty pipe=%s inflight=%d/%d dt=%dms] RES %s retry_after=%s body=%s',
		$ts, $pipeId, $perPipe, $global, $dtMs, $status, $retryAfter, $bodyField));
}

# Decrement inflight counters exactly once per response (paired with _call's increments).
sub _decInflightCounters {
	my ($http) = @_;
	Plugins::Spotty::API::_decGlobalInflight();
	my $params = $http->_params || {};
	my $pipe   = $params->{_pipe};
	if (ref $pipe && $pipe->can('_inflight')) {
		my $cur = $pipe->_inflight || 0;
		$pipe->_inflight($cur > 0 ? $cur - 1 : 0);
	}
}

1;

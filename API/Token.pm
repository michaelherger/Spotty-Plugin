package Plugins::Spotty::API::Token;

use strict;

use File::Slurp;
# use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Spotty::API::Cache;
use Plugins::Spotty::Plugin;

# override the scope list hard-coded in to the spotty helper application
use constant SPOTIFY_SCOPE => join(',', qw(
  playlist-modify-private
  playlist-modify-public
  playlist-read-collaborative
  playlist-read-private
  user-follow-modify
  user-follow-read
  user-library-modify
  user-library-read
  user-modify-playback-state
  user-read-playback-state
  user-read-private
  user-read-recently-played
  user-top-read
));

use constant DEFAULT_EXPIRATION => 3600;

my $cache = Slim::Utils::Cache->new();
my $spottyCache = Plugins::Spotty::API::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

my %callbacks;

sub _callCallbacks {
	my ($token, $refreshToken) = @_;

	foreach (@{$callbacks{$refreshToken} || []}) {
		$_->($token);
	}
	delete $callbacks{$refreshToken};
}

sub _gotTokenInfo {
	my ($result, $userId, $args) = @_;

	return unless $result && ref $result eq 'HASH';

	my $accessToken = $result->{access_token};
	if ($accessToken) {
		my $expiresIn = $result->{expires_in} || 3600;

		main::INFOLOG && $log->is_info && $log->info("Refreshed access token for user: $userId");

		# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — propagate flavor from $args into the cache writers.
		__PACKAGE__->cacheAccessToken($args->{code}, $userId, $accessToken, $expiresIn, $args->{flavor});
		__PACKAGE__->cacheRefreshToken($args->{code}, $userId, $result->{refresh_token}, $args->{flavor}) if $result->{refresh_token};
	}

	$log->error("Failed to refresh access token: " . ($result->{error} || 'Unknown error')) if $result->{error} || !$result->{access_token};

	return $accessToken;
}

my $startupTime = time();
# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor-aware access-token cache key.
# Backward-compat: callers omitting the third arg get $flavor='own', producing the
# same key shape as before plus an `_own` suffix; existing cached entries (no suffix)
# fall through to a refresh on first read after upgrade — graceful migration.
sub _getATCacheKey {
	my ($code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	return join('_', 'spotty_access_token', $startupTime,
	                 $code || $prefs->get('iconCode'),
	                 Slim::Utils::Unicode::utf8toLatin1Transliterate($userId),
	                 $flavor);
}

# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor-aware refresh-token cache key.
# Same backward-compat pattern as _getATCacheKey above.
sub _getRTCacheKey {
	my ($code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	return join('_', 'spotty_refresh_token',
	                 $code || $prefs->get('iconCode'),
	                 Slim::Utils::Unicode::utf8toLatin1Transliterate($userId),
	                 $flavor);
}

# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor-aware access-token cache writer.
sub cacheAccessToken {
	my ($class, $code, $userId, $token, $expiration, $flavor) = @_;
	$flavor ||= 'own';
	$expiration ||= DEFAULT_EXPIRATION;

	my $cacheKey = _getATCacheKey($code, $userId, $flavor);

	$expiration = $expiration > 600 ? ($expiration - 300) : $expiration;

	main::INFOLOG && $log->is_info && $log->info("Caching access token for $userId (flavor=$flavor) for $expiration seconds.");

	$cache->set($cacheKey, $token, $expiration);
}

# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor-aware refresh-token cache writer.
sub cacheRefreshToken {
	my ($class, $code, $userId, $token, $flavor) = @_;
	$flavor ||= 'own';
	main::INFOLOG && $log->is_info && $log->info("Caching refresh token for $userId (flavor=$flavor).");
	$spottyCache->set(_getRTCacheKey($code, $userId, $flavor), $token) if $token;
}

# singleton shortcut to the main class
sub get {
	my ($class, $api, $cb, $args) = @_;
	$args ||= {};

	# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor extraction and bundled-code resolution.
	my $flavor = $args->{flavor} || 'own';
	$args->{flavor} = $flavor;   # normalize back into $args so _gotTokenInfo sees it

	my $userId = $args->{userId} || ($api && $api->userId);
	Slim::Utils::Log::logBacktrace("No userId found") if !$userId;
	$userId ||= (main::SCANNER ? '_scanner' : 'generic');

	# SPOTTY-NG: under bundled flavor, derive $code from the bundled icon basename when caller
	# didn't pass one. Caller may still pass an explicit code to override — preserves test ergonomics.
	my $code = $args->{code};
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}
	$args->{code} = $code if $code;   # normalize into $args so _gotTokenInfo writes under same code

	my $atCacheKey = _getATCacheKey($code, $userId, $flavor);

	if (my $token = $cache->get($atCacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Found cached access token (flavor=$flavor)");
		return $cb ? $cb->($token) : $token;
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("Didn't find cached token. Need to refresh. $userId");
	}

	my $rtCacheKey = _getRTCacheKey($code, $userId, $flavor);
	# temporary fallback code: from global to app own cache
	my $refreshToken = $spottyCache->get($rtCacheKey) || $cache->get($rtCacheKey);

	if (main::SCANNER) {
		# Synchronous path — UNTOUCHED per D-16 / FIX-07. Bit-preserved from the pre-patch state:
		# the scanner branch does NOT participate in the flavor extension in this phase.
		my $tokenInfo = Plugins::Spotty::API::Sync->refreshToken(
			{ refreshToken => $refreshToken }
		);

		return _gotTokenInfo($tokenInfo, $userId, $args);
	}
	else {
		if (!$refreshToken) {
			$log->error("No refresh token found - can't refresh access token. user=$userId flavor=$flavor");
			$cb->() if $cb;
			return;
		}

		if ($cb) {
			$callbacks{$refreshToken} ||= [];
			push @{$callbacks{$refreshToken}}, $cb;
		}

		if ( $cb && scalar(@{$callbacks{$refreshToken}}) > 1 ) {
			main::INFOLOG && $log->is_info && $log->info("There's already a refresh in progress for this token - queuing callback.");
			return;
		}

		# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — pass _client_id so API.pm::_tokenCall (plan 05)
		# can override the iconCode pref lookup with the flavor-correct Client ID.
		$api->refreshToken(
			sub {
				my $accessToken = _gotTokenInfo(shift, $userId, $args);
				$log->error("Failed to refresh access token for user=$userId flavor=$flavor") if !$accessToken;
				_callCallbacks($accessToken, $refreshToken);
			},
			{ refreshToken => $refreshToken, _client_id => $code }
		);
	}
}

# SPOTTY-NG (Phase 2, plan 04 / D-09 / FIX-13) — probe helper for try-own-then-fallback dispatch.
# API::_call (plan 05) calls this BEFORE attempting a bundled-flavor retry, so we can surface a
# clear sentinel error when no bundled refresh token is cached (instead of letting refreshToken
# log "No refresh token found" mid-callback — that line predates the routing logic and reads
# misleadingly when the routing chose to attempt the retry).
sub hasRefreshToken {
	my ($class, $api, %args) = @_;
	my $flavor = $args{flavor} || 'own';
	my $userId = $args{userId} || ($api && $api->userId)
	                          || (main::SCANNER ? '_scanner' : 'generic');
	my $code = $args{code};
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}
	my $rtCacheKey = _getRTCacheKey($code, $userId, $flavor);
	my $rt = $spottyCache->get($rtCacheKey) || $cache->get($rtCacheKey);
	return defined($rt) && length($rt);
}

1;
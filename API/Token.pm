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

# The dedup map is keyed on the (refreshToken, flavor) tuple via "$rt|$flavor" so a future
# cosmetic-collision case where own and bundled refresh tokens are identical (theoretically
# possible but practically impossible — Spotify RTs are unique per (user, app) pair) never
# conflates callbacks across flavors.
sub _callCallbacks {
	my ($token, $dedupKey) = @_;

	foreach (@{$callbacks{$dedupKey} || []}) {
		$_->($token);
	}
	delete $callbacks{$dedupKey};
}

sub _gotTokenInfo {
	my ($result, $userId, $args) = @_;

	return unless $result && ref $result eq 'HASH';

	my $accessToken = $result->{access_token};
	if ($accessToken) {
		my $expiresIn = $result->{expires_in} || 3600;

		main::INFOLOG && $log->is_info && $log->info("Refreshed access token for user: $userId");

		# Propagate flavor from $args into the cache writers.
		__PACKAGE__->cacheAccessToken($args->{code}, $userId, $accessToken, $expiresIn, $args->{flavor});
		__PACKAGE__->cacheRefreshToken($args->{code}, $userId, $result->{refresh_token}, $args->{flavor}) if $result->{refresh_token};
	}

	$log->error("Failed to refresh access token: " . ($result->{error} || 'Unknown error')) if $result->{error} || !$result->{access_token};

	return $accessToken;
}

# Flavor-aware access-token cache key. Callers omitting the third arg get $flavor='own',
# producing the same key shape as before plus an `_own` suffix; existing cached entries
# (no suffix) fall through to a refresh on first read after upgrade — graceful migration.
#
# Cache key shape: spotty_access_token_<code>_<userId>_<flavor>
# The AT TTL (`expires_in - 300` seconds, set in cacheAccessToken below) provides correct
# expiration without a per-process startup-time segment.
#
# Migration semantics on first read after upgrade from an older key shape:
# - Old keys become unreachable but are NOT removed proactively; they expire naturally
#   via TTL (≤ 55min).
# - First Token::get call after upgrade will look up the new key shape, miss, and
#   trigger a normal AT refresh against Spotify — identical to cold-cache first-read
#   behavior on every LMS startup, no user-visible change.
sub _getATCacheKey {
	my ($code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	return join('_', 'spotty_access_token',
	                 $code || $prefs->get('iconCode'),
	                 Slim::Utils::Unicode::utf8toLatin1Transliterate($userId),
	                 $flavor);
}

# Flavor-aware refresh-token cache key. Same backward-compat pattern as _getATCacheKey above.
sub _getRTCacheKey {
	my ($code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	return join('_', 'spotty_refresh_token',
	                 $code || $prefs->get('iconCode'),
	                 Slim::Utils::Unicode::utf8toLatin1Transliterate($userId),
	                 $flavor);
}

# Pre-flavor 3-segment RT cache key shape. Used only for the legacy-key read fallback
# in _lookupRefreshToken below; never written.
sub _getRTCacheKeyLegacy {
	my ($code, $userId) = @_;
	return join('_', 'spotty_refresh_token',
	                 $code || $prefs->get('iconCode'),
	                 Slim::Utils::Unicode::utf8toLatin1Transliterate($userId));
}

# Graceful migration of legacy RT cache entries. Looks up the new 4-segment key first;
# on miss, falls back to the legacy 3-segment key for flavor='own' only (the pre-flavor
# default), and on legacy hit opportunistically writes the value under the new key so
# subsequent reads are direct. Best-effort migration: a write failure does not block the
# read. Bundled flavor never has a legacy entry, so the fallback is skipped.
sub _lookupRefreshToken {
	my ($code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	my $newKey = _getRTCacheKey($code, $userId, $flavor);
	my $rt = $spottyCache->get($newKey) || $cache->get($newKey);
	return $rt if defined($rt) && length($rt);
	return undef unless $flavor eq 'own';
	my $legacyKey = _getRTCacheKeyLegacy($code, $userId);
	$rt = $spottyCache->get($legacyKey) || $cache->get($legacyKey);
	if (defined($rt) && length($rt)) {
		# Opportunistically migrate the value forward AND remove the legacy entry to prevent
		# stale (revoked-by-Spotify) RT accumulation. Both removes are best-effort under eval —
		# a remove failure does not block the read.
		eval { $spottyCache->set($newKey, $rt) };
		eval { $spottyCache->remove($legacyKey) };
		eval { $cache->remove($legacyKey) };
		main::INFOLOG && $log->is_info &&
			$log->info("Migrated legacy 3-segment RT key for user=$userId to flavor=own (legacy key removed)");
	}
	return $rt;
}

# Flavor-aware access-token cache writer.
sub cacheAccessToken {
	my ($class, $code, $userId, $token, $expiration, $flavor) = @_;
	$flavor ||= 'own';
	$expiration ||= DEFAULT_EXPIRATION;

	my $cacheKey = _getATCacheKey($code, $userId, $flavor);

	$expiration = $expiration > 600 ? ($expiration - 300) : $expiration;

	main::INFOLOG && $log->is_info && $log->info("Caching access token for $userId (flavor=$flavor) for $expiration seconds.");

	$cache->set($cacheKey, $token, $expiration);
}

# Flavor-aware refresh-token cache writer.
sub cacheRefreshToken {
	my ($class, $code, $userId, $token, $flavor) = @_;
	$flavor ||= 'own';
	main::INFOLOG && $log->is_info && $log->info("Caching refresh token for $userId (flavor=$flavor).");
	$spottyCache->set(_getRTCacheKey($code, $userId, $flavor), $token) if $token;
}

# Flavor-aware refresh-token cache remover. Mirror of cacheRefreshToken above. Called by
# AccountHelper::deleteCacheFolder (twice — once each for 'own' and 'bundled' flavors) so
# AccountHelper.pm stays agnostic to Token cache-key internals. Best-effort: the eval-wrap
# around the cache remove ensures cache-layer failures never block the caller (e.g. half-
# completed account-delete). Does NOT chase the legacy 3-segment RT key shape — those are
# 'own'-only by construction and age out via natural lifecycle plus _lookupRefreshToken's
# opportunistic migration on next read.
sub removeRefreshToken {
	my ($class, $code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	# Mirror the bundled-code derivation in Token::get and Token::hasRefreshToken.
	# Bundled-flavor RTs are written under a key derived from initIcon(), not iconCode;
	# once a user configures their own Spotify Developer App Client ID (the canonical
	# setup), iconCode != initIcon() and a fallback to iconCode would target a key
	# that was never written.
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}
	main::INFOLOG && $log->is_info && $log->info("Removing refresh token for $userId (flavor=$flavor).");
	eval { $spottyCache->remove(_getRTCacheKey($code, $userId, $flavor)) };
	$log->warn("removeRefreshToken: new-key remove failed for $userId (flavor=$flavor): $@") if $@;
	if ($flavor eq 'own') {
		my $legacyKey = _getRTCacheKeyLegacy($code, $userId);
		eval { $spottyCache->remove($legacyKey) };
		$log->warn("removeRefreshToken: legacy spottyCache remove failed for $userId: $@") if $@;
		eval { $cache->remove($legacyKey) };
		$log->warn("removeRefreshToken: legacy cache remove failed for $userId: $@") if $@;
	}
}

# singleton shortcut to the main class
sub get {
	my ($class, $api, $cb, $args) = @_;
	$args ||= {};

	# Defense-in-depth cooldown gate. Token::get is directly callable from _call's closure
	# and from bundled-flavor token resolves, so the rate-limit gate must apply at this level
	# too. Returns the `-429` sentinel that all callers already recognise.
	if ($cache->get('spotty_rate_limit_exceeded')) {
		return $cb ? $cb->(-429) : -429;
	}

	# Flavor extraction and bundled-code resolution.
	my $flavor = $args->{flavor} || 'own';

	my $userId = $args->{userId} || ($api && $api->userId);
	Slim::Utils::Log::logBacktrace("No userId found") if !$userId;
	$userId ||= (main::SCANNER ? '_scanner' : 'generic');

	# Under bundled flavor, derive $code from the bundled icon basename when caller
	# didn't pass one. Caller may still pass an explicit code to override.
	my $code = $args->{code};
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}

	# Build a local copy of $args carrying the resolved flavor + code to avoid mutating the
	# caller's hash. All downstream callees read these from the args/argsref they receive.
	my $localArgs = { %$args, flavor => $flavor };
	$localArgs->{code} = $code if $code;

	my $atCacheKey = _getATCacheKey($code, $userId, $flavor);

	if (my $token = $cache->get($atCacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Found cached access token (flavor=$flavor)");
		return $cb ? $cb->($token) : $token;
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("Didn't find cached token. Need to refresh. $userId");
	}

	# _lookupRefreshToken handles new-key first, legacy 3-segment fallback for flavor='own',
	# and opportunistic key migration on legacy hit.
	my $refreshToken = _lookupRefreshToken($code, $userId, $flavor);

	if (main::SCANNER) {
		# Synchronous path — bit-preserved from the pre-flavor-dispatch state:
		# the scanner branch does NOT participate in the flavor extension.
		my $tokenInfo = Plugins::Spotty::API::Sync->refreshToken(
			{ refreshToken => $refreshToken }
		);

		return _gotTokenInfo($tokenInfo, $userId, $localArgs);
	}
	else {
		if (!$refreshToken) {
			$log->error("No refresh token found - can't refresh access token. user=$userId flavor=$flavor");
			$cb->() if $cb;
			return;
		}

		# Dedup key is the (refreshToken, flavor) tuple, not refreshToken alone, so own and
		# bundled callbacks are never conflated.
		my $dedupKey = "$refreshToken|$flavor";

		if ($cb) {
			$callbacks{$dedupKey} ||= [];
			push @{$callbacks{$dedupKey}}, $cb;
		}

		if ( $cb && scalar(@{$callbacks{$dedupKey}}) > 1 ) {
			main::INFOLOG && $log->is_info && $log->info("There's already a refresh in progress for this token - queuing callback.");
			return;
		}

		# Pass _client_id so API.pm::_tokenCall can override the iconCode pref lookup
		# with the flavor-correct Client ID.
		$api->refreshToken(
			sub {
				my $accessToken = _gotTokenInfo(shift, $userId, $localArgs);

				if (!$accessToken) {
					$accessToken = _keymasterFallback($userId, $localArgs);
				}

				$log->error("Failed to refresh access token for user=$userId flavor=$flavor") if !$accessToken;
				_callCallbacks($accessToken, $dedupKey);
			},
			{ refreshToken => $refreshToken, _client_id => $code }
		);
	}
}

sub _keymasterFallback {
	my ($userId, $args) = @_;

	my $cacheDir = Plugins::Spotty::AccountHelper->cacheFolder();
	my $result = Plugins::Spotty::Helper->getKeymasterToken($cacheDir);

	if ($result && $result->{accessToken}) {
		$log->warn("PKCE refresh failed — recovered via binary keymaster token for user=$userId");
		my $expiresIn = $result->{expiresIn} || DEFAULT_EXPIRATION;
		__PACKAGE__->cacheAccessToken($args->{code}, $userId, $result->{accessToken}, $expiresIn, $args->{flavor});
		return $result->{accessToken};
	}

	return;
}

# Probe helper for try-own-then-fallback dispatch. API::_call calls this BEFORE attempting a
# bundled-flavor retry, so we can surface a clear sentinel error when no bundled refresh token
# is cached (instead of letting refreshToken log "No refresh token found" mid-callback — that
# line predates the routing logic and reads misleadingly when the routing chose to attempt the
# retry).
sub hasRefreshToken {
	my ($class, $api, %args) = @_;
	my $flavor = $args{flavor} || 'own';
	my $userId = $args{userId} || ($api && $api->userId)
	                          || (main::SCANNER ? '_scanner' : 'generic');
	my $code = $args{code};
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}
	# Share the legacy-fallback lookup with get().
	my $rt = _lookupRefreshToken($code, $userId, $flavor);
	return defined($rt) && length($rt);
}

1;
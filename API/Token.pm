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

# SPOTTY-NG (Phase 2.6, plan 03 / HARDEN-09 / closes 02-REVIEW.md WR-06) — dedup map is keyed
# on the (refreshToken, flavor) tuple via "$rt|$flavor" so a future cosmetic-collision case
# where own and bundled refresh tokens are identical (theoretically possible but practically
# impossible — Spotify RTs are unique per (user, app) pair) never conflates callbacks across
# flavors. CONTEXT.md `<code_context>` already documented this as the intent; this change
# brings the code in line with the documentation.
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

		# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — propagate flavor from $args into the cache writers.
		__PACKAGE__->cacheAccessToken($args->{code}, $userId, $accessToken, $expiresIn, $args->{flavor});
		__PACKAGE__->cacheRefreshToken($args->{code}, $userId, $result->{refresh_token}, $args->{flavor}) if $result->{refresh_token};
	}

	$log->error("Failed to refresh access token: " . ($result->{error} || 'Unknown error')) if $result->{error} || !$result->{access_token};

	return $accessToken;
}

# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor-aware access-token cache key.
# Backward-compat: callers omitting the third arg get $flavor='own', producing the
# same key shape as before plus an `_own` suffix; existing cached entries (no suffix)
# fall through to a refresh on first read after upgrade — graceful migration.
#
# SPOTTY-NG (Phase 3, plan 02 / POLISH-12 / closes 02-REVIEW.md IN-05 / promoted from
# .planning/todos/pending/HARDEN-DEFER-IN-05.md) — drop the per-process startup-time
# segment from the AT cache key shape. The AT TTL (`expires_in - 300` seconds, set in
# cacheAccessToken below) already provides correct expiration; per-startup separation
# was belt-and-suspenders that costs disk space (orphaned `spotty_access_token_*` rows
# accumulate across LMS restarts until their natural ~55min TTL expires). Dropping it
# makes the key shape:
#   spotty_access_token_<code>_<userId>_<flavor>
# instead of:
#   spotty_access_token_<startup_epoch>_<code>_<userId>_<flavor>
#
# Migration semantics on first read after upgrade:
# - Old keys (with startup-time segment) become unreachable but are NOT removed proactively;
#   they expire naturally via TTL (≤ 55min) — same graceful-miss pattern HARDEN-10
#   used for legacy 3-segment RT keys.
# - First Token::get call after upgrade will look up the new key shape, miss, and
#   trigger a normal AT refresh against Spotify. This is identical to the cold-cache
#   first-read behavior on every LMS startup — no user-visible change.
sub _getATCacheKey {
	my ($code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	return join('_', 'spotty_access_token',
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

# SPOTTY-NG (Phase 2, plan 04 follow-up / FIX-11) — pre-04 3-segment RT cache key shape.
# Used only for the legacy-key read fallback in _lookupRefreshToken below; never written.
sub _getRTCacheKeyLegacy {
	my ($code, $userId) = @_;
	return join('_', 'spotty_refresh_token',
	                 $code || $prefs->get('iconCode'),
	                 Slim::Utils::Unicode::utf8toLatin1Transliterate($userId));
}

# SPOTTY-NG (Phase 2, plan 04 follow-up / FIX-11) — graceful migration of pre-04 RT cache entries.
# Looks up the new 4-segment key first; on miss, falls back to the legacy 3-segment key for
# flavor='own' only (the pre-04 default), and on legacy hit opportunistically writes the value
# under the new key so subsequent reads are direct. Best-effort migration: a write failure
# does not block the read. Bundled flavor never has a legacy entry, so the fallback is skipped.
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
		# SPOTTY-NG (Phase 2.6, plan 03 / HARDEN-10 / closes 02-REVIEW.md WR-07) — opportunistically
		# migrate the value forward AND remove the legacy entry. Pre-fix code only wrote forward
		# and left the legacy key indefinitely; on a future Spotify RT rotation, _gotTokenInfo
		# writes the new RT only to the 4-segment key, leaving the legacy key holding a stale
		# (now-revoked-by-Spotify) RT. A user rolling back to pre-Phase-2 code would read the
		# legacy entry, get a 401 from Spotify, and be forced to re-authorize. Removing the
		# legacy key after migration eliminates that rollback hazard and tidies up bundled-OAuth
		# side-trip flush sequences.
		#
		# Implementation note: Plugins::Spotty::API::Cache (the namespaced wrapper bound to
		# $spottyCache) does not expose ->remove; its internal Slim::Utils::Cache instance does
		# (proxied through the standard `remove` method). Reach through the documented
		# `cache` slot of the wrapper, plus the module-level $cache (the default LMS namespace)
		# in case a legacy entry was historically read from there too. Both removes are
		# best-effort under eval — a remove failure does not block the read.
		eval { $spottyCache->set($newKey, $rt) };
		# SPOTTY-NG (Phase 3, plan 02 / POLISH-09 / closes 02.6-REVIEW.md IN-04) — soft fix
		# for the encapsulation breach. Pre-fix code reaches into `$spottyCache->{cache}` to
		# call `->remove`, which works today (Plugins::Spotty::API::Cache exposes the slot)
		# but would silently regress to a no-op if a future refactor renames or hides the
		# slot. The clean fix is to add a `remove` method to Plugins::Spotty::API::Cache and
		# proxy through it — but that expands the file scope to Spotty-Plugin/API/Cache.pm,
		# which D3-13 explicitly forbids in Phase 3. Instead, surface a WARN log when the
		# slot is unreachable so a future regression doesn't go silent. (Eval-wrap stays so
		# any other failure mode — e.g. a Slim::Utils::Cache implementation that throws on
		# remove of a non-existent key — also doesn't kill the migration write.)
		if (!defined $spottyCache->{cache}) {
			$log->warn('[SPOTTY-NG] _lookupRefreshToken: cannot remove legacy RT key — '
			          . 'Plugins::Spotty::API::Cache internal `cache` slot is undef. Encapsulation '
			          . 'changed in a way that hides the slot; legacy keys will accumulate. '
			          . 'See 02.6-REVIEW.md IN-04 / 03-PATTERNS.md POLISH-09 for the clean-fix '
			          . 'option (add a public ->remove method to Plugins::Spotty::API::Cache).');
		}
		else {
			eval { $spottyCache->{cache}->remove($legacyKey) };
		}
		eval { $cache->remove($legacyKey) };
		main::INFOLOG && $log->is_info &&
			$log->info("Migrated legacy 3-segment RT key for user=$userId to flavor=own (legacy key removed)");
	}
	return $rt;
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

# SPOTTY-NG (Phase 4 / D-4-07 / closes UAT-3 hookup primitive) — flavor-aware refresh-token
# cache remover. Mirror of cacheRefreshToken above. Called by AccountHelper::deleteCacheFolder
# (twice — once each for 'own' and 'bundled' flavors) so AccountHelper.pm stays agnostic to
# Token cache-key internals. Best-effort: cache-remove failures never block the caller.
# Does NOT chase the legacy 3-segment RT key shape (D-4-09) — those are 'own'-only by
# construction and age out via natural lifecycle / _lookupRefreshToken's opportunistic
# migration (HARDEN-10).
sub removeRefreshToken {
	my ($class, $code, $userId, $flavor) = @_;
	$flavor ||= 'own';
	# Mirror the bundled-code derivation already in Token::get (lines 251-254) and
	# Token::hasRefreshToken (lines 332-335). Bundled-flavor RTs are written under a
	# key derived from initIcon(), not iconCode; once a user configures their own
	# Spotify Developer App Client ID (the canonical setup), iconCode != initIcon()
	# and a fallback to iconCode would target a key that was never written.
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}
	main::INFOLOG && $log->is_info && $log->info("Removing refresh token for $userId (flavor=$flavor).");
	$spottyCache->remove(_getRTCacheKey($code, $userId, $flavor));
}

# singleton shortcut to the main class
sub get {
	my ($class, $api, $cb, $args) = @_;
	$args ||= {};

	# SPOTTY-NG (Phase 3, plan 02 / POLISH-02 / closes 02.6-REVIEW.md WR-02) — defense-in-depth
	# cooldown gate. Mirrors the API.pm::getToken pattern at lines 140-148. Pre-Phase-2,
	# Token::get was only invoked through getToken (which gates on cooldown); Phase 2's
	# plan-05 made Token::get directly callable from _call's closure (and from $bundledCb's
	# bundled-flavor token resolve), so the gate must apply at this level too. The check
	# must respect the `$cb`-may-be-undef contract — same as the existing cached-AT
	# early-return at lines 201-206 (`return $cb ? $cb->($token) : $token;`). Returns the
	# `-429` sentinel that all callers of Token::get (or its API.pm wrappers) already
	# recognise via _callOneShot's `^-(\d+)$` test (API.pm:1235-1242).
	if ($cache->get('spotty_rate_limit_exceeded')) {
		return $cb ? $cb->(-429) : -429;
	}

	# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — flavor extraction and bundled-code resolution.
	my $flavor = $args->{flavor} || 'own';

	my $userId = $args->{userId} || ($api && $api->userId);
	Slim::Utils::Log::logBacktrace("No userId found") if !$userId;
	$userId ||= (main::SCANNER ? '_scanner' : 'generic');

	# SPOTTY-NG: under bundled flavor, derive $code from the bundled icon basename when caller
	# didn't pass one. Caller may still pass an explicit code to override — preserves test ergonomics.
	my $code = $args->{code};
	if (!$code && $flavor eq 'bundled') {
		$code = Plugins::Spotty::Plugin->initIcon();
	}

	# SPOTTY-NG (Phase 2.6, plan 03 / HARDEN-08 / closes 02-REVIEW.md WR-05) — build a local
	# copy of $args carrying the resolved flavor + code, so we don't mutate the caller's hash.
	# Pre-fix code wrote the resolved flavor and code values back into $args, which surprised
	# callers passing long-lived or shared hashes (none today, but a future change could). All
	# downstream callees (_gotTokenInfo, $api->refreshToken) read these from the args/argsref
	# they receive, so passing $localArgs preserves behavior bit-for-bit.
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

	# SPOTTY-NG (Phase 2, plan 04 follow-up) — _lookupRefreshToken handles new-key first,
	# legacy 3-segment fallback for flavor='own', and opportunistic key migration on legacy hit.
	my $refreshToken = _lookupRefreshToken($code, $userId, $flavor);

	if (main::SCANNER) {
		# Synchronous path — UNTOUCHED per D-16 / FIX-07. Bit-preserved from the pre-patch state:
		# the scanner branch does NOT participate in the flavor extension in this phase.
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

		# SPOTTY-NG (Phase 2.6, plan 03 / HARDEN-09 / closes 02-REVIEW.md WR-06) — dedup key is
		# now the (refreshToken, flavor) tuple, not refreshToken alone.
		my $dedupKey = "$refreshToken|$flavor";

		if ($cb) {
			$callbacks{$dedupKey} ||= [];
			push @{$callbacks{$dedupKey}}, $cb;
		}

		if ( $cb && scalar(@{$callbacks{$dedupKey}}) > 1 ) {
			main::INFOLOG && $log->is_info && $log->info("There's already a refresh in progress for this token - queuing callback.");
			return;
		}

		# SPOTTY-NG (Phase 2, plan 04 / D-07 / FIX-11) — pass _client_id so API.pm::_tokenCall (plan 05)
		# can override the iconCode pref lookup with the flavor-correct Client ID.
		$api->refreshToken(
			sub {
				my $accessToken = _gotTokenInfo(shift, $userId, $localArgs);
				$log->error("Failed to refresh access token for user=$userId flavor=$flavor") if !$accessToken;
				_callCallbacks($accessToken, $dedupKey);
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
	# SPOTTY-NG (Phase 2, plan 04 follow-up) — share the legacy-fallback lookup with get().
	my $rt = _lookupRefreshToken($code, $userId, $flavor);
	return defined($rt) && length($rt);
}

1;
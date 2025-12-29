package Plugins::Spotty::API::Token;

use strict;

use File::Slurp;
# use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

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

my $cache = Slim::Utils::Cache->new('spotty', 0);
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

sub _logCommand {
	if (main::INFOLOG && $log->is_info) {
		my ($cmd) = @_;
		$cmd =~ s/--client-id [a-f0-9]+/--client-id ***/;
		$cmd =~ s/(access_token|refresh_token)=\w+/$1=***/g;
		$log->info("Trying to get access token: $cmd");
	}
}

sub _gotTokenInfo {
	my ($result, $userId, $args) = @_;

	return unless $result && ref $result eq 'HASH';

	my $accessToken = $result->{access_token};
	if ($accessToken) {
		my $expiresIn = $result->{expires_in} || 3600;

		main::INFOLOG && $log->is_info && $log->info("Refreshed access token for user: $userId");

		__PACKAGE__->cacheAccessToken($args->{code}, $userId, $accessToken, $expiresIn);
		__PACKAGE__->cacheRefreshToken($args->{code}, $userId, $result->{refresh_token}) if $result->{refresh_token};
	}

	$log->error("Failed to refresh access token: " . ($result->{error} || 'Unknown error')) if $result->{error} || !$result->{refresh_token};

	return $accessToken;
}

my $startupTime = time();
sub _getATCacheKey {
	my ($code, $userId, $tokenId) = @_;
	return join('_', 'spotty_access_token', $startupTime, $code || $prefs->get('iconCode'), Slim::Utils::Unicode::utf8toLatin1Transliterate($userId));
}

sub _getRTCacheKey {
	my ($code, $userId, $tokenId) = @_;
	return join('_', 'spotty_refresh_token', $code || $prefs->get('iconCode'), Slim::Utils::Unicode::utf8toLatin1Transliterate($userId));
}

sub cacheAccessToken {
	my ($class, $code, $userId, $token, $expiration) = @_;
	$expiration ||= DEFAULT_EXPIRATION;

	my $cacheKey = _getATCacheKey($code, $userId);

	$expiration = $expiration > 600 ? ($expiration - 300) : $expiration;

	main::INFOLOG && $log->is_info && $log->info("Caching access token for $userId for $expiration seconds.");

	$cache->set($cacheKey, $token, $expiration);
}

sub cacheRefreshToken {
	my ($class, $code, $userId, $token) = @_;
	main::INFOLOG && $log->is_info && $log->info("Caching refresh token for $userId.");
	$cache->set(_getRTCacheKey($code, $userId), $token, '1y') if $token;
}

# singleton shortcut to the main class
sub get {
	my ($class, $api, $cb, $args) = @_;
	$args ||= {};

	my $userId = $args->{userId} || ($api && $api->userId);
	Slim::Utils::Log::logBacktrace("No userId found") if !$userId;
	$userId ||= (main::SCANNER ? '_scanner' : 'generic');
	my $cacheKey = _getATCacheKey($args->{code}, $userId);

	if (my $token = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Found cached token: $token");
		main::DEBUGLOG && $log->is_debug && $log->debug($token);
		return $cb ? $cb->($token) : $token;
	}
	else {
		$log->warn("Didn't find cached token. Need to refresh. $userId");
	}

	my $refreshToken = $cache->get(_getRTCacheKey($args->{code}, $userId));

	if (main::SCANNER) {
		my $tokenInfo = Plugins::Spotty::API::Sync->refreshToken(
			{ refreshToken => $refreshToken }
		);

		return _gotTokenInfo($tokenInfo, $userId, $args);
	}
	else {
		if (!$refreshToken) {
			$log->warn("No refresh token found - can't refresh access token. $userId");
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

		$api->refreshToken(
			sub {
				my $accessToken = _gotTokenInfo(shift, $userId, $args);
				$log->error("Failed to refresh access token for $userId") if !$accessToken;
				_callCallbacks($accessToken, $refreshToken);
			},
			{ refreshToken => $refreshToken }
		);
	}
}

1;
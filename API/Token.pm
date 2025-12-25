package Plugins::Spotty::API::Token;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Slurp;
use File::Spec::Functions qw(catfile tmpdir);
use File::Temp;
use JSON::XS::VersionOneAndTwo;
use Proc::Background;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::Helper;

__PACKAGE__->mk_accessor( rw => qw(
	api
	_proc
	_tmpfile
	_callbacks
) );

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

use constant POLLING_INTERVAL => 0.5;
use constant TIMEOUT => 15;
use constant DEFAULT_EXPIRATION => 3600;

# Argh...
use constant CAN_ASYNC_GET_TOKEN => !main::ISWINDOWS;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

my %procs;
my %callbacks;

_cleanupTmpDir();

sub new {
	my ($class, $api, $args) = @_;
	$args ||= {};

	Plugins::Spotty::Helper->init();

	my $self = $class->SUPER::new();
	$self->api($api);
	$self->_callbacks([]);

	my $account = Plugins::Spotty::AccountHelper->getAccount($api->client);

	$self->_tmpfile(File::Temp->new(
		UNLINK => 1,
		TEMPLATE => 'spt-XXXXXXXX',
		DIR => tmpdir()
	)->filename);

	my $cmd = sprintf(
		Plugins::Spotty::Helper->getCapability('save-token')
			? '"%s" -n "Squeezebox" -c "%s" --client-id "%s" --disable-discovery --scope "%s" --save-token "%s"'
			: '"%s" -n "Squeezebox" -c "%s" --client-id "%s" --disable-discovery --scope "%s" --get-token > "%s" 2>&1',
		scalar Plugins::Spotty::Helper->get(),
		$self->api->cache || Plugins::Spotty::AccountHelper->cacheFolder($account),
		$args->{code} || $prefs->get('iconCode'),
		$args->{scope} || SPOTIFY_SCOPE,
		$self->_tmpfile
	);

	# for whatever reason Windows can't handle the quotes here...
	main::ISWINDOWS && $cmd =~ s/"//g;

	_logCommand($cmd);

	eval {
		$self->_proc( Proc::Background->new($cmd) );
	};

	if ($@) {
		$log->warn("Failed to launch the Spotty helper: $@");
	}

	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + TIMEOUT, \&_killTokenHelper);
	Slim::Utils::Timers::setHighTimer($self, Time::HiRes::time() + POLLING_INTERVAL, \&_pollTokenHelper, $args);

	return $self;
}

sub _cleanupTmpDir {
	my $tmpDir = tmpdir();

	if (opendir(DIR, $tmpDir)) {
		foreach my $tmp ( grep /^spt-\w{8}$/i, readdir(DIR) ) {
			unlink catfile($tmpDir, $tmp);
		}

		closedir DIR;
	}
}

sub _pollTokenHelper {
	my ($self, $args) = @_;
	Slim::Utils::Timers::killTimers($self, \&_pollTokenHelper);

	if ($self && $self->_tmpfile && -f $self->_tmpfile && -s _) {
		Slim::Utils::Timers::killTimers($self, \&_killTokenHelper);
		$self->_killTokenHelper(1);

		my $response = read_file($self->_tmpfile);
		unlink $self->_tmpfile;

		# my $token = $self->_gotTokenInfo($response, $self->api->username || 'generic', $args);
		# $self->_callCallbacks($token);
	}
	elsif ($self && $self->_proc && $self->_proc->alive) {
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + POLLING_INTERVAL, \&_pollTokenHelper, $args);
	}
	else {
		$self->_killTokenHelper(0, 'Token refresh call helper has closed unexpectedly? - Please consider re-setting your Spotify credentials should this continue to happen.');
	}
}

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
	# my ($class, $response, $username, $args) = @_;
	# $args ||= {};

	# my $token;

	# eval {
	# 	main::INFOLOG && $log->is_info && $log->info("Got response: $response");
	# 	$response = decode_json($response);
	# };

	# $log->error("Failed to get Spotify access token: $@ \n$response") if $@;

	# if ( $response && ref $response ) {
	# 	if ( $token = $response->{accessToken} ) {
	# 		my $expiry = DEFAULT_EXPIRATION;
	# 		if (my $expiresIn = $response->{expiresIn}) {
	# 			if (ref $expiresIn eq 'HASH') {
	# 				$expiry = $expiresIn->{secs} || DEFAULT_EXPIRATION;
	# 			} elsif ($expiresIn =~ /^\d+$/) {
	# 				$expiry = $expiresIn || DEFAULT_EXPIRATION;
	# 			}
	# 		}

	# 		main::DEBUGLOG && $log->is_debug && $log->debug("Received access token: " . Data::Dump::dump($response));
	# 		main::INFOLOG && $log->is_info && $log->debug("Caching access token for $expiry seconds.");

	# 		# Cache for the given expiry time (less some to be sure...)
	# 		# $class->cacheAccessToken($args->{code}, $username, $token, $expiry);
	# 	}
	# }
	# else {
	# 	$response = {};
	# }

	# if (!$token) {
	# 	$log->error($response->{error} || "Failed to get Spotify access token");
	# 	# store special value to prevent hammering the backend
	# 	# $class->cacheAccessToken($args->{code}, $username, $token = -1, 15);
	# }

	# return $token;
}

sub _killTokenHelper {
	my ($self, $active, $msg) = @_;

	Slim::Utils::Timers::killTimers($self, \&_pollTokenHelper);
	Slim::Utils::Timers::killTimers($self, \&_killTokenHelper);

	$log->error($msg || 'Timed out waiting for a token') unless $active;

	# $self->_callCallbacks() if $self && !$active;

	if ($self && $self->_proc) {
		$self->_proc->die();
	}
}

my $startupTime = time();
sub _getATCacheKey {
	my ($code, $username, $tokenId) = @_;
	return join('_', 'spotty_access_token', $startupTime, $code || $prefs->get('iconCode'), Slim::Utils::Unicode::utf8toLatin1Transliterate($username));
}

sub _getRTCacheKey {
	my ($code, $username, $tokenId) = @_;
	return join('_', 'spotty_refresh_token', $code || $prefs->get('iconCode'), Slim::Utils::Unicode::utf8toLatin1Transliterate($username));
}

sub cacheAccessToken {
	my ($class, $code, $username, $token, $expiration) = @_;
	$expiration ||= DEFAULT_EXPIRATION;

	my $cacheKey = _getATCacheKey($code, $username);

	$expiration = $expiration > 600 ? ($expiration - 300) : $expiration;

	main::INFOLOG && $log->is_info && $log->info("Caching access token for $expiration seconds.");

	$cache->set($cacheKey, $token, $expiration);
}

sub cacheRefreshToken {
	my ($class, $code, $username, $token) = @_;
	$cache->set(_getRTCacheKey($code, $username), $token, '1y') if $token;
}

# singleton shortcut to the main class
sub get {
	my ($class, $api, $cb, $args) = @_;
	$args ||= {};

	my $userId = $args->{accountId} || ($api && $api->username) || (main::SCANNER ? '_scanner' : 'generic');
	my $cacheKey = _getATCacheKey($args->{code}, $userId);

	if (my $token = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Found cached token: $token");
		main::DEBUGLOG && $log->is_debug && $log->debug($token);
		return $cb ? $cb->($token) : $token;
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("Didn't find cached token. Need to refresh. $userId");
	}

	if (main::SCANNER) {
		my $cmd = sprintf('"%s" -n "Squeezebox" -c "%s" --client-id "%s" --disable-discovery --get-token --scope "%s"',
			scalar Plugins::Spotty::Helper->get(),
			Plugins::Spotty::AccountHelper->cacheFolder($args->{accountId}),
			$prefs->get('iconCode'),
			SPOTIFY_SCOPE
		);

		_logCommand($cmd);

		return $class->_gotTokenInfo(`$cmd 2>&1`, $args->{accountId} || '_scanner');
	}
	else {
		my $refreshToken = $cache->get(_getRTCacheKey($args->{code}, $userId));

		if (!$refreshToken) {
			main::INFOLOG && $log->is_info && $log->info("No refresh token found - can't refresh access token.");
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
				my $result = shift || {};
				my $accessToken;

				if ($accessToken = $result->{access_token}) {
					my $expiresIn = $result->{expires_in} || 3600;

					main::INFOLOG && $log->is_info && $log->info("Refreshed access token for user: $userId");

					$class->cacheAccessToken($args->{code}, $userId, $accessToken, $expiresIn - 300);
					$class->cacheRefreshToken($args->{code}, $userId, $result->{refresh_token}) if $result->{refresh_token};

					# $cb->($accessToken) if $cb;
					# return;
				}

				$log->error("Failed to refresh access token: " . ($result->{error} || 'Unknown error')) if $result->{error} || !$result->{refresh_token};
				_callCallbacks($accessToken, $refreshToken);
			},
			{ refreshToken => $refreshToken }
		);

		# my $asyncHelperCall = (CAN_ASYNC_GET_TOKEN || Plugins::Spotty::Helper->getCapability('save-token')) && !$prefs->get('disableAsyncTokenRefresh');

		# my $proc;
		# if ($asyncHelperCall) {
		# 	$proc = $procs{$api} if $args->{code};
		# }

		# $api->refreshToken(
		# 	sub {
		# 		my $result = shift;
		# 		my $error;

		# 		if ($result && (my $accessToken = $result->{access_token})) {
		# 			my $expiresIn = $result->{expires_in} || 3600;

		# 			main::INFOLOG && $log->is_info && $log->info("Refreshed access token for user: $userId");

		# 			$class->cacheAccessToken(
		# 				$args->{code},
		# 				$userId,
		# 				$accessToken,
		# 				$expiresIn - 300
		# 			);

		# 			$class->cacheRefreshToken($args->{code}, $userId, $result->{refresh_token}) if $result->{refresh_token};

		# 			if ( (CAN_ASYNC_GET_TOKEN || Plugins::Spotty::Helper->getCapability('save-token')) && !$prefs->get('disableAsyncTokenRefresh') ) {

		# 				if ( !($proc && $proc->_proc && $proc->_proc->alive()) ) {
		# 					$proc = $class->new($api, $args);
		# 					# we don't keep a connection around if this is the web token code
		# 					$procs{$api} = $proc unless $args->{code};
		# 				}

		# 				if ($cb) {
		# 					my $cbs = $proc->_callbacks;
		# 					push @$cbs, $cb;
		# 					$proc->_callbacks($cbs);
		# 				}
		# 			}
		# 			else {
		# 				main::INFOLOG && $log->info("Can't do non-blocking getToken call. Good luck!");

		# 				my $account = Plugins::Spotty::AccountHelper->getAccount($api->client);

		# 				my $cmd = sprintf('"%s" -n "Squeezebox" -c "%s" --client-id "%s" --disable-discovery --get-token --scope "%s"',
		# 					scalar Plugins::Spotty::Helper->get(),
		# 					$api->cache || Plugins::Spotty::AccountHelper->cacheFolder($account),
		# 					$args->{code} || $prefs->get('iconCode'),
		# 					$args->{scope} || SPOTIFY_SCOPE
		# 				);

		# 				_logCommand($cmd);

		# 				$cb->($class->_gotTokenInfo(`$cmd 2>&1`, $api->username || 'generic', $args));
		# 			}

		# 			return;
		# 		}

		# 		$log->error("Failed to refresh access token: " . ($result->{error} || 'Unknown error'));
		# 		$class->_callCallbacks();
		# 	},
		# 	{ refreshToken => $refreshToken },
		# );
	}
}

1;
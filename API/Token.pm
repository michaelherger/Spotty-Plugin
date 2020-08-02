package Plugins::Spotty::API::Token;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Slurp;
use File::Temp qw(tempfile);
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
  user-read-private
  user-follow-modify
  user-follow-read
  user-library-read
  user-library-modify
  user-top-read
  user-read-recently-played
  user-read-playback-state
  user-modify-playback-state
  playlist-read-private
  playlist-read-collaborative
  playlist-modify-public
  playlist-modify-private
));

use constant POLLING_INTERVAL => 0.5;
use constant TIMEOUT => 15;

# Argh...
use constant CAN_ASYNC_GET_TOKEN => !main::ISWINDOWS;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

my %procs;

sub new {
	my ($class, $api) = @_;

	Plugins::Spotty::Helper->init();

	my $self = $class->SUPER::new();
	$self->api($api);
	$self->_callbacks([]);

	my $account = Plugins::Spotty::AccountHelper->getAccount($api->client);

	$self->_tmpfile(File::Temp->new(UNLINK => 1)->filename);

	my $cmd = sprintf(
		Plugins::Spotty::Helper->getCapability('save-token')
			? '%s -n Squeezebox -c "%s" -i %s --scope "%s" --save-token "%s"'
			: '%s -n Squeezebox -c "%s" -i %s --get-token --scope "%s" > "%s" 2>&1',
		scalar Plugins::Spotty::Helper->get(),
		$self->api->cache || Plugins::Spotty::AccountHelper->cacheFolder($account),
		$prefs->get('iconCode'),
		SPOTIFY_SCOPE,
		$self->_tmpfile
	);

	_logCommand($cmd);

	eval {
		$self->_proc( Proc::Background->new($cmd) );
	};

	if ($@) {
		$log->warn("Failed to launch the Spotty helper: $@");
	}

	Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + TIMEOUT, \&_killTokenHelper);
	Slim::Utils::Timers::setHighTimer($self, Time::HiRes::time() + POLLING_INTERVAL, \&_pollTokenHelper);

	return $self;
}

sub _pollTokenHelper {
	my ($self) = @_;
	Slim::Utils::Timers::killTimers($self, \&_pollTokenHelper);

	if ($self && $self->_tmpfile && -f $self->_tmpfile && -s _) {
		Slim::Utils::Timers::killTimers($self, \&_killTokenHelper);
		$self->_killTokenHelper(1);

		my $response = read_file($self->_tmpfile);
		unlink $self->_tmpfile;

		my $token = $self->_gotTokenInfo($response, $self->api->username || 'generic');
		$self->_callCallbacks($token);
	}
	elsif ($self && $self->_proc && $self->_proc->alive) {
		Slim::Utils::Timers::setTimer($self, Time::HiRes::time() + POLLING_INTERVAL, \&_pollTokenHelper);
	}
	else {
		$self->_killTokenHelper(0, 'Token refresh call helper has closed unexpectedly? - Please consider re-setting your Spotify credentials should this happen all the time.');
	}
}

sub _callCallbacks {
	my ($self, $token) = @_;

	my $cbs = $self->_callbacks();
	$self->_callbacks([]);
	foreach (@$cbs) {
		$_->($token);
	}
}

sub _logCommand {
	if (main::INFOLOG && $log->is_info) {
		my ($cmd) = @_;
		$cmd =~ s/-i [a-f0-9]+/-i abcdef1234567890/;
		$log->info("Trying to get access token: $cmd");
	}
}

sub _gotTokenInfo {
	my ($class, $response, $username) = @_;

	my $cacheKey = 'spotty_access_token' . Slim::Utils::Unicode::utf8toLatin1Transliterate($username);

	my $token;

	eval {
		main::INFOLOG && $log->is_info && $log->info("Got response: $response");
		$response = decode_json($response);
	};

	$log->error("Failed to get Spotify access token: $@ \n$response") if $@;

	if ( $response && ref $response ) {
		if ( $token = $response->{accessToken} ) {
			if ( main::DEBUGLOG && $log->is_debug ) {
				$log->debug("Received access token: " . Data::Dump::dump($response));
				$log->debug("Caching for " . ($response->{expiresIn} || 3600) . " seconds.");
			}

			# Cache for the given expiry time (less some to be sure...)
			$cache->set($cacheKey, $token, ($response->{expiresIn} || 3600) - 300);
		}
	}

	if (!$token) {
		$log->error("Failed to get Spotify access token");
		# store special value to prevent hammering the backend
		$cache->set($cacheKey, $token = -1, 15);
	}

	return $token;
}

sub _killTokenHelper {
	my ($self, $active, $msg) = @_;

	Slim::Utils::Timers::killTimers($self, \&_pollTokenHelper);
	Slim::Utils::Timers::killTimers($self, \&_killTokenHelper);

	$log->error($msg || 'Timed out waiting for a token') unless $active;

	$self->_callCallbacks() if $self && !$active;

	if ($self && $self->_proc && $self->_proc->alive) {
		$self->_proc->die();
	}
}

# singleton shortcut to the main class
sub get {
	my ($class, $api, $cb, $accountId) = @_;

	if (main::SCANNER) {
		my $cmd = sprintf('%s -n Squeezebox -c "%s" -i %s --get-token --scope "%s"',
			scalar Plugins::Spotty::Helper->get(),
			Plugins::Spotty::AccountHelper->cacheFolder($accountId),
			$prefs->get('iconCode'),
			SPOTIFY_SCOPE
		);

		_logCommand($cmd);

		return $class->_gotTokenInfo(`$cmd 2>&1`, $accountId || '_scanner');
	}
	elsif ( (CAN_ASYNC_GET_TOKEN || Plugins::Spotty::Helper->getCapability('save-token')) && !$prefs->get('disableAsyncTokenRefresh') ) {
		my $proc = $procs{$api};

		if ( !($proc && $proc->_proc && $proc->_proc->alive()) ) {
			$proc = $procs{$api} = $class->new($api);
		}

		if ($cb) {
			my $cbs = $proc->_callbacks;
			push @$cbs, $cb;
			$proc->_callbacks($cbs);
		}
	}
	else {
		main::INFOLOG && $log->info("Can't do non-blocking getToken call. Good luck!");

		my $account = Plugins::Spotty::AccountHelper->getAccount($api->client);

		my $cmd = sprintf('%s -n Squeezebox -c "%s" -i %s --get-token --scope "%s"',
			scalar Plugins::Spotty::Helper->get(),
			$api->cache || Plugins::Spotty::AccountHelper->cacheFolder($account),
			$prefs->get('iconCode'),
			SPOTIFY_SCOPE
		);

		_logCommand($cmd);

		$cb->($class->_gotTokenInfo(`$cmd 2>&1`, $api->username || 'generic'));
	}
}

1;
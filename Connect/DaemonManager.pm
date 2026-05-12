package Plugins::Spotty::Connect::DaemonManager;

use strict;

use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::Plugin;
use Plugins::Spotty::Connect::Daemon;

# buffer the helper initialization to prevent a flurry of activity when players connect etc.
use constant DAEMON_INIT_DELAY       => 2;
use constant DAEMON_WATCHDOG_INTERVAL => 60;

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my %helperInstances;

sub init {
	my $class = shift;

	# manage helper application instances
	# debounce: kill any pending initHelpers timer and set a new one with DAEMON_INIT_DELAY
	Slim::Control::Request::subscribe(sub {
		Slim::Utils::Timers::killTimers( $class, \&initHelpers );
		Slim::Utils::Timers::setTimer( $class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers );
	}, [['client'], ['new', 'disconnect']]);

	# sync group changes: kill all daemons and restart after delay
	Slim::Control::Request::subscribe(sub {
		my $request = shift;

		return if $request->isNotCommand([['sync']]);

		# we're not going to try to be smart... just kill them all :-/
		__PACKAGE__->shutdown();

		Slim::Utils::Timers::killTimers( $class, \&initHelpers );
		Slim::Utils::Timers::setTimer( $class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers );
	}, [['sync']]);

	# start/stop helpers when the Connect flag changes
	$prefs->setChange(\&initHelpers, 'enableSpotifyConnect');

	# NOTE: checkDaemonConnected is explicitly disabled (was a 429 source per REQUIREMENTS.md)
	# Only reset it to 0 if disableDiscovery is turned off
	$prefs->setChange(sub {
		$prefs->set('checkDaemonConnected', 0) if !$_[1];
	}, 'disableDiscovery');

	# re-initialize helpers when the active account or helper binary for a player changes
	$prefs->setChange(sub {
		my ($pref, $new, $client, $old) = @_;

		return unless $client && $client->id;

		main::INFOLOG && $log->is_info && $log->info("Spotify setting $pref for player " . $client->id . " has changed - re-initialize Connect helper");
		$class->stopHelper($client);
		initHelpers();
	}, 'account', 'helper');

	# re-initialize helpers when global settings change
	$prefs->setChange(sub {
		my ($pref, $new, undef, $old) = @_;

		return if !($new || $old) && $new eq $old;

		Slim::Utils::Timers::killTimers( $class, \&initHelpers );

		if (main::INFOLOG && $log->is_info) {
			$pref eq 'disableDiscovery' && $log->info("Discovery mode for Connect has changed - re-initialize Connect helpers");
			$pref eq 'helper' && $log->info("Helper binary was re-configured - re-initialize Connect helpers");
		}

		$class->shutdown();

		# call the initialization asynchronously, to allow other change handlers to finish before we restart
		Slim::Utils::Timers::setTimer( $class, time() + 1, \&initHelpers );
	}, 'helper', 'forceFallbackAP', Plugins::Spotty::Plugin->canDiscovery() ? 'disableDiscovery' : undef);

	preferences('server')->setChange(sub {
		main::INFOLOG && $log->is_info && $log->info("Authentication information for LMS has changed - re-initialize Connect helpers");
		$class->shutdown();
		initHelpers();
	}, 'authorize', 'username');
}

sub initHelpers {
	my $class = __PACKAGE__;

	Slim::Utils::Timers::killTimers( $class, \&initHelpers );

	main::INFOLOG && $log->is_info && $log->info("Checking Spotty Connect helper daemons...");

	# shut down orphaned instances (players that disconnected)
	$class->shutdown('inactive-only');

	for my $client ( Slim::Player::Client::clients() ) {
		my $syncMaster;

		# if the player is part of the sync group, only start daemon for the group, not the individual players
		if ( Slim::Player::Sync::isSlave($client) && (my $master = $client->master) ) {
			if ( $prefs->client($master)->get('enableSpotifyConnect') ) {
				$syncMaster = $master->id;
			}
			# if the master of the sync group doesn't have connect enabled, enable anyway if one of the slaves has
			else {
				($syncMaster) = map { $_->id } grep {
					$prefs->client($_)->get('enableSpotifyConnect')
				} sort { $a->id cmp $b->id } Slim::Player::Sync::slaves($master);
			}
		}

		if ( $syncMaster && $syncMaster eq $client->id ) {
			main::INFOLOG && $log->is_info && $log->info("This is not the sync group's master itself, but the first slave with Connect enabled: $syncMaster");
			$class->startHelper($client);
		}
		elsif ( $syncMaster ) {
			main::INFOLOG && $log->is_info && $log->info("This is not the sync group's master, and not the first slave with Connect either: $syncMaster");
			$class->stopHelper($client);
		}
		elsif ( !$syncMaster && $prefs->client($client)->get('enableSpotifyConnect') ) {
			main::INFOLOG && $log->is_info && $log->info("This is the sync group's master, or a standalone player with Spotify Connect enabled: " . $client->id);
			$class->startHelper($client);
		}
		else {
			main::INFOLOG && $log->is_info && $log->info("This is a standalone player with Spotify Connect disabled: " . $client->id);
			$class->stopHelper($client);
		}
	}

	# IMPORTANT: do NOT re-enable checkDaemonConnected block from v0.7 here
	# It was a 429 source and is explicitly disabled per REQUIREMENTS.md

	# set 60s watchdog timer to re-call initHelpers
	Slim::Utils::Timers::setTimer( $class, Time::HiRes::time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers );
}

sub startHelper {
	my ($class, $clientId) = @_;

	$clientId = $clientId->id if $clientId && blessed $clientId;

	# no need to restart if it's already there and alive
	my $helper = $helperInstances{$clientId};

	if (!$helper) {
		main::INFOLOG && $log->is_info && $log->info("Need to create Connect daemon for $clientId");
		$helper = $helperInstances{$clientId} = Plugins::Spotty::Connect::Daemon->new($clientId);
	}
	elsif (!$helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("Need to (re-)start Connect daemon for $clientId");
		$helper->start;
	}
	# NOTE: checkDaemonConnected block deliberately NOT re-enabled (was 429 source; per REQUIREMENTS.md)

	return $helper if $helper && $helper->alive;
}

sub stopHelper {
	my ($class, $clientId) = @_;

	$clientId = $clientId->id if $clientId && blessed $clientId;

	my $helper = delete $helperInstances{$clientId};

	if ($helper && $helper->alive) {
		main::INFOLOG && $log->is_info && $log->info(sprintf("Shutting down Connect daemon for $clientId (pid: %s)", $helper->pid));
		$helper->stop;
	}
}

sub shutdown {
	my ($class, $inactiveOnly) = @_;

	my %clientIds = map { $_->id => 1 } Slim::Player::Client::clients() if $inactiveOnly;

	foreach my $clientId ( keys %helperInstances ) {
		next if $clientIds{$clientId};
		$class->stopHelper($clientId);
	}

	Slim::Utils::Timers::killTimers( $class, \&initHelpers );
}

sub uptime {
	my ($class, $clientId) = @_;

	return unless $clientId;

	my $helper = $helperInstances{$clientId} || return 0;

	return $helper->uptime();
}

sub idFromMac {
	my ($class, $mac) = @_;

	return unless $mac;

	my $helper = $helperInstances{$mac} || return;

	return $helper->spotifyId;
}

sub helperInstances {
	my $class = shift;
	return values %helperInstances;
}

sub helperPids {
	my $class = shift;
	return map { $_->pid } grep { $_->alive } values %helperInstances;
}

sub checkAPIConnectPlayers {
	my ($class, $spotty, $data, $oneHelper) = @_;

	if ($data && ref $data && $data->{devices}) {
		my %connectDevices = map {
			$_->{name} => $_->{id};
		} @{$data->{devices}};

		my $cacheFolder = $spotty->cache;

		foreach my $helper ( $oneHelper || values %helperInstances ) {
			my $spotifyId = $connectDevices{$helper->name};

			if ( !$oneHelper && !$spotifyId && $helper->cache eq $cacheFolder ) {
				$log->warn("Connect daemon is running, but not connected - shutting down to force restart: " . $helper->mac . " " . $helper->name);
				$class->stopHelper($helper->mac);

				# NOTE: checkDaemonConnected flag is NOT set here (disabled per REQUIREMENTS.md)
				# $prefs->set('checkDaemonConnected', 1) if $prefs->get('disableDiscovery');
			}
			elsif ( $spotifyId ) {
				main::INFOLOG && $log->is_info && $log->info("Updating id of Connect connected daemon for " . $helper->mac);
				$helper->spotifyId($spotifyId);
			}
		}
	}
}

sub checkAPIConnectPlayer {
	my ($class, $spotty, $data) = @_;

	if ( $data && ref $data && $data->{device} && $spotty && $spotty->client && (my $helper = $helperInstances{$spotty->client->id}) ) {
		$class->checkAPIConnectPlayers($spotty, {
			devices => [
				$data->{device}
			]
		}, $helper);
	}
}

1;

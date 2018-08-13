package Plugins::Spotty::Connect::DaemonManager;

use strict;

use Scalar::Util qw(blessed);


use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::Plugin;
use Plugins::Spotty::Connect::Daemon;

# buffer the helper initialization to prevent a flurry of activity when players connect etc.
use constant DAEMON_INIT_DELAY => 2;
use constant DAEMON_WATCHDOG_INTERVAL => 60;

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my %helperInstances;

sub init {
	my $class = shift;

	# manage helper application instances
	Slim::Control::Request::subscribe(sub {
		Slim::Utils::Timers::killTimers( $class, \&initHelpers );
		Slim::Utils::Timers::setTimer( $class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers );;
	}, [['client'], ['new', 'disconnect']]);

	Slim::Control::Request::subscribe(sub {
		my $request = shift;

		return if $request->isNotCommand([['sync']]);

		# # we need to re-initialize daemons for all members or the sync group
		# if ( my $client = $request->client ) {
		# 	foreach ($client, $client->master, Slim::Player::Sync::slaves($client->master)) {
		# 		warn $_->name;
		# 		__PACKAGE__->stopHelper($_->id);
		# 	}
		# }

		# if ( my $buddy = $request->getParam('_indexid-') ) {
		# 	__PACKAGE__->stopHelper($buddy);
		# }

		# we're not going to try to be smart... just kill them all :-/
		__PACKAGE__->shutdown();

		Slim::Utils::Timers::killTimers( $class, \&initHelpers );
		Slim::Utils::Timers::setTimer( $class, Time::HiRes::time() + DAEMON_INIT_DELAY, \&initHelpers );;
	}, [['sync']]);

	# start/stop helpers when the Connect flag changes
	$prefs->setChange(\&initHelpers, 'enableSpotifyConnect');

	# re-initialize helpers when the active account for a player changes
	$prefs->setChange(sub {
		my ($pref, $new, $client, $old) = @_;

		return unless $client && $client->id;

		main::INFOLOG && $log->is_info && $log->info("Spotify Account for player " . $client->id . " has changed - re-initialize Connect helper");
		$class->stopHelper($client);
		initHelpers();
	}, 'account', 'helper');

	$prefs->setChange(sub {
		my ($pref, $new, undef, $old) = @_;

		return if !($new || $old) && $new eq $old;

		if (main::INFOLOG && $log->is_info) {
			$pref eq 'disableDiscovery' && $log->info("Discovery mode for Connect has changed - re-initialize Connect helpers");
			$pref eq 'helper' && $log->info("Helper binary was re-configured - re-initialize Connect helpers");
		}

		$class->shutdown();

		# call the initialization asynchronously, to allow other change handlers to finish before we restart
		Slim::Utils::Timers::setTimer( $class, time() + 1, \&initHelpers );
	}, 'helper', Plugins::Spotty::Plugin->canDiscovery() ? 'disableDiscovery' : undef);

	preferences('server')->setChange(sub {
		main::INFOLOG && $log->is_info && $log->info("Authentication information for LMS has changed - re-initialize Connect helpers");
		$class->shutdown();
		initHelpers();
	}, 'authorize', 'username', 'password');
}

sub initHelpers {
	my $class = __PACKAGE__;

	Slim::Utils::Timers::killTimers( $class, \&initHelpers );

	main::INFOLOG && $log->is_info && $log->info("Initializing/verifying Spotty Connect helper daemons...");

	# shut down orphaned instances
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
				($syncMaster) = grep {
					$prefs->client($_)->get('enableSpotifyConnect')
				} sort { $a->id cmp $b->id } Slim::Player::Sync::slaves($master);

				main::INFOLOG && $log->is_info && $log->info("Master doesn't have Connect, but slave does: $syncMaster");
			}
		}

		# we're not the sync group's master itself, but the first slave with Connect enabled
		if ( $syncMaster && $syncMaster eq $client->id ) {
			$class->startHelper($client);
		}
		# we're not the sync group's master, and not the first slave with Connect either
		elsif ( $syncMaster ) {
			$class->stopHelper($client);
		}
		# we're the sync group's master, or there's no group
		elsif ( !$syncMaster && $prefs->client($client)->get('enableSpotifyConnect') ) {
			$class->startHelper($client);
		}
		else {
			$class->stopHelper($client);
		}
	}

	Slim::Utils::Timers::setTimer( $class, Time::HiRes::time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers );
}

sub startHelper {
	my ($class, $clientId) = @_;

	$clientId = $clientId->id if $clientId && blessed $clientId;

	# no need to restart if it's already there
	my $helper = $helperInstances{$clientId};

	if (!$helper) {
		main::INFOLOG && $log->is_info && $log->info("Need to create Connect daemon for $clientId");
		$helper = $helperInstances{$clientId} = Plugins::Spotty::Connect::Daemon->new($clientId);
	}
	elsif (!$helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("Need to (re-)start Connect daemon for $clientId");
		$helper->start;
	}

	return $helper if $helper && $helper->alive;
}

sub stopHelper {
	my ($class, $clientId) = @_;

	$clientId = $clientId->id if $clientId && blessed $clientId;

	my $helper = $helperInstances{$clientId};

	if ($helper) {
		main::INFOLOG && $log->is_info && $log->info("Shutting down Connect daemon for $clientId");
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

1;

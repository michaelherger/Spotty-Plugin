package Plugins::Spotty::Connect::DaemonManager;

use strict;

use Scalar::Util qw(blessed);


use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::Plugin;
use Plugins::Spotty::Connect::Daemon;

use constant DAEMON_WATCHDOG_INTERVAL => 60;

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my %helperInstances;

sub init {
	my $class = shift;
	
	# manage helper application instances
	Slim::Control::Request::subscribe(\&initHelpers, [['client'], ['new', 'disconnect']]);
	
	# start/stop helpers when the Connect flag changes
	$prefs->setChange(\&initHelpers, 'enableSpotifyConnect');
	
	# re-initialize helpers when the active account for a player changes
	$prefs->setChange(sub {
		my ($pref, $new, $client, $old) = @_;
		
		return unless $client && $client->id;
		
		main::INFOLOG && $log->is_info && $log->info("Spotify Account for player " . $client->id . " has changed - re-initialize Connect helper");
		$class->stopHelper($client);
		initHelpers();
	}, 'account');

	$prefs->setChange(sub {
		main::INFOLOG && $log->is_info && $log->info("Discovery mode for Connect has changed - re-initialize Connect helpers");
		$class->shutdown();
		initHelpers();
	}, 'disableDiscovery') if Plugins::Spotty::Plugin->canDiscovery();
}

sub initHelpers {
	my $class = __PACKAGE__;
	
	Slim::Utils::Timers::killTimers( $class, \&initHelpers );

	main::DEBUGLOG && $log->is_debug && $log->debug("Initializing Spotty Connect helper daemons...");

	# shut down orphaned instances
	$class->shutdown('inactive-only');

	for my $client ( Slim::Player::Client::clients() ) {
		if ( $prefs->client($client)->get('enableSpotifyConnect') ) {
			$class->startHelper($client);
		}
		else {
			$class->stopHelper($client);
		}
	}

	Slim::Utils::Timers::setTimer( $class, time() + DAEMON_WATCHDOG_INTERVAL, \&initHelpers );
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

1;

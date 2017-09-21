package Plugins::Spotty::Connect;

use strict;

use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use constant MIN_HELPER_VERSION => '0.7.0';
use constant SEEK_THRESHOLD => 3;
use constant NOTIFICATION => '{\\"id\\":0,\\"params\\":[\\"%s\\",[\\"spottyconnect\\",\\"%s\\"]],\\"method\\":\\"slim.request\\"}';

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my %helperInstances;
my %helperBins;
my $initialized;

sub init {
	my ($class) = @_;
	
	return unless $class->canSpotifyConnect('dontInit');
	
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch(['spottyconnect','_cmd'],
	                                                            [1, 0, 0, \&_connectEvent]
	);
	
	# listen to playlist change events so we know when Spotify Connect mode ends
	Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);
	
	# we want to tell the Spotify controller to pause playback when we pause locally
	Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);
	
	# manage helper application instances
	Slim::Control::Request::subscribe(\&initHelpers, [['client'], ['new', 'disconnect']]);
	
	# start/stop helpers when the Connect flag changes
	$prefs->setChange(\&initHelpers, 'enableSpotifyConnect');

	if (main::WEBUI) {
		require Plugins::Spotty::PlayerSettings;
		Plugins::Spotty::PlayerSettings->new();
	}
	
	$initialized = 1;
}

sub canSpotifyConnect {
	my ($class, $dontInit) = @_;
	
	# we need either curl or wget in order to interact with the helper application
	return unless _getCurlCmd() || _getWgetCmd();
	
	# we need a minimum helper application version
	my ($helperPath, $helperVersion) = Plugins::Spotty::Plugin->getHelper();
	$helperVersion =~ s/^v//;
	
	if ( !Slim::Utils::Versions->checkVersion($helperVersion, MIN_HELPER_VERSION, 10) ) {
		$log->error("Cannot support Spotty Connect, need at least helper version " . MIN_HELPER_VERSION);
		return;
	}
	
	__PACKAGE__->init() unless $initialized || $dontInit;
	
	return 1;
}

sub isSpotifyConnect {
	my ( $class, $client ) = @_;
	
	return unless $client;
	$client = $client->master;
	my $song = $client->playingSong();
	
	return $client->pluginData('newTrack') || ($song ? $song->pluginData('SpotifyConnect') : undef) ? 1 : 0; 
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $client = $song->master;

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);			

	if ( $client->pluginData('newTrack') ) {
		main::INFOLOG && $log->is_info && $log->info("Don't get next track as we got called by a play track event from spotty");
		$song->pluginData( SpotifyConnect => 1 );
		$client->pluginData( newTrack => 0 );
		$successCb->();
	}
	else {
		main::INFOLOG && $log->is_info && $log->info("We're approaching the end of a track - get the next track");

		$client->pluginData( newTrack => 1 );

		$spotty->playerNext(sub {
			$spotty->player(sub {
				my ($result) = @_;
				
				if ( $result && ref $result && (my $uri = $result->{item}->{uri}) ) {
					main::INFOLOG && $log->is_info && $log->info("Got a new track to be played next: $uri");
					
					$uri =~ s/^(spotify:)(track:.*)/$1\/\/$2/;

					$song->track->url($uri);
					$song->pluginData( SpotifyConnect => 1 );
					
					$successCb->();
				}
			});
		});
	}
}

sub _onNewSong {
	my $request = shift;
	my $client  = $request->client();

	return if !defined $client;
	
	$client = $client->master;

	return if $request->source && $request->source eq __PACKAGE__;
	
	return if __PACKAGE__->isSpotifyConnect($client);
	
	main::INFOLOG && $log->is_info && $log->info("Got a new track event, but this is no longer Spotify Connect");
	$client->playingSong()->pluginData( SpotifyConnect => 0 );
}

sub _onPause {
	my $request = shift;
	my $client  = $request->client();

	return if !defined $client;
	$client = $client->master;

	return if !__PACKAGE__->isSpotifyConnect($client);
	
	main::INFOLOG && $log->is_info && $log->info("Got a pause event - tell Spotify Connect controller to pause, too");
	Plugins::Spotty::Plugin->getAPIHandler($client)->playerPause();
}

sub _connectEvent {
	my $request = shift;
	my $client = $request->client()->master;
	
	if ( $client->pluginData('newTrack') ) {
		$client->pluginData( newTrack => 0 );
		return;
	}

	my $cmd = $request->getParam('_cmd');
	
	main::INFOLOG && $log->is_info && $log->info("Got called from spotty helper: $cmd");

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);			

	$spotty->player(sub {
		my ($result) = @_;
		
		my $song = $client->playingSong();
		my $streamUrl = ($song ? $song->streamUrl : '') || '';
		$streamUrl =~ s/\/\///;
		
		$result ||= {};
		
		#warn Data::Dump::dump($result, $cmd);
		
		# in case of a change event we need to figure out what actually changed...
		if ( $cmd =~ /change|stop/ && $result && ref $result && (($streamUrl ne $result->{track}->{uri} && $result->{is_playing}) || !__PACKAGE__->isSpotifyConnect($client)) ) {
			main::INFOLOG && $log->is_info && $log->info("Got a $cmd event, but actually this is a play next track event");
			$cmd = 'start';
		}

		if ( $cmd eq 'start' && $result->{track} ) {
			if ( $streamUrl ne $result->{track}->{uri} || !__PACKAGE__->isSpotifyConnect($client) ) {
				main::INFOLOG && $log->is_info && $log->info("Got a new track to be played: " . $result->{track}->{uri});

				# Sometimes we want to know whether we're in Spotify Connect mode or not
				$client->pluginData( newTrack => 1 );

				my $request = $client->execute( [ 'playlist', 'play', $result->{track}->{uri} ] );
				$request->source(__PACKAGE__);
				
				# if status is already more than 10s in, then do seek
				if ( $result->{progress} && $result->{progress} > 10 ) {
					$client->execute( ['time', $result->{progress}] );
				}
			}
			elsif ( !$client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Got to resume playback");
				my $request = $client->execute(['play']);
				$request->source(__PACKAGE__);
			}
		}
		elsif ( $cmd eq 'stop' && $result->{device} ) {
			my $clientId = $client->id;
			
			# if we're playing, got a stop event, and current Connect device is us, then pause
			if ( $client->isPlaying && $result->{device}->{name} =~ /\Q$clientId\E/i ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause");
				$client->execute(['pause']);
			} 
			# if we're playing, got a stop event, and current Connect device is NOT us, then 
			# disable Connect and let the track end
			elsif ( $client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause, but current player is not Connect target");
				$client->playingSong()->pluginData( SpotifyConnect => 0 );
			}
		}
		elsif ( $cmd eq 'change' ) {
			# seeking event from Spotify - we would only seek if the difference was larger than x seconds, as we'll never be perfectly in sync
			if ( $client->isPlaying && abs($result->{progress} - Slim::Player::Source::songTime($client)) > SEEK_THRESHOLD ) {
				$client->execute( ['time', $result->{progress}] );
			}
		}
	});
}

sub initHelpers {
	my $class = __PACKAGE__;

	main::INFOLOG && $log->is_info && $log->info("Initializing Spotty Connect helper daemons...");

	# shut down orphaned instances
	$class->shutdownHelpers('inactive-only');

	for my $client ( Slim::Player::Client::clients() ) {
		my $clientId = $client->id;

		if ( $prefs->client($client)->get('enableSpotifyConnect') ) {
			if (!$helperInstances{$clientId} || !$helperInstances{$clientId}->alive) {
				$class->startHelper($client);
			}
		}
		else {
			$class->stopHelper($clientId);
		}
	}
}

sub startHelper {
	my ($class, $client) = @_;
	
	my $clientId = $client->id;
	
	# no need to restart if it's already there
	my $helper = $helperInstances{$clientId};
	return $helper->alive if $helper && $helper->alive;

	if ( (_getCurlCmd() || _getWgetCmd()) && (my $helperPath = Plugins::Spotty::Plugin->getHelper()) ) {
		if ( !($helper && $helper->alive) ) {
			my $command = sprintf('%s -c "%s" -n "%s (%s)" --disable-discovery --onstart "%s" --onstop "%s" --onchange "%s" %s > %s', 
				$helperPath, 
				Plugins::Spotty::Plugin->cacheFolder( Plugins::Spotty::Plugin->getAccount($client) ), 
				$client->name,
				$clientId,
				_getNotificationCmd('start', $clientId),
				_getNotificationCmd('stop', $clientId),
				_getNotificationCmd('change', $clientId),
				_getPVcmd(),
				main::ISWINDOWS ? 'NULL' : '/dev/null'
			);
			main::INFOLOG && $log->is_info && $log->info("Starting Spotty Connect deamon: $command");
			
			eval { 
				$helper = $helperInstances{$clientId} = Proc::Background->new(
					{ 'die_upon_destroy' => 1 },
					$command 
				);
			};
	
			if ($@) {
				$log->warn("Failed to launch the Spotty Connect deamon: $@");
			}
		}
	}

	return $helper && $helper->alive;
}

sub _getNotificationCmd {
	my ($event, $clientId) = @_;
	
	my $cmd = sprintf(NOTIFICATION, $clientId, $event);
	
	if ( my $curl = _getCurlCmd() ) {
		return sprintf(
			'%s -s -X POST -d %s %s/jsonrpc.js',
			$curl,
			$cmd,
			Slim::Utils::Network::serverURL()
		);
	}
	elsif ( my $wget = _getWgetCmd() ) {
		return sprintf(
			'%s -q -O- --post-data %s %s/jsonrpc.js',
			$wget,
			$cmd,
			Slim::Utils::Network::serverURL()
		);
	}
}

sub _getCurlCmd {
	return;
	return $helperBins{curl} if $helperBins{curl};
	
	if ( my $curl = Slim::Utils::Misc::findbin('curl') ) {
		$helperBins{curl} = $curl;
	}
	else {
		$log->error("Can't initialized Spotty Connect without the 'curl' utility. Please install curl using your package manager.") unless defined $helperBins{curl};
		$helperBins{curl} = '';
	}

	return $helperBins{curl};
}

sub _getWgetCmd {
	return $helperBins{wget} if $helperBins{wget};
	
	if ( my $wget = Slim::Utils::Misc::findbin('wget') ) {
		$helperBins{wget} = $wget;
	}
	else {
		$log->error("Can't initialized Spotty Connect without the 'wget' utility. Please install curl using your package manager.") unless defined $helperBins{wget};
		$helperBins{wget} = '';
	}

	return $helperBins{wget};
}

sub _getPVcmd {
	return $helperBins{pv} if $helperBins{pv};
	
	if ( my $pv = Slim::Utils::Misc::findbin('pv') ) {
		$helperBins{pv} = sprintf('| %s -L20k -B10k -q', $pv);
	}
	else {
		$log->error("Didn't find the pv (pipe viewer) utility. Please install pv using your package manager") unless defined $helperBins{pv};
		$helperBins{pv} = '';
	}

	return $helperBins{pv};
}

sub stopHelper {
	my ($class, $clientId) = @_;
	
	my $helper = $helperInstances{$clientId};
	
	if ($helper && $helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting Spotty Connect daemon for $clientId");
		$helper->die;
	}
}

sub shutdownHelpers {
	my ($class, $inactiveOnly) = @_;
	
	my %clientIds = map { $_->id => 1 } Slim::Player::Client::clients() if $inactiveOnly;
	
	foreach my $clientId ( keys %helperInstances ) {
		next if $clientIds{$clientId};
		$class->stopHelper($clientId);
	}
}

1;
package Plugins::Spotty::Connect;

use strict;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

my $prefs = preferences('plugin.spotty');
my $log = logger('network.asynchttp');

sub init {
	my ($class, $helper) = @_;

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
}

sub isSpotifyConnect {
	my ( $class, $client ) = @_;
	return $client->master->pluginData('SpotifyConnect');
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;
	
	my $client = $song->master;

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);			

	if ( $client->pluginData('newTrack') ) {
		main::INFOLOG && $log->is_info && $log->info("Don't get next track as we got called by a play track event from spotty");
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

	return if $request->source && $request->source eq __PACKAGE__;
	
	main::INFOLOG && $log->is_info && $log->info("Got a new track event, but this is no longer Spotify Connect");
	$client->master->pluginData( SpotifyConnect => 0 );
}

sub _onPause {
	my $request = shift;
	my $client  = $request->client();

	return if !defined $client;
	$client = $client->master;

	return if !$client->pluginData('SpotifyConnect');
	
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
		
		my $streamUrl = $client->playingSong()->streamUrl || '';
		$streamUrl =~ s/\/\///;
		
		$result ||= {};
		
		# in case of a change event we need to figure out what actually changed...
		if ( $cmd eq 'stop' && $result && ref $result && $streamUrl ne $result->{track}->{uri} && $result->{is_playing} ) {
			main::INFOLOG && $log->is_info && $log->info("Got a $cmd event, but actually this is a play next track event");
			$cmd = 'play';
		}

		if ( $cmd eq 'play' && $result->{track} ) {
			if ( $streamUrl ne $result->{track}->{uri} ) {
				main::INFOLOG && $log->is_info && $log->info("Got a new track to be played: " . $result->{track}->{uri});

				# Sometimes we want to know whether we're in Spotify Connect mode or not
				$client->pluginData( SpotifyConnect => 1 );
				$client->pluginData( newTrack => 1 );

				my $request = $client->execute( [ 'playlist', 'play', $result->{track}->{uri} ] );
				$request->source($class);
			}
			elsif ( !$client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Got to resume playback");
				$client->execute(['play']);
			}
		}
		elsif ( $cmd eq 'stop' && $result->{device} ) {
			if ( $client->isPlaying ) {
				$client->execute(['pause']);
			} 
		}
		
	});
}

1;
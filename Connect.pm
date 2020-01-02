package Plugins::Spotty::Connect;

use strict;

use File::Path qw(mkpath);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::API qw(uri2url);

use constant CONNECT_HELPER_VERSION => '0.12.0';
use constant SEEK_THRESHOLD => 3;
use constant VOLUME_GRACE_PERIOD => 5;
use constant PRE_BUFFER_TIME => 7;
use constant PRE_BUFFER_SIZE_THRESHOLD => 10 * 1024 * 1024;

my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my $initialized;

sub init {
	my ($class) = @_;

	return if $initialized;

	return unless $class->canSpotifyConnect('dontInit');

	require Plugins::Spotty::Connect::Context;

#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch(['spottyconnect','_cmd'],
	                                                            [1, 0, 1, \&_connectEvent]
	);

	# listen to playlist change events so we know when Spotify Connect mode ends
	Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);

	# we want to tell the Spotify controller to pause playback when we pause locally
	Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);

	# we want to tell the Spotify about local volume changes
	Slim::Control::Request::subscribe(\&_onVolume, [['mixer'], ['volume']]);

	# set optimizePreBuffer if client with huge buffer connects
	Slim::Control::Request::subscribe(sub {
		my $request = shift;
		my $client  = $request->client();

		if (!$prefs->get('optimizePreBuffer')) {
			# we have to wait a few seconds before the buffer size is known
			Slim::Utils::Timers::setTimer($client, time() + 5, sub {
				if ($client->bufferSize > PRE_BUFFER_SIZE_THRESHOLD) {
					main::INFOLOG && $log->is_info && $log->info(sprintf("Enabling pre-buffer optimization as player seems to be using very large buffer: %s (%sMB)", $client->name, int($client->bufferSize/1024/1024)));
					$prefs->set('optimizePreBuffer', 1);
				}
			});
		}
	}, [['client'], ['new']]);

	require Plugins::Spotty::Connect::DaemonManager;
	Plugins::Spotty::Connect::DaemonManager->init();

	$initialized = 1;
}

sub canSpotifyConnect {
	my ($class, $dontInit) = @_;

	# we need a minimum helper application version
	if ( !Slim::Utils::Versions->checkVersion(Plugins::Spotty::Helper->getVersion(), CONNECT_HELPER_VERSION, 10) ) {
		$log->error("Cannot support Spotty Connect, need at least helper version " . CONNECT_HELPER_VERSION);
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

	return unless $client->pluginData('SpotifyConnect');

	return ($client->pluginData('newTrack') || _contextTime($song)) ? 1 : 0;
}

sub _contextTime {
	my ($song) = @_;

	return unless $song && $song->pluginData('context');
	return $song->pluginData('context')->time() || 0;
}

sub setSpotifyConnect {
	my ( $class, $client, $context ) = @_;

	return unless $client;

	$client = $client->master;
	my $song = $client->playingSong();

	# state on song: need to know whether we're currently in Connect mode. Is lost when new track plays.
	$song->pluginData('context') || $song->pluginData( context => Plugins::Spotty::Connect::Context->new($class->getAPIHandler($client)) );
	$song->pluginData('context')->update($context);
	$song->pluginData('context')->time(time());

	# state on client: need to know whether we've been in Connect mode. If this is set, then we've been playing from Connect, but are no more.
	$client->pluginData( SpotifyConnect => 1 );
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $client = $song->master;

	Slim::Utils::Timers::killTimers($client, \&_getNextTrack);

	if ( $client->pluginData('newTrack') ) {
		main::INFOLOG && $log->is_info && $log->info("Don't get next track as we got called by a play track event from spotty");

		my $spotty = $class->getAPIHandler($client);

		$spotty->player(sub {
			my $state = $_[0];

			if ( !$state->{item} && (my $uri = $client->pluginData('episodeUri')) ) {
				$state->{item} = {
					uri => $uri
				};
				$client->pluginData( episodeUri => '' );

				$spotty->track(sub {
					$state->{item} = $_[0];
					$class->setSpotifyConnect($client, $state);
				}, $uri);
			}

			$song->streamUrl($state->{item}->{uri});
			$class->setSpotifyConnect($client, $state);
			$client->pluginData( newTrack => 0 );
			$successCb->();
		});
	}
	elsif ( $prefs->get('optimizePreBuffer') ) {
		my $duration  = $client->controller()->playingSongDuration() || 0;
		my $remaining = $duration - (Slim::Player::Source::songTime($client) || 0);

		main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump({
			duration => $duration,
			remaining => $remaining,
			current_url => $song->streamUrl,
		}));

		if ($remaining && $remaining > PRE_BUFFER_TIME) {
			$remaining -= PRE_BUFFER_TIME;
			main::INFOLOG && $log->is_info && $log->info("We're still far away from the end - delay getting the next track by ${remaining}s.");
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining, \&_getNextTrack, $class, $song, $successCb);

			Slim::Utils::Timers::killTimers($client, \&_syncController);
			if ($remaining > 20) {
				Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining - 15, \&_syncController);
			}
		}
		elsif (!$duration || !$remaining) {
			main::INFOLOG && $log->is_info && $log->info("Ignoring 'getNextTrack' call, as we've been called before");
		}
		else {
			_getNextTrack($client, $class, $song, $successCb);
		}
	}
	else {
		_getNextTrack($client, $class, $song, $successCb);
	}
}

sub _getNextTrack {
	# params kind of reversed, to help the timer keep track of the client
	my ($client, $class, $song, $successCb) = @_;

	Slim::Utils::Timers::killTimers($client, \&_syncController);
	Slim::Utils::Timers::killTimers($client, \&_getNextTrack);

	if (!$client->isPlaying() || !$class->isSpotifyConnect($client)) {
		main::INFOLOG && $log->is_info && $log->info("Don't get next track, we're no longer playing or not in Connect mode");
		return;
	}

	my $spotty = $class->getAPIHandler($client);

	main::INFOLOG && $log->is_info && $log->info("We're approaching the end of a track - get the next track");
	$client->pluginData( newTrack => 1 );

	# add current track to the history
	$song->pluginData('context')->addPlay($song->streamUrl);

	# for playlists and albums we can know the last track. In this case no further check would be required.
	if ( $song->pluginData('context')->isLastTrack($song->streamUrl) ) {
		$class->_delayedStop($client);
		$successCb->();
		return;
	}

	$spotty->playerNext(sub {
		$spotty->player(sub {
			my ($result) = @_;

			if ( $result && ref $result && (my $uri = $result->{item}->{uri}) ) {
				main::INFOLOG && $log->is_info && $log->info("Got a new track to be played next: $uri");

				$uri = uri2url($uri);

				# stop playback if we've played this track before. It's likely trying to start over.
				if ( $song->pluginData('context')->hasPlay($uri) && !($result->{repeat_state} && $result->{repeat_state} eq 'on')) {
					$class->_delayedStop($client);
				}
				else {
					$song->streamUrl($uri);
					$class->setSpotifyConnect($client, $result);
				}

				$successCb->();
			}
		});
	});
}

sub _syncController {
	my ($client) = @_;

	Slim::Utils::Timers::killTimers($client, \&_syncController);

	my $songtime = Slim::Player::Source::songTime($client);

	__PACKAGE__->getAPIHandler($client)->playerSeek(undef, $client->id, $songtime) if $songtime;
}

sub _delayedStop {
	my ($class, $client) = @_;

	# set a timer to stop playback at the end of the track
	my $remaining = $client->controller()->playingSongDuration() - Slim::Player::Source::songTime($client);
	main::INFOLOG && $log->is_info && $log->info("Stopping playback in ${remaining}s, as we have likely reached the end of our context (playlist, album, ...)");

	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining, sub {
		$client->pluginData( newTrack => 0 );
		$class->getAPIHandler($client)->playerPause(sub {
			$client->execute(['stop']);
		}, $client->id);
	});
}

sub _onNewSong {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client  = $request->client();
	return if !defined $client;
	$client = $client->master;

	if (__PACKAGE__->isSpotifyConnect($client)) {
		# if we're in Connect mode and have seek information, go there
		if ( $client && (my $progress = $client->pluginData('progress')) ) {
			$client->pluginData( progress => 0 );
			$client->execute( ['time', int($progress)] );
		}

		return;
	}

	return unless $client->pluginData('SpotifyConnect');

	main::INFOLOG && $log->is_info && $log->info("Got a new track event, but this is no longer Spotify Connect");
	$client->playingSong()->pluginData( context => 0 );
	$client->pluginData( SpotifyConnect => 0 );
	Slim::Utils::Timers::killTimers($client, \&_syncController);
	Slim::Utils::Timers::killTimers($client, \&_getNextTrack);
	__PACKAGE__->getAPIHandler($client)->playerPause(undef, $client->id);
}

sub _onPause {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	# no need to pause if we unpause
	return if $request->isCommand([['playlist'],['pause']]) && !$request->getParam('_newvalue');

	my $client  = $request->client();
	return if !defined $client;
	$client = $client->master;

	# ignore pause while we're fetching a new track
	return if $client->pluginData('newTrack');

	return if !__PACKAGE__->isSpotifyConnect($client);

	if ( $request->isCommand([['playlist'],['stop','pause']]) && _contextTime($client->playingSong()) > time() - 5 ) {
		main::INFOLOG && $log->is_info && $log->info("Got a stop event within 5s after start of a new track - do NOT tell Spotify Connect controller to pause");
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("Got a pause event - tell Spotify Connect controller to pause, too");
	__PACKAGE__->getAPIHandler($client)->playerPause(undef, $client->id);
}

sub _onVolume {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client  = $request->client();
	return if !defined $client;
	$client = $client->master;

	return if !__PACKAGE__->isSpotifyConnect($client);

	my $volume = $client->volume;

	# buffer volume change events, as they often come in bursts
	Slim::Utils::Timers::killTimers($client, \&_bufferedSetVolume);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, \&_bufferedSetVolume, $volume);
}

sub _bufferedSetVolume {
	my ($client, $volume) = @_;
	main::INFOLOG && $log->is_info && $log->info("Got a volume event - tell Spotify Connect controller to adjust volume, too: $volume");
	__PACKAGE__->getAPIHandler($client)->playerVolume(undef, $client->id, $volume);
}

sub _connectEvent {
	my $request = shift;
	my $client = $request->client()->master;

	my $cmd = $request->getParam('_cmd');

	if ( $client->pluginData('newTrack') ) {
		main::INFOLOG && $log->info("Ignoring request, as it's a follow up to a new track event: $cmd");
		$client->pluginData( newTrack => 0 );
		return;
	}

	main::INFOLOG && $log->is_info && $log->info("Got called from spotty helper: $cmd");

	my $spotty = __PACKAGE__->getAPIHandler($client);

	if ( $cmd eq 'volume' && !($request->source && $request->source eq __PACKAGE__) ) {
		my $volume = $request->getParam('_p2') || return;

		# sometimes volume would be reset to a default 50 right after the daemon start - ignore
		if ( $volume == 50 && Plugins::Spotty::Connect::DaemonManager->uptime($client->id) < VOLUME_GRACE_PERIOD ) {
			main::INFOLOG && $log->is_info && $log->info("Ignoring initial volume reset right after daemon start");
			# this is kind of the "onConnect" handler - get a list of all players
			$spotty->devices();
			return;
		}

		main::INFOLOG && $log->is_info && $log->info("Set volume to $volume");

		# we don't let spotty handle volume directly to prevent getting caught in a call loop
		my $request = Slim::Control::Request->new( $client->id, [ 'mixer', 'volume', $volume ] );
		$request->source(__PACKAGE__);
		$request->execute();

		return;
	}

	$spotty->player(sub {
		my ($result) = @_;

		my $song = $client->playingSong();
		my $streamUrl = ($song ? $song->streamUrl : '') || '';
		$streamUrl =~ s/\/\///;

		$song && $song->pluginData('context') && $song->pluginData('context')->update($result);

		$result ||= {};

		main::INFOLOG && $log->is_info && $log->info("Current Connect state: \n" . Data::Dump::dump($result, $cmd));

		# the spotty helper would send us the track ID, but unfortunately not the full URI. Let's assume this was an episode ID if we're currently in an episode and got an ID...
		if ( $cmd =~ /^start|change$/ && ($result->{currently_playing_type} || '') eq 'episode' && !$result->{track} && (my $uri = $request->getParam('_p2')) ) {
			$uri = "spotify:episode:$uri";
			main::INFOLOG && $log->is_info && $log->info("Didn't get track info in player request, but in notification from spotty helper: $uri");
			$result->{track} = {
				uri => $uri
			};
		}

		# in case of a change event we need to figure out what actually changed...
		if ( $cmd eq 'change' && $result && ref $result && ref $result->{track} && (($streamUrl ne $result->{track}->{uri} && $result->{is_playing}) || !__PACKAGE__->isSpotifyConnect($client)) ) {
			main::INFOLOG && $log->is_info && $log->info("Got a $cmd event, but actually this is a play next track event");
			$cmd = 'start';
		}

		if ( $cmd eq 'start' && $result->{track} ) {
			if ( $streamUrl ne $result->{track}->{uri} || !__PACKAGE__->isSpotifyConnect($client) ) {
				main::INFOLOG && $log->is_info && $log->info("Got a new track to be played: " . $result->{track}->{uri});

				# Sometimes we want to know whether we're in Spotify Connect mode or not
				$client->pluginData( SpotifyConnect => 1 );
				$client->pluginData( newTrack => 1 );

				# we need to keep track of the episodeUri, as it won't be sent in the player status response. Stupid.
				$client->pluginData( episodeUri => $result->{track}->{uri}) if ($result->{currently_playing_type} || '') eq 'episode';

				my $request = $client->execute( [ 'playlist', 'play', sprintf("spotify://connect-%u", Time::HiRes::time() * 1000) ] );
				$request->source(__PACKAGE__);

				# sync volume up to spotify if we just got connected
				if ( !$client->pluginData('SpotifyConnect') ) {
					$spotty->playerVolume(undef, $client->id, $client->volume);
				}

				# on interactive Spotify Connect use we're going to reset the play history.
				# this isn't really solving the problem of lack of context. But it's better than nothing...
				$song && $song->pluginData('context') && $song->pluginData('context')->reset();

				$result->{progress} ||= ($result->{progress_ms} / 1000) if $result->{progress_ms};

				# if status is already more than 10s in, then do seek
				if ( $result->{progress} && $result->{progress} > 10 ) {
					$song && $client->pluginData( progress => $result->{progress} );
				}
			}
			elsif ( !$client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Got to resume playback");
				__PACKAGE__->setSpotifyConnect($client, $result);
				my $request = Slim::Control::Request->new( $client->id, ['play'] );
				$request->source(__PACKAGE__);
				$request->execute();
			}
		}
		elsif ( $cmd eq 'stop' && $result->{device} ) {
			my $clientId = $client->id;

			# if we're playing, got a stop event, and current Connect device is us, then pause
			if ( $client->isPlaying && ($result->{device}->{id} eq Plugins::Spotty::Connect::DaemonManager->idFromMac($clientId) || $result->{device}->{name} eq $client->name) && __PACKAGE__->isSpotifyConnect($client) ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause: " . $client->id);

				my $request = Slim::Control::Request->new( $client->id, ['pause', 1] );
				$request->source(__PACKAGE__);
				$request->execute();
			}
			elsif ( $client->isPlaying && ($result->{device}->{id} ne Plugins::Spotty::Connect::DaemonManager->idFromMac($clientId) && $result->{device}->{name} ne $client->name) && __PACKAGE__->isSpotifyConnect($client) ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause, but current player is no longer the Connect target");

				my $request = Slim::Control::Request->new( $client->id, ['pause', 1] );
				$request->source(__PACKAGE__);
				$request->execute();

				# reset Connect status on this device
				$client->playingSong()->pluginData( context => 0 );
				$client->pluginData( SpotifyConnect => 0 );
			}
			# if we're playing, got a stop event, and current Connect device is NOT us, then
			# disable Connect and let the track end
			elsif ( $client->isPlaying ) {
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause, but current player is not Connect target");
				$client->playingSong()->pluginData( context => 0 );
				$client->pluginData( SpotifyConnect => 0 );
			}
		}
		elsif ( $cmd eq 'change' ) {
			# seeking event from Spotify - we would only seek if the difference was larger than x seconds, as we'll never be perfectly in sync
			if ( $client->isPlaying && abs($result->{progress} - Slim::Player::Source::songTime($client)) > SEEK_THRESHOLD ) {
				$client->execute( ['time', int($result->{progress})] );
			}
		}
		elsif (main::INFOLOG && $log->is_info) {
			$log->info("Unknown command called? $cmd\n" . Data::Dump::dump($result));
		}
	});
}

=pod
	Here we're overriding some of the default handlers. In Connect mode, when discovery is enabled,
	we could be streaming from any account, not only those configured in Spotty. Therefore we need
	to use different cache folders with credentials. Use the currently set in Spotty as default,
	but read actual value whenever accessing the API. We won't keep these credentials around, to
	prevent using a visitor's account.
=cut
sub getAPIHandler {
	my ($class, $client) = @_;

	return unless $client;

	if (!blessed $client) {
		$client = Slim::Player::Client::getClient($client);
	}

	my $api;

	my $cacheFolder = $class->cacheFolder($client);
	my $credentialsFile = catfile($cacheFolder, 'credentials.json');

	my $credentials = eval {
		from_json(read_file($credentialsFile));
	};

	if ( !$@ && $credentials || ref $credentials && $credentials->{auth_data} ) {
		$api = Plugins::Spotty::API->new({
			client => $client,
			cache => $cacheFolder,
			username => $credentials->{username},
		});
	}

	return $api || Plugins::Spotty::Plugin->getAPIHandler($client);
}

sub cacheFolder {
	my ($class, $clientId) = @_;

	$clientId = $clientId->id if $clientId && blessed $clientId;

	my $cacheFolder = Plugins::Spotty::AccountHelper->cacheFolder( Plugins::Spotty::AccountHelper->getAccount($clientId) );

	# create a temporary account folder with the player's MAC address
	if ( Plugins::Spotty::Plugin->canDiscovery() && !$prefs->get('disableDiscovery') ) {
		my $id = $clientId;
		$id =~ s/://g;

		my $playerCacheFolder = catdir(preferences('server')->get('cachedir'), 'spotty', $id);
		mkpath $playerCacheFolder unless -e $playerCacheFolder;

		if ( !-e catfile($playerCacheFolder, 'credentials.json') ) {
			require File::Copy;
			File::Copy::copy(catfile($cacheFolder, 'credentials.json'), catfile($playerCacheFolder, 'credentials.json'));
		}
		$cacheFolder = $playerCacheFolder;
	}

	return $cacheFolder
}

sub shutdown {
	if ($initialized) {
		Plugins::Spotty::Connect::DaemonManager->shutdown();
	}
}

1;
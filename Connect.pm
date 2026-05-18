package Plugins::Spotty::Connect;

use strict;

use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);
use Time::HiRes;

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
use Slim::Utils::Timers;

use Plugins::Spotty::API qw(uri2url);

# Seconds; delta threshold to trigger a seek on change events
use constant SEEK_THRESHOLD => 3;

# Seconds; CON-07 — ignore volume events within this window after daemon start.
# Plan B's suppress_next_volume AtomicBool handles the very first VolumeChanged after
# SessionConnected. This grace period suppresses subsequent echoes during session setup.
use constant VOLUME_GRACE_PERIOD => 20;

# Seconds; pre-buffer optimisation lookahead
use constant PRE_BUFFER_TIME => 7;

# Bytes; threshold for the large-buffer pre-buffer optimisation
use constant PRE_BUFFER_SIZE_THRESHOLD => 10 * 1024 * 1024;

my $prefs       = preferences('plugin.spotty');
my $serverPrefs = preferences('server');
my $log         = logger('plugin.spotty');

my $initialized;

# ---------------------------------------------------------------------------
# Public API
# ---------------------------------------------------------------------------

sub init {
	my ($class) = @_;

	return if $initialized;

	require Plugins::Spotty::Connect::Context;

	#                                                                |requires Client
	#                                                                |  |is a Query
	#                                                                |  |  |has Tags
	#                                                                |  |  |  |Function to call
	#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch(['spottyconnect', '_cmd'],
	                                                            [1, 0, 1, \&_connectEvent]
	);

	# Listen to playlist change events so we know when Spotify Connect mode ends
	Slim::Control::Request::subscribe(\&_onNewSong, [['playlist'], ['newsong']]);

	# Tell the Spotify controller to pause playback when we pause locally (D-05)
	Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);

	# Forward local volume changes to Spotify (D-05)
	Slim::Control::Request::subscribe(\&_onVolume, [['mixer'], ['volume']]);

	# Forward local seeks to Spotify so the app stays in sync
	Slim::Control::Request::subscribe(\&_onSeek, [['time']]);

	# Enable pre-buffer optimisation for players with very large buffers
	Slim::Control::Request::subscribe(sub {
		my $request = shift;
		my $client  = $request->client();

		if (!$prefs->get('optimizePreBuffer')) {
			# Wait a few seconds before the buffer size is known
			Slim::Utils::Timers::setTimer($client, time() + 5, sub {
				my $c = shift;
				if ($c && $c->bufferSize > PRE_BUFFER_SIZE_THRESHOLD) {
					main::INFOLOG && $log->is_info && $log->info(sprintf(
						"Enabling pre-buffer optimization as player seems to be using very large buffer: %s (%sMB)",
						$c->name, int($c->bufferSize / 1024 / 1024)
					));
					$prefs->set('optimizePreBuffer', 1);
				}
			});
		}
	}, [['client'], ['new']]);

	require Plugins::Spotty::Connect::DaemonManager;
	Plugins::Spotty::Connect::DaemonManager->init();

	$initialized = 1;
}

sub isSpotifyConnect {
	my ($class, $client) = @_;

	return unless $client;
	$client = $client->master;
	my $song = $client->playingSong();

	return unless $client->pluginData('SpotifyConnect');

	return ($client->pluginData('newTrack') || _contextTime($song)) ? 1 : 0;
}

sub setSpotifyConnect {
	my ($class, $client, $context) = @_;

	return unless $client;

	$client = $client->master;
	if (my $song = $client->playingSong()) {
		# State on song: need to know whether we're currently in Connect mode.
		# Lost when a new track plays.
		$song->pluginData('context') || $song->pluginData(
			context => Plugins::Spotty::Connect::Context->new($class->getAPIHandler($client))
		);
		$song->pluginData('context')->update($context);
		$song->pluginData('context')->time(time());
	}

	# State on client: remember whether we've ever been in Connect mode.
	$client->pluginData(SpotifyConnect => 1);
}

sub getNextTrack {
	my ($class, $song, $successCb, $errorCb) = @_;

	my $client = $song->master;

	Slim::Utils::Timers::killTimers($client, \&_getNextTrack);

	if ($client->pluginData('newTrack')) {
		main::INFOLOG && $log->is_info && $log->info(
			"Don't get next track as we got called by a play track event from spotty"
		);

		my $spotty = $class->getAPIHandler($client);

		$spotty->player(sub {
			my $state = $_[0];

			if (!$state->{item} && (my $uri = $client->pluginData('episodeUri'))) {
				$state->{item} = { uri => $uri };
				$client->pluginData(episodeUri => '');

				$spotty->track(sub {
					$state->{item} = $_[0];
					$class->setSpotifyConnect($client, $state);
				}, $uri);
			}

			$song->streamUrl($state->{item}->{uri});
			$class->setSpotifyConnect($client, $state);
			$client->pluginData(newTrack => 0);
			$successCb->();
		});
	}
	elsif ($prefs->get('optimizePreBuffer')) {
		my $duration  = $client->controller()->playingSongDuration() || 0;
		my $remaining = $duration - (Slim::Player::Source::songTime($client) || 0);

		main::INFOLOG && $log->is_info && $log->info(sprintf(
			"Optimized pre-buffer: duration=%s remaining=%s url=%s",
			$duration, $remaining, $song->streamUrl
		));

		if ($remaining && $remaining > PRE_BUFFER_TIME) {
			$remaining -= PRE_BUFFER_TIME;
			main::INFOLOG && $log->is_info && $log->info(
				"We're still far away from the end - delay getting the next track by ${remaining}s."
			);
			Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining,
				\&_getNextTrack, $class, $song, $successCb);

			Slim::Utils::Timers::killTimers($client, \&_syncController);
			if ($remaining > 20) {
				Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining - 15,
					\&_syncController);
			}
		}
		elsif (!$duration || !$remaining) {
			main::INFOLOG && $log->is_info && $log->info(
				"Ignoring 'getNextTrack' call, as we've been called before"
			);
		}
		else {
			_getNextTrack($client, $class, $song, $successCb);
		}
	}
	else {
		_getNextTrack($client, $class, $song, $successCb);
	}
}

sub getAPIHandler {
	my ($class, $client) = @_;

	return unless $client;

	if (!blessed $client) {
		$client = Slim::Player::Client::getClient($client);
	}

	return unless $client;

	my $cacheFolder     = $class->cacheFolder($client);
	my $credentialsFile = catfile($cacheFolder, 'credentials.json');

	my $credentials = eval {
		from_json(do { local $/; open(my $fh, '<', $credentialsFile) or die $!; <$fh> });
	};

	if (!$@ && $credentials && ref $credentials && $credentials->{auth_data}) {
		return Plugins::Spotty::API->new({
			client   => $client,
			cache    => $cacheFolder,
			username => $credentials->{username},
		});
	}

	return Plugins::Spotty::Plugin->getAPIHandler($client);
}

sub cacheFolder {
	my ($class, $clientId) = @_;

	$clientId = $clientId->id if $clientId && blessed $clientId;

	my $cacheFolder = Plugins::Spotty::AccountHelper->cacheFolder(
		Plugins::Spotty::AccountHelper->getAccount($clientId)
	);

	# Per-player credentials folder — always created regardless of discovery mode.
	# REG-02: prevents the Connect daemon from writing to the main account folder
	# (which --single-track streaming processes share).
	if ($clientId) {
		my $id = $clientId;
		$id =~ s/://g;

		my $playerCacheFolder = catdir($serverPrefs->get('cachedir'), 'spotty', $id);
		mkpath $playerCacheFolder unless -e $playerCacheFolder;

		if (!-e catfile($playerCacheFolder, 'credentials.json')) {
			require File::Copy;
			File::Copy::copy(
				catfile($cacheFolder, 'credentials.json'),
				catfile($playerCacheFolder, 'credentials.json')
			);
		}
		$cacheFolder = $playerCacheFolder;
	}

	return $cacheFolder;
}

sub shutdown {
	if ($initialized) {
		require Plugins::Spotty::Connect::DaemonManager;
		Plugins::Spotty::Connect::DaemonManager->shutdown();

		Slim::Control::Request::unsubscribe(\&_onNewSong);
		Slim::Control::Request::unsubscribe(\&_onPause);
		Slim::Control::Request::unsubscribe(\&_onVolume);
		Slim::Control::Request::unsubscribe(\&_onSeek);

		$initialized = 0;
	}
}

# ---------------------------------------------------------------------------
# Private helpers
# ---------------------------------------------------------------------------

sub _contextTime {
	my ($song) = @_;

	return unless $song && $song->pluginData('context');
	return $song->pluginData('context')->time() || 0;
}

# Called when we're approaching the end of a track in optimizePreBuffer mode
sub _getNextTrack {
	# Params reversed so timers can track by client
	my ($client, $class, $song, $successCb) = @_;

	Slim::Utils::Timers::killTimers($client, \&_syncController);
	Slim::Utils::Timers::killTimers($client, \&_getNextTrack);
	Slim::Utils::Timers::killTimers($client, \&_firePlayerNext);


	if (!$client->isPlaying() || !$class->isSpotifyConnect($client)) {
		main::INFOLOG && $log->is_info && $log->info(
			"Don't get next track, we're no longer playing or not in Connect mode"
		);
		return;
	}

	my $spotty = $class->getAPIHandler($client);

	main::INFOLOG && $log->is_info && $log->info("We're approaching the end of a track - get the next track");
	$client->pluginData(newTrack => 1);

	# Add current track to history
	$song->pluginData('context')->addPlay($song->streamUrl);

	# For playlists/albums we may know the last track — stop if so and no autoplay
	if ($song->pluginData('context')->isLastTrack($song->streamUrl)
		&& !($spotty->can('doesAutoplay') && $spotty->doesAutoplay))
	{
		$class->_delayedStop($client);
		$successCb->();
		return;
	}

	# Peek at the queue to find the next track for pre-buffering, then schedule
	# playerNext at track end to advance Spotify in sync with LMS.
	$spotty->playerQueue(sub {
		my ($nextItem) = @_;

		$client->pluginData(newTrack => 0);

		if ($nextItem && (my $uri = $nextItem->{uri})) {
			my $url = uri2url($uri);

			main::INFOLOG && $log->is_info && $log->info("Queue peek: next track is $uri");

			if ($song->pluginData('context')->hasPlay($url)) {
				$class->_delayedStop($client);
			}
			else {
				$song->streamUrl($uri);

				# Schedule playerNext to fire when the track actually ends,
				# so Spotify advances in sync with LMS.
				my $remaining = ($client->controller()->playingSongDuration() || 0)
					- (Slim::Player::Source::songTime($client) || 0);
				if ($remaining > 0) {
					main::INFOLOG && $log->is_info && $log->info(
						"Scheduling playerNext in ${remaining}s (at track end)"
					);
					Slim::Utils::Timers::killTimers($client, \&_firePlayerNext);
					Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining,
						\&_firePlayerNext, $spotty);
				}
			}

			$successCb->();
		}
		else {
			main::INFOLOG && $log->is_info && $log->info("Queue empty — end of context");
			$class->_delayedStop($client);
			$successCb->();
		}
	});
}

sub _firePlayerNext {
	my ($client, $spotty) = @_;
	Slim::Utils::Timers::killTimers($client, \&_firePlayerNext);
	main::INFOLOG && $log->is_info && $log->info("Advancing Spotify to next track (at track end)");
	$spotty->playerNext(undef);
}

sub _syncController {
	my ($client) = @_;

	Slim::Utils::Timers::killTimers($client, \&_syncController);

	my $songtime = Slim::Player::Source::songTime($client);
	__PACKAGE__->getAPIHandler($client)->playerSeek(undef, $client->id, $songtime) if $songtime;
}

sub _delayedStop {
	my ($class, $client) = @_;

	my $remaining = $client->controller()->playingSongDuration()
		- Slim::Player::Source::songTime($client);
	main::INFOLOG && $log->is_info && $log->info(
		"Stopping playback in ${remaining}s, as we have likely reached the end of our context"
	);

	Slim::Utils::Timers::killTimers($client, \&_sendPause);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + $remaining, \&_sendPause, $class);
}

sub _sendPause {
	my $client = shift || return;
	my $class  = shift;

	Slim::Utils::Timers::killTimers($client, \&_sendPause);
	$client->pluginData(newTrack => 0);
	$class->getAPIHandler($client)->playerPause(sub {
		my $stopReq = Slim::Control::Request->new($client->id, ['stop']);
		$stopReq->source(__PACKAGE__);
		$stopReq->execute();
	}, $client->id);
}

# ---------------------------------------------------------------------------
# Event subscribers
# ---------------------------------------------------------------------------

sub _onNewSong {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client = $request->client();
	return if !defined $client;
	$client = $client->master;

	if (__PACKAGE__->isSpotifyConnect($client)) {
		# If we're in Connect mode and have a seek position, go there
		if ($client && (my $progress = $client->pluginData('progress'))) {
			$client->pluginData(progress => 0);
			$client->execute(['time', int($progress)]);
		}
		return;
	}

	return unless $client->pluginData('SpotifyConnect');

	main::INFOLOG && $log->is_info && $log->info(
		"Got a new track event, but this is no longer Spotify Connect"
	);
	$client->playingSong()->pluginData(context => 0);
	$client->pluginData(SpotifyConnect => 0);
	Slim::Utils::Timers::killTimers($client, \&_syncController);
	Slim::Utils::Timers::killTimers($client, \&_getNextTrack);

	__PACKAGE__->getAPIHandler($client)->playerPause(undef, $client->id);
}

sub _onPause {
	my $request = shift;

	# Source-marking loop prevention (Pattern 2): skip our own requests
	return if $request->source && $request->source eq __PACKAGE__;

	# No need to forward if this is an unpause
	return if $request->isCommand([['playlist'], ['pause']]) && !$request->getParam('_newvalue');

	my $client = $request->client();
	return if !defined $client;
	$client = $client->master;

	# Ignore pause while we're fetching a new track
	return if $client->pluginData('newTrack');

	return if !__PACKAGE__->isSpotifyConnect($client);

	# Ignore stop events arriving within 5s of a new track start (race between
	# start-event processing and LMS stop-before-play sequence)
	if ($request->isCommand([['playlist'], ['stop', 'pause']])
		&& _contextTime($client->playingSong()) > time() - 5)
	{
		main::INFOLOG && $log->is_info && $log->info(
			"Got a stop event within 5s after start of a new track - do NOT tell Spotify Connect controller to pause"
		);
		return;
	}

	main::INFOLOG && $log->is_info && $log->info(
		"Got a pause event - tell Spotify Connect controller to pause, too"
	);
	__PACKAGE__->getAPIHandler($client)->playerPause(undef, $client->id);
}

sub _onVolume {
	my $request = shift;

	# Source-marking loop prevention (Pattern 2, T-08-08): skip our own requests
	if ($request->source && $request->source eq __PACKAGE__) {
		main::DEBUGLOG && $log->is_debug && $log->debug("_onVolume: skipping own source");
		return;
	}

	my $client = $request->client();
	if (!defined $client) {
		main::DEBUGLOG && $log->is_debug && $log->debug("_onVolume: no client");
		return;
	}

	$client = $client->master;

	if (!__PACKAGE__->isSpotifyConnect($client)) {
		main::DEBUGLOG && $log->is_debug && $log->debug("_onVolume: not in Connect mode for " . $client->id);
		return;
	}

	my $volume = $client->volume;

	# Buffer volume change events, as they often come in bursts (0.5s debounce)
	Slim::Utils::Timers::killTimers($client, \&_bufferedSetVolume);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.5, \&_bufferedSetVolume, $volume);
}

sub _bufferedSetVolume {
	my ($client, $volume) = @_;
	main::INFOLOG && $log->is_info && $log->info(
		"Got a volume event - tell Spotify Connect controller to adjust volume, too: $volume"
	);
	__PACKAGE__->getAPIHandler($client)->playerVolume(undef, $client->id, $volume);
}

sub _onSeek {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client = $request->client();
	return if !defined $client;
	$client = $client->master;

	return if $client->pluginData('newTrack');

	return if !__PACKAGE__->isSpotifyConnect($client);

	my $position = Slim::Player::Source::songTime($client) || 0;

	Slim::Utils::Timers::killTimers($client, \&_bufferedSeek);
	Slim::Utils::Timers::setTimer($client, Time::HiRes::time() + 0.3, \&_bufferedSeek, $position);
}

sub _bufferedSeek {
	my ($client, $position) = @_;
	main::INFOLOG && $log->is_info && $log->info(
		"Forwarding LMS seek to Spotify Connect: ${position}s"
	);
	__PACKAGE__->getAPIHandler($client)->playerSeek(undef, $client->id, $position);
}

# ---------------------------------------------------------------------------
# spottyconnect JSON-RPC dispatch handler
#
# Wire vocabulary (Plan B Binary, librespot/src/spotty.rs):
#   start  — new track begins (None -> Some);  p1=track_id(base62), p2=""
#   change — track changes mid-playback;        p1=new_track_id, p2=previous_track_id
#   stop   — PlayerEvent::Paused OR Stopped;    p1="", p2=""  (NOTE: no 'pause' event)
#   volume — VolumeChanged (after suppress);    p1=volume 0-100, p2=""
#   seek   — Seeked mid-playback;               p1=position in seconds (3 decimals), p2=""
# ---------------------------------------------------------------------------
sub _connectEvent {
	my $request = shift;
	my $client  = $request->client()->master;

	my $cmd = $request->getParam('_cmd');

	main::INFOLOG && $log->is_info && $log->info(sprintf(
		'Got called from spotty helper for %s: %s', $client->id, $cmd
	));

	# Volume handler — process directly; /me/player poll is not needed
	if ($cmd eq 'volume' && !($request->source && $request->source eq __PACKAGE__)) {
		my $volume = $request->getParam('_p2');
		return unless defined $volume && $volume ne '';

		# CON-07: VOLUME_GRACE_PERIOD — ignore volume events within the first N seconds
		# after daemon start. Plan B's suppress_next_volume AtomicBool handles the very
		# first VolumeChanged; this grace period covers subsequent echoes during session
		# setup (T-08-08).
		if (Plugins::Spotty::Connect::DaemonManager->uptime($client->id) < VOLUME_GRACE_PERIOD) {
			main::INFOLOG && $log->is_info && $log->info(
				"Ignoring initial volume reset right after daemon start"
			);
			# Treat this as an onConnect signal — refresh device list
			__PACKAGE__->getAPIHandler($client)->devices() if __PACKAGE__->getAPIHandler($client);
			return;
		}

		# Volume 49 is a known spurious default from the old binary — always ignore
		if ($volume == 49) {
			main::INFOLOG && $log->is_info && $log->info("Ignoring volume reset to 49");
			return;
		}

		main::INFOLOG && $log->is_info && $log->info("Set volume to $volume");

		# Use a new Request object with source-marking to break the feedback loop
		my $volReq = Slim::Control::Request->new($client->id, ['mixer', 'volume', $volume]);
		$volReq->source(__PACKAGE__);
		$volReq->execute();
		return;
	}

	# Seek handler — source-marked so _onSeek doesn't echo it back to Spotify
	if ($cmd eq 'seek') {
		my $position = $request->getParam('_p2');
		if (defined $position && $position ne '') {
			main::INFOLOG && $log->is_info && $log->info("Seek to $position");
			my $seekReq = Slim::Control::Request->new($client->id, ['time', int($position)]);
			$seekReq->source(__PACKAGE__);
			$seekReq->execute();
		}
		return;
	}

	# Ignore stop events while _getNextTrack is orchestrating a track transition —
	# playerNext causes the daemon to emit stop before the next track starts.
	if ($cmd eq 'stop' && $client->pluginData('newTrack')) {
		main::INFOLOG && $log->is_info && $log->info(
			"Ignoring stop event while fetching next track"
		);
		return;
	}

	# All other events (start, change, stop): poll /me/player for current state
	my $spotty = __PACKAGE__->getAPIHandler($client);
	return unless $spotty;

	$spotty->player(sub {
		my ($result) = @_;

		my $song      = $client->playingSong();
		my $streamUrl = ($song ? $song->streamUrl : '') || '';
		$streamUrl =~ s/\/\///;

		# Update context if available
		$song && $song->pluginData('context') && $song->pluginData('context')->update($result);

		# Defensive: protect against undef from race between session setup and first poll
		# (Pitfall 6)
		$result ||= {};

		main::INFOLOG && $log->is_info && $log->info(sprintf(
			"Current Connect state (cmd=%s): is_playing=%s track=%s",
			$cmd,
			$result->{is_playing} // '?',
			($result->{track} && $result->{track}->{uri}) ? $result->{track}->{uri} : 'none'
		));

		# Handle episode URIs: Plan B sends only the track_id (base62), not the full URI.
		# If we're currently in an episode context and result has no track, synthesise the URI.
		if ($cmd =~ /^(?:start|change)$/ && ($result->{currently_playing_type} || '') eq 'episode'
			&& !$result->{track} && (my $episodeId = $request->getParam('_p2')))
		{
			my $uri = "spotify:episode:$episodeId";
			main::INFOLOG && $log->is_info && $log->info(
				"Didn't get track info in player request, but in notification from spotty helper: $uri"
			);
			$result->{track} = { uri => $uri };
		}

		# change-to-start upgrade (Pitfall 5):
		# If the current stream URL differs from the result track URI (and Spotify says
		# it's playing), or if we're not currently in Connect mode, this is really a start.
		if ($cmd eq 'change' && ref $result->{track}
			&& (($streamUrl ne $result->{track}->{uri} && $result->{is_playing})
				|| !__PACKAGE__->isSpotifyConnect($client)))
		{
			main::INFOLOG && $log->is_info && $log->info(
				"Got a $cmd event, but actually this is a play next track event"
			);
			$cmd = 'start';
		}
		elsif ($cmd eq 'change' && !$client->isPlaying && ref $result->{track}
			&& ($streamUrl eq $result->{track}->{uri} && $result->{is_playing}))
		{
			main::INFOLOG && $log->is_info && $log->info(
				"Got a $cmd event, but actually this is a resume event"
			);
			$cmd = 'start';
		}

		# Start: assign synthetic Connect URL to LMS player
		if ($cmd eq 'start' && $result->{track}) {
			if ($streamUrl ne $result->{track}->{uri} || !__PACKAGE__->isSpotifyConnect($client)) {
				main::INFOLOG && $log->is_info && $log->info(
					"Got a new track to be played: " . $result->{track}->{uri}
				);

				# Mark Connect mode on the client
				$client->pluginData(SpotifyConnect => 1);
				$client->pluginData(newTrack       => 1);

				# Remember episode URI for getNextTrack (Spotify won't return it in player status)
				$client->pluginData(episodeUri => $result->{track}->{uri})
					if ($result->{currently_playing_type} || '') eq 'episode';

				# The spotify://connect-<ts> URL signals Connect mode to ProtocolHandler
				my $playReq = $client->execute([
					'playlist', 'play',
					sprintf("spotify://connect-%u", Time::HiRes::time() * 1000)
				]);
				$playReq->source(__PACKAGE__);

				# Sync volume to Spotify on initial connect
				if (!$client->pluginData('SpotifyConnect')) {
					$spotty->playerVolume(undef, $client->id, $client->volume);
				}

				# Reset play history on interactive Connect use
				$song && $song->pluginData('context') && $song->pluginData('context')->reset();

				$result->{progress} ||= ($result->{progress_ms} / 1000) if $result->{progress_ms};

				# If playback is already more than 10s in, seek to the current position
				if ($result->{progress} && $result->{progress} > 10) {
					$song && $client->pluginData(progress => $result->{progress});
				}
			}
			elsif (!$client->isPlaying) {
				main::INFOLOG && $log->is_info && $log->info("Got to resume playback");
				__PACKAGE__->setSpotifyConnect($client, $result);
				my $resumeReq = Slim::Control::Request->new($client->id, ['play']);
				$resumeReq->source(__PACKAGE__);
				$resumeReq->execute();
			}
		}

		# Stop: pause LMS player if we are the current Connect device
		elsif ($cmd eq 'stop' && $result->{device}) {
			my $clientId = $client->id;
			my $deviceId = Plugins::Spotty::Connect::DaemonManager->idFromMac($clientId);

			if ($client->isPlaying
				&& ($result->{device}->{id} eq ($deviceId || '')
					|| $result->{device}->{name} eq $client->name)
				&& __PACKAGE__->isSpotifyConnect($client))
			{
				main::INFOLOG && $log->is_info && $log->info("Spotify told us to pause: " . $client->id);

				my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
				$pauseReq->source(__PACKAGE__);
				$pauseReq->execute();
			}
			elsif ($client->isPlaying
				&& ($result->{device}->{id} ne ($deviceId || '')
					&& $result->{device}->{name} ne $client->name)
				&& __PACKAGE__->isSpotifyConnect($client))
			{
				main::INFOLOG && $log->is_info && $log->info(
					"Spotify told us to pause, but current player is no longer the Connect target"
				);

				my $pauseReq = Slim::Control::Request->new($client->id, ['pause', 1]);
				$pauseReq->source(__PACKAGE__);
				$pauseReq->execute();

				# Reset Connect status
				$client->playingSong()->pluginData(context       => 0);
				$client->pluginData(SpotifyConnect => 0);
			}
			elsif ($client->isPlaying) {
				main::INFOLOG && $log->is_info && $log->info(
					"Spotify told us to pause, but current player is not Connect target"
				);
				$client->playingSong()->pluginData(context => 0);
				$client->pluginData(SpotifyConnect => 0);
			}
		}

		# Change: seek detection — only if we're still playing and have progress data
		elsif ($cmd eq 'change') {
			if ($client->isPlaying && defined $result->{progress}
				&& abs($result->{progress} - Slim::Player::Source::songTime($client)) > SEEK_THRESHOLD)
			{
				main::INFOLOG && $log->is_info && $log->info(
					"Seek triggered by change event: " . $result->{progress}
				);
				my $seekReq = Slim::Control::Request->new($client->id, ['time', int($result->{progress})]);
				$seekReq->source(__PACKAGE__);
				$seekReq->execute();
			}
		}

		elsif (main::INFOLOG && $log->is_info) {
			$log->info("Unhandled command: $cmd");
		}
	});
}

1;

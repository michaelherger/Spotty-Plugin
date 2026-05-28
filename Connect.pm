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
use Slim::Music::Info;

use Plugins::Spotty::API;

# Seconds; delta threshold to trigger a seek on change events
use constant SEEK_THRESHOLD => 3;

# Fallback artwork for stream-mode metadata updates
use constant IMG_TRACK => '/html/images/cover.png';

# Seconds; CON-07 — ignore volume events within this window after daemon start.
# Plan B's suppress_next_volume AtomicBool handles the very first VolumeChanged after
# SessionConnected. This grace period suppresses subsequent echoes during session setup.
use constant VOLUME_GRACE_PERIOD => 20;

# Seconds; suppress spurious stop events during session setup (mid-playback transfer)
use constant CONNECT_START_GRACE => 12;

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

	# Forward local pause/stop to the Spotify controller for bidirectional state sync
	Slim::Control::Request::subscribe(\&_onPause, [['playlist'], ['pause', 'stop']]);

	# Forward local volume changes to Spotify for bidirectional state sync
	Slim::Control::Request::subscribe(\&_onVolume, [['mixer'], ['volume']]);

	# Forward local seeks to Spotify so the app stays in sync
	Slim::Control::Request::subscribe(\&_onSeek, [['time']]);

	# Forward local skip next/prev to Spotify instead of letting LMS handle it
	Slim::Control::Request::subscribe(\&_onPlaylistJump, [['playlist'], ['jump', 'index']]);

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

	# PLG-01 / D-11: stream mode — audio stream is continuous; track progression
	# is driven by the binary via spottyconnect change events.
	# No API queries, no queue peeking, no pre-buffer optimisation needed.
	main::INFOLOG && $log->is_info && $log->info(
		"Stream mode: getNextTrack is a no-op, audio stream is continuous"
	);

	# Fetch metadata for the initial track (start event sets eventTrackUri).
	# Do NOT clear newTrack synchronously — isSpotifyConnect needs it true
	# until the async callback sets up the Connect context.
	if ($client->pluginData('newTrack')) {
		my $trackUri = $client->pluginData('eventTrackUri') || '';

		if ($trackUri) {
			my $spotty = $class->getAPIHandler($client);
			if ($spotty) {
				$spotty->track(sub {
					my $trackInfo = shift || {};
					$class->setSpotifyConnect($client, {});
					$client->pluginData(newTrack => 0);
					$client->pluginData(eventTrackUri => '');
					if ($trackInfo->{name} && $song) {
						my $artist = join(', ', map { $_->{name} } @{$trackInfo->{artists} || []});
						Slim::Music::Info::setCurrentTitle(
							$song->streamUrl, "$artist - $trackInfo->{name}", $client
						);
						$song->pluginData(info => {
							title        => $trackInfo->{name},
							artist       => $artist,
							album        => ($trackInfo->{album} || {})->{name} || '',
							duration     => ($trackInfo->{duration_ms} || 0) / 1000,
							cover        => $trackInfo->{image}
							               || ($trackInfo->{album} || {})->{image}
							               || IMG_TRACK,
							url          => $song->streamUrl,
							originalType => 'Ogg Vorbis (Spotify)',
							type         => 'Ogg Vorbis (Spotify)',
						});
						$song->duration(($trackInfo->{duration_ms} || 0) / 1000)
							if $trackInfo->{duration_ms};
						$client->streamingProgressBar({
							url      => $song->streamUrl,
							duration => $trackInfo->{duration_ms} / 1000,
						}) if $trackInfo->{duration_ms};
						Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
					}
				}, $trackUri);
			}
			else {
				$log->warn("getNextTrack: no API handler for " . $client->id . ", skipping metadata fetch");
				$client->pluginData(newTrack      => 0);
				$client->pluginData(eventTrackUri => '');
			}
		}
	}

	$successCb->();
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
			client => $client,
			cache  => $cacheFolder,
			userId => $credentials->{username},
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
		Slim::Control::Request::unsubscribe(\&_onPlaylistJump);

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

# Returns true if the Connect daemon for this client was started in stream mode
# (i.e., with --connect-stream, writing PCM to a named FIFO).
sub _isStreamMode {
	my ($client) = @_;
	return unless $client;
	$client = $client->master if $client->can('master');
	my $helper = Plugins::Spotty::Connect::DaemonManager->helperForClient($client->id);
	return $helper && $helper->_streamMode;
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
		if ($client && (my $progress = $client->pluginData('progress'))) {
			$client->pluginData(progress => 0);

			if (_isStreamMode($client)) {
				# Stream-mode: binary streams from current position. Adjust
				# startOffset so songTime reports the correct position without
				# triggering _JumpToTime → _Stop + _Stream.
				my $song = $client->playingSong();
				if ($song) {
					my $elapsed = $client->songElapsedSeconds() || 0;
					$song->startOffset(int($progress) - $elapsed);
					main::INFOLOG && $log->is_info && $log->info(
						"Stream mode mid-song connect: startOffset=" . $song->startOffset()
					);
				}
			} else {
				my $seekReq = Slim::Control::Request->new($client->id, ['time', int($progress)]);
				$seekReq->source(__PACKAGE__);
				$seekReq->execute();
			}
		}
		return;
	}

	return unless $client->pluginData('SpotifyConnect');

	main::INFOLOG && $log->is_info && $log->info(
		"Got a new track event, but this is no longer Spotify Connect"
	);
	my $song = $client->playingSong();
	$song->pluginData(context => 0) if $song;
	$client->pluginData(SpotifyConnect => 0);

	my $spotty = __PACKAGE__->getAPIHandler($client);
	$spotty->playerPause(undef, $client->id) if $spotty;
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
	my $spotty = __PACKAGE__->getAPIHandler($client) or return;
	$spotty->playerPause(undef, $client->id);
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
	my $spotty = __PACKAGE__->getAPIHandler($client) or return;
	$spotty->playerVolume(undef, $client->id, $volume);
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
	my $spotty = __PACKAGE__->getAPIHandler($client) or return;
	$spotty->playerSeek(undef, $client->id, $position);
}

sub _onPlaylistJump {
	my $request = shift;

	return if $request->source && $request->source eq __PACKAGE__;

	my $client = $request->client();
	return if !defined $client;
	$client = $client->master;

	return if !__PACKAGE__->isSpotifyConnect($client);

	my $index = $request->getParam('_index');
	return if !defined $index;

	my $spotty = __PACKAGE__->getAPIHandler($client) or return;

	if ($index eq '+1') {
		main::INFOLOG && $log->is_info && $log->info(
			"Connect mode: forwarding skip-next to Spotify API"
		);
		$spotty->playerNext(undef, $client->id);
	}
	elsif ($index eq '-1' || $index eq '+0') {
		main::INFOLOG && $log->is_info && $log->info(
			"Connect mode: forwarding skip-previous to Spotify API"
		);
		$spotty->playerPrevious(undef, $client->id);
	}
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

	# Flag pending start so the seek handler can defer position to _onNewSong.
	# Must be set synchronously — the seek event arrives before the async API
	# callback that issues playlist play.
	if ($cmd eq 'start') {
		$client->pluginData(pendingConnect => 1);
	}

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
			if ( my $apiHandler = __PACKAGE__->getAPIHandler($client) ) {
				$apiHandler->devices();
			}
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

			if (_isStreamMode($client)) {
				if ($client->pluginData('pendingConnect')) {
					# Seek arrived before playlist play — the song object will
					# be replaced. Store position for _onNewSong to apply after
					# the new song is created.
					$client->pluginData(progress => $position);
					$client->pluginData(pendingConnect => 0);
					main::INFOLOG && $log->is_info && $log->info(
						"Stream mode seek deferred: progress=$position (pending connect)"
					);
				} else {
					# Stream-mode: binary already seeked internally. Adjust startOffset
					# so songTime reports the correct position without triggering
					# _JumpToTime → _Stop + _Stream (which restarts the FIFO).
					my $song = $client->playingSong();
					if ($song) {
						my $elapsed = $client->songElapsedSeconds() || 0;
						$song->startOffset(int($position) - $elapsed);
						main::INFOLOG && $log->is_info && $log->info(
							"Stream mode seek: adjusted startOffset to " . $song->startOffset()
						);
					}
				}
			} else {
				my $seekReq = Slim::Control::Request->new($client->id, ['time', int($position)]);
				$seekReq->source(__PACKAGE__);
				$seekReq->execute();
			}
		}
		return;
	}

	# Ignore stop events during the stream-mode window between start event and
	# metadata fetch completion (newTrack is set by start, cleared by getNextTrack callback).
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

		# Stale-API fallback: the binary's event carries the new track_id in _p2.
		# If the API returned the same track we already have but the event says
		# otherwise, trust the event — the API is lagging behind.
		if ($cmd eq 'change' && (my $eventTrackId = $request->getParam('_p2'))) {
			my $eventUri = "spotify:track:$eventTrackId";
			if (ref $result->{track} && $result->{track}->{uri}
				&& $result->{track}->{uri} eq $streamUrl
				&& $eventUri ne $streamUrl)
			{
				main::INFOLOG && $log->is_info && $log->info(
					"API returned stale track, using event track_id: $eventUri"
				);
				$result->{track} = { uri => $eventUri };
				$result->{is_playing} = 1;
				$result->{progress} = 0;
			}
		}

		# PLG-02 / D-04 / D-05: Stream mode — metadata-only update on track change.
		# MUST run BEFORE the change-to-start upgrade (below) to prevent playlist play.
		# In stream mode the FIFO carries continuous PCM; the binary drives track
		# progression — no new transcoding process should be spawned.
		if ($cmd eq 'change' && _isStreamMode($client)) {
			# Reset progress bar for the new track: in stream mode,
			# songElapsedSeconds counts from the original stream start,
			# so startOffset must compensate to reset songTime to ~0.
			# Clear pluginData progress to prevent _onNewSong from overriding
			# with the stale API position (which still reports the old track's end).
			if ($song) {
				my $elapsed = $client->songElapsedSeconds() || 0;
				$song->startOffset(0 - $elapsed);
				$client->playPoint(undef);
				$client->pluginData(progress => 0);
			}

			my $eventTrackId = $request->getParam('_p2');
			if ($eventTrackId && $song) {
				# Full async fetch for track metadata (title, artist, album, artwork, duration)
				my $spotty2 = __PACKAGE__->getAPIHandler($client);
				$spotty2->track(sub {
					my $trackInfo = shift || {};
					if ($trackInfo->{name}) {
						my $artist = join(', ', map { $_->{name} } @{$trackInfo->{artists} || []});

						# Instant display update (D-04)
						Slim::Music::Info::setCurrentTitle(
							$song->streamUrl,
							"$artist - " . $trackInfo->{name},
							$client
						);

						# Full metadata for Now Playing display
						$song->pluginData(info => {
							title        => $trackInfo->{name},
							artist       => $artist,
							album        => ($trackInfo->{album} || {})->{name} || '',
							duration     => ($trackInfo->{duration_ms} || 0) / 1000,
							cover        => $trackInfo->{image}
							                || ($trackInfo->{album} || {})->{image}
							                || IMG_TRACK,
							url          => $song->streamUrl,
							originalType => 'Ogg Vorbis (Spotify)',
							type         => 'Ogg Vorbis (Spotify)',
						});

						# Update song duration for progress bar
						$song->duration(($trackInfo->{duration_ms} || 0) / 1000)
							if $trackInfo->{duration_ms};
						$client->streamingProgressBar({
							url      => $song->streamUrl,
							duration => $trackInfo->{duration_ms} / 1000,
						}) if $trackInfo->{duration_ms};

						# Fire newmetadata notification so LMS refreshes Now Playing
						Slim::Control::Request::notifyFromArray($client, ['newmetadata']);
					}
				}, "spotify:track:$eventTrackId");
			}

			# In stream mode, startOffset is reset directly above — do NOT
			# store the API's progress here: on track change the API still
			# reports the OLD track's end position, and _onNewSong would
			# override our reset with that stale value.

			return;  # D-05: no fall-through to change-to-start upgrade / playlist play
		}

		# change-to-start upgrade (Pitfall 5):
		# If the current stream URL differs from the result track URI (and Spotify says
		# it's playing), or if we're not currently in Connect mode, this is really a start.
		my $wasChange = 0;
		if ($cmd eq 'change' && ref $result->{track}
			&& (($streamUrl ne $result->{track}->{uri} && $result->{is_playing})
				|| !__PACKAGE__->isSpotifyConnect($client)))
		{
			main::INFOLOG && $log->is_info && $log->info(
				"Got a $cmd event, but actually this is a play next track event"
			);
			$wasChange = 1;
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

		# Stale-API fallback for start: if API returned no track but the
		# event carries a track_id in _p2, synthesize the track info.
		if ($cmd eq 'start' && !$result->{track} && (my $startTrackId = $request->getParam('_p2'))) {
			my $startUri = "spotify:track:$startTrackId";
			main::INFOLOG && $log->is_info && $log->info(
				"API returned no track on start, using event track_id: $startUri"
			);
			$result->{track} = { uri => $startUri };
			$result->{is_playing} = 1;
		}

		# Start: assign synthetic Connect URL to LMS player
		if ($cmd eq 'start' && $result->{track}) {
			if ($streamUrl ne $result->{track}->{uri} || !__PACKAGE__->isSpotifyConnect($client)) {
				main::INFOLOG && $log->is_info && $log->info(
					"Got a new track to be played: " . $result->{track}->{uri}
				);

				# Store event track URI for getNextTrack fallback (stale API)
				$client->pluginData(eventTrackUri => $result->{track}->{uri});

				# Sync volume to Spotify on initial connect (before setting the flag)
				if (!$client->pluginData('SpotifyConnect')) {
					$spotty->playerVolume(undef, $client->id, $client->volume);
				}

				# Mark Connect mode on the client
				$client->pluginData(SpotifyConnect   => 1);
				$client->pluginData(newTrack         => 1);
				$client->pluginData(connectStartTime => Time::HiRes::time());

				# Store mid-track progress BEFORE play command so _onNewSong
				# can read it when the newsong event fires synchronously.
				if (!$wasChange) {
					$result->{progress} ||= ($result->{progress_ms} / 1000) if $result->{progress_ms};

					if ($result->{progress} && $result->{progress} > 10) {
						$client->pluginData(progress => $result->{progress});
					}
				}

				# The spotify://connect-<ts> URL signals Connect mode to ProtocolHandler
				my $playReq = $client->execute([
					'playlist', 'play',
					sprintf("spotify://connect-%u", Time::HiRes::time() * 1000)
				]);
				$playReq->source(__PACKAGE__);

				# Reset play history on interactive Connect use
				$song && $song->pluginData('context') && $song->pluginData('context')->reset();
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
		elsif ($cmd eq 'stop') {
			# Grace period: ignore spurious stop events (is_playing=0, no track)
			# that arrive during mid-playback session setup. These are librespot
			# session transition artifacts, not real user pauses.
			if (!$result->{is_playing} && !$result->{track}
				&& (Time::HiRes::time() - ($client->pluginData('connectStartTime') || 0)) < CONNECT_START_GRACE)
			{
				main::INFOLOG && $log->is_info && $log->info(
					"Ignoring spurious stop during Connect session setup grace period"
				);
				return;
			}

			if ($result->{device}) {
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
		}

		# Change: the binary reports a track change — seek correction if progress drifted.
		elsif ($cmd eq 'change') {
			if ($client->isPlaying && defined $result->{progress}
				&& abs($result->{progress} - Slim::Player::Source::songTime($client)) > SEEK_THRESHOLD)
			{
				main::INFOLOG && $log->is_info && $log->info(
					"Seek triggered by change event: " . $result->{progress}
				);

				if (_isStreamMode($client)) {
					my $song = $client->playingSong();
					if ($song) {
						my $elapsed = $client->songElapsedSeconds() || 0;
						$song->startOffset(int($result->{progress}) - $elapsed);
					}
				} else {
					my $seekReq = Slim::Control::Request->new($client->id, ['time', int($result->{progress})]);
					$seekReq->source(__PACKAGE__);
					$seekReq->execute();
				}
			}
		}

		elsif (main::INFOLOG && $log->is_info) {
			$log->info("Unhandled command: $cmd");
		}
	});
}

1;

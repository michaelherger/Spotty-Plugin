package Plugins::Spotty::ProtocolHandler;

use strict;

use base qw(Slim::Formats::RemoteStream);
use Scalar::Util qw(blessed);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Spotty::Plugin;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');

use constant IMG_TRACK => '/html/images/cover.png';

sub contentType { 'spt' }

# transcoding needs a fix only available in 7.9.1
sub canSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }
sub canTranscodeSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub trackGain {
	my ($class, $client, $url) = @_;

	return unless $client && blessed $client;

	# if spotty's replaygain is enabled, then don't additionally change in LMS
	return if $prefs->client($client)->get('replaygain');

	# otherwise respect LMS' settings
	my $cprefs = $serverPrefs->client($client);
	return $cprefs->get('replayGainMode') && $cprefs->get('remoteReplayGain');
}

sub formatOverride {
	my ($class, $song) = @_;

	# Update the transcoding table with the current player's Spotty ID...
	Plugins::Spotty::Plugin->updateTranscodingTable($song->master);

	# check if we want/need to purge the audio cache
	# this needs to be done from whatever code being run once per track
	Plugins::Spotty::AccountHelper->purgeAudioCacheAfterXTracks();

	return 'spt';
}

sub canDirectStream { 0 }

# P = Chosen by the user
sub audioScrobblerSource { 'P' }

sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;

	main::INFOLOG && $log->is_info && $log->info("Explode URI: $uri");
	if ($uri =~ m|/connect-\d+|) {
		$cb->([$uri]);
	}
	elsif (my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client)) {
		$spotty->trackURIsFromURI(sub {
			$cb->([
				map {
					/((?:track|episode):.*)/;
					"spotify://$1";
				} @{shift || []}
			]);
		}, $uri);
	}
	else {
		$cb->([]);
	}
}

sub isRepeatingStream {
	my ( undef, $song ) = @_;

	return $song && Plugins::Spotty::Connect->isSpotifyConnect($song->master());
}

sub canDoAction {
	my ( $class, $client, $url, $action ) = @_;

	if ( $action eq 'pause' && $prefs->get('optimizePreBuffer') && Plugins::Spotty::Connect->isSpotifyConnect($client) ) {
		return 0;
	}

	return 1;
}

sub getNextTrack {
	my ( $class, $song, $successCb, $errorCb ) = @_;

	my $client = $song->master();

	if (Plugins::Spotty::Connect->isSpotifyConnect($client)) {
		Plugins::Spotty::Connect->getNextTrack($song, $successCb, $errorCb);
		return;
	}

	$successCb->();
}

sub getMetadataFor {
	my ( $class, $client, $url, undef, $song ) = @_;

	my $meta = {
		artist    => '',
		album     => '',
		title     => '',
		duration  => 0,
		cover     => IMG_TRACK,
		icon      => IMG_TRACK,
		bitrate   => 0,
		originalType => 'Ogg Vorbis (Spotify)',
	};

	$meta->{type} = $meta->{originalType};

	if ( !Plugins::Spotty::AccountHelper->hasCredentials() ) {
		$meta->{artist} = cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT');
		$meta->{title} = cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT');
		return $meta;
	}
	elsif ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		$meta->{artist} = cstring($client, 'PLUGIN_SPOTTY_MISSING_SSL');
		$meta->{title} = cstring($client, 'PLUGIN_SPOTTY_MISSING_SSL');
		return $meta;
	}

	$meta = undef;

	# sometimes we wouldn't get a song object, and an outdated url. Get latest data instead!
	if (!$song && Plugins::Spotty::Connect->isSpotifyConnect($client) && ($song = $client->playingSong)) {
		$url = $song->streamUrl;
	}

	if ( $client && ($song ||= $client->currentSongForUrl($url)) ) {
		# we store a copy of the metadata in the song object - no need to read from the disk cache
		my $info = $song->pluginData('info');
		if ( $info->{title} && $info->{duration} && ($info->{url} eq $url) ) {
			my $bitrate = $song->streambitrate;
			if ($bitrate) {
				$info->{bitrate} = Slim::Schema::Track->buildPrettyBitRate( $bitrate );
			}

			# Append "...converted to [format]" if stream has been transcoded
			my $converted = $song->streamformat;
			if ($converted && $converted ne 'ogg') {
				my $convertedString = Slim::Utils::Strings::getString(uc($converted));
				if ( $converted =~ /.{2,4}/ && $converted ne $convertedString ) {
					$converted = $convertedString;
				}
				$info->{type} = sprintf('%s (%s %s)', $info->{originalType}, cstring($client, 'CONVERTED_TO'), $converted);
			}

			$song->duration($info->{duration});

			main::INFOLOG && $log->is_info && $log->info("Returning metadata cached in song object for $url");
			main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($info));
			return $info;
		}
	}

	my $uri = $url;
	$uri =~ s/\///g;

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);

	if ( my $cached = Plugins::Spotty::API->trackCached(undef, $uri, { noLookup => 1 }) ) {
		$meta = {
			artist    => join( ', ', map { $_->{name} } @{ $cached->{artists} } ),
			album     => $cached->{album}->{name},
			title     => $cached->{name},
			duration  => $cached->{duration_ms} / 1000,
			cover     => $cached->{image} || $cached->{album}->{image},
		};

		main::INFOLOG && $log->is_info && $log->info("Found cached metadata for $uri");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($meta));
	}

	if (!$meta) {
		# grab missing metadata asynchronously
		main::INFOLOG && $log->is_info && $log->info("No metadata found - need to look online");
		$class->getBulkMetadata($client, $song ? undef : $url);
		$meta = {};
	}

	$meta->{bitrate} ||= $prefs->get('bitrate') . 'k VBR';
	$meta->{originalType} ||= 'Ogg Vorbis (Spotify)';
	$meta->{type}    = $meta->{originalType};
	$meta->{cover}   ||= IMG_TRACK;
	$meta->{icon}    ||= IMG_TRACK;

	if ($song) {
		if ( $meta->{duration} && !($song->duration && $song->duration > 0) ) {
			$song->duration($meta->{duration});
		}
		$meta->{url} = $url;

		$song->pluginData( info => $meta );
	}

	return $meta;
}

sub getBulkMetadata {
	my ($class, $client, $uri) = @_;

	my @uris;

	if ($uri) {
		@uris = ($uri);
	}
	elsif ( !$client->master->pluginData('fetchingMeta') ) {
		$client->master->pluginData( fetchingMeta => 1 );
		@uris = @{ Slim::Player::Playlist::playList($client) };
	}

	if (scalar @uris) {
		# Go fetch metadata for all tracks on the playlist without metadata
		my @need;

		my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client) || return;

		for my $track ( @uris ) {
			my $uri = blessed($track) ? $track->url : $track;
			$uri =~ s/\///g;

			next unless $uri =~ /^spotify:(?:episode|track)/;

			if ( !$spotty->trackCached(undef, $uri, { noLookup => 1 }) ) {
				push @need, $uri;
			}
		}

		if (scalar @need) {
			if ( main::INFOLOG && $log->is_info ) {
				$log->info( "Need to fetch metadata for: " . Data::Dump::dump(@need) );
			}

			$spotty->tracks(sub {
				# Update the playlist time so the web will refresh, etc
				$client->currentPlaylistUpdateTime( Time::HiRes::time() );

				Slim::Control::Request::notifyFromArray( $client, [ 'newmetadata' ] );

				$client->master->pluginData( fetchingMeta => 0 );
			}, \@need);
		}
	}
}

sub getIcon {
	return Plugins::Spotty::Plugin->_pluginDataFor('icon');
}

1;
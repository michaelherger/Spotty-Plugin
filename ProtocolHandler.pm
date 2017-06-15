package Plugins::Spotty::ProtocolHandler;

use strict;

use base qw(Slim::Formats::RemoteStream);
use Scalar::Util qw(blessed);

use Slim::Utils::Cache;
use Slim::Utils::Log;
#use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring);

use Plugins::Spotty::Plugin;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');

use constant IMG_TRACK => '/html/images/cover.png';

sub contentType { 'spt' }

# transcoding needs a fix only available in 7.9.1
sub canSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }
sub canTranscodeSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }

#sub bufferThreshold {
#	my ($class, $client, $url) = @_;
#	warn Data::Dump::dump($url); 
#	40 * ( preferences('server')->get('bufferSecs') || 3 ) 
#}

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub formatOverride { 
	my ($class, $song) = @_;
	return ($song->streamUrl =~ m|/connect\.| || $song->track->url =~ m|/connect\.|) ? 'sptc' : 'spt';
}

sub canDirectStream { 0 }

sub explodePlaylist {
	my ( $class, $client, $uri, $cb ) = @_;
	
#	if ( $uri eq 'spotify://connect.spt' ) {
#		$cb->([$uri]);
#		return;
#	}

	Plugins::Spotty::Plugin->getAPIHandler($client)->trackURIsFromURI(sub {
		$cb->([ 
			map { 
				/(track:.*)/; 
				"spotify://$1";
			} @{shift || []}
		]);
	}, $uri);
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
		type      => 'Ogg Vorbis (Spotify)',
	};
	
	if ( !Plugins::Spotty::Plugin->hasCredentials() ) {
		$meta->{artist} = cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT');
		$meta->{title} = cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT');
		return $meta;
	}
	elsif ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		$meta->{artist} = cstring($client, 'PLUGIN_SPOTTY_MISSING_SSL');
		$meta->{title} = cstring($client, 'PLUGIN_SPOTTY_MISSING_SSL');
		return $meta;
	}
	elsif ($url =~ m|/connect\.|) {
		$meta->{title} = 'Spotify Connect';
		return $meta;
	}
	
	$meta = undef;

	if ( $song ||= $client->currentSongForUrl($url) ) {
		# we store a copy of the metadata in the song object - no need to read from the disk cache
		my $info = $song->pluginData('info');
		if ( $info->{title} && $info->{duration} ) {
			my $bitrate = $song->streambitrate;
			if ($bitrate) {
				$info->{bitrate} = Slim::Schema::Track->buildPrettyBitRate( $bitrate );
			}
			
			# Append "...converted to [format]" if stream has been transcoded
			my $converted = $song->streamformat;
			if ($converted && $info->{type} !~ /mp3|fla?c|pcm/i) {
				if ($converted =~ /mp3|flc|pcm/i) {
					$converted = cstring( $client, uc($converted) );
				}
				$info->{type} = sprintf('%s (%s %s)', $info->{type}, cstring($client, 'CONVERTED_TO'), $converted);
			}
			
			return $info;
		}
	}
	
	my $uri = $url;
	$uri =~ s/\///g;
	
	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);
	
	if ( my $cached = $spotty->trackCached(undef, $uri, { noLookup => 1 }) ) {
		$meta = {
			artist    => join( ', ', map { $_->{name} } @{ $cached->{artists} } ),
			album     => $cached->{album}->{name},
			title     => $cached->{name},
			duration  => $cached->{duration_ms} / 1000,
			cover     => $cached->{album}->{image},
		};
	}

	if (!$meta) {
		# grab missing metadata asynchronously
		$class->getBulkMetadata($client);
		$meta = {};
	}
	
	$meta->{bitrate} ||= '320k VBR';
	$meta->{type}    ||= 'Ogg Vorbis (Spotify)';
	$meta->{cover}   ||= IMG_TRACK;
	$meta->{icon}    ||= IMG_TRACK;
#			info_link => 'plugins/spotifylogi/trackinfo.html',

	if ($song) {
		if ( $meta->{duration} && !($song->duration && $song->duration > 0) ) {
			$song->duration($meta->{duration});
		}

		$song->pluginData( info => $meta );
	}
	
	return $meta;
}

sub getBulkMetadata {
	my ($class, $client) = @_;
	
	if ( !$client->master->pluginData('fetchingMeta') ) {
		$client->master->pluginData( fetchingMeta => 1 );

		# Go fetch metadata for all tracks on the playlist without metadata
		my @need;

		my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);
		
		for my $track ( @{ Slim::Player::Playlist::playList($client) } ) {
			my $uri = blessed($track) ? $track->url : $track;
			$uri =~ s/\///g;
			
			next unless $uri =~ /^spotify:track/;

			if ( !$spotty->trackCached(undef, $uri, { noLookup => 1 }) ) {
				push @need, $uri;
			}
		}
		
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

sub getIcon {
	return Plugins::Spotty::Plugin->_pluginDataFor('icon');
}

1;
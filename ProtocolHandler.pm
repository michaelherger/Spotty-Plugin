package Plugins::Spotty::ProtocolHandler;

use strict;

use base qw(Slim::Formats::RemoteStream);

use Slim::Plugin::SpotifyLogi::Plugin;
use Slim::Plugin::SpotifyLogi::ProtocolHandler;
use Slim::Utils::Cache;
use Slim::Utils::Strings qw(cstring);

use Plugins::Spotty::Plugin;

my $cache = Slim::Utils::Cache->new();

use constant IMG_TRACK => '/html/images/cover.png';

sub contentType { 'spt' }

# transcoding needs a fix only available in 7.9.1
sub canSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }
sub canTranscodeSeek { Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 }

sub getSeekData {
	my ($class, $client, $song, $newtime) = @_;
	return { timeOffset => $newtime };
}

sub formatOverride { 
	my ($class, $song) = @_;
	return ($song->streamUrl =~ m|/connect\.| || $song->track->url =~ m|/connect\.|) ? 'sptc' : 'spt';
}

sub canDirectStream { 0 }

sub getMetadataFor {
	my ( $class, $client, $url, undef, $song ) = @_;
	
	if ( !Plugins::Spotty::Plugin->hasCredentials() ) {
		return {
			artist    => cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT'),
			album     => '',
			title     => cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED'),
			duration  => 0,
			cover     => IMG_TRACK,
			icon      => IMG_TRACK,
			bitrate   => 0,
			type      => 'Ogg Vorbis (Spotify)',
		}
	}
	elsif ($url =~ m|/connect\.|) {
		return {
			artist    => '',
			album     => '',
			title     => 'Spotify Connect',
			duration  => 0,
			cover     => IMG_TRACK,
			icon      => IMG_TRACK,
			bitrate   => 0,
			type      => 'Ogg Vorbis (Spotify)',
		}
	}

	$song ||= $client->currentSongForUrl($url);
	
	my $uri = $url;
	$uri =~ s/\///g;
	
	my $meta;
	if ( my $cached = $cache->get($uri) ) {
		$meta = {
			artist    => join( ', ', map { $_->{name} } @{ $cached->{artists} } ),
			album     => $cached->{album}->{name},
			title     => $cached->{name},
			duration  => $cached->{duration_ms} / 1000,
			cover     => $cached->{album}->{image},
			icon      => IMG_TRACK,
			info_link => 'plugins/spotifylogi/trackinfo.html',
			type      => 'Ogg Vorbis (Spotify)',
		}
	}

	$meta ||= Slim::Plugin::SpotifyLogi::ProtocolHandler->getMetadataFor( $client, $url, undef, $song );

	if ($song) {
		$meta->{bitrate} = Slim::Schema::Track->buildPrettyBitRate( $song->streambitrate );
		
		my $converted = $song->streamformat;
		if ($converted) {
			if ($converted =~ /mp3|flc|pcm/i) {
				$converted = cstring( $client, uc($converted) );
			}
			$meta->{type} = sprintf('%s (%s %s)', $meta->{type}, cstring($client, 'CONVERTED_TO'), $converted);
		}
	}
	
	return $meta;
}

sub getIcon {
	return Slim::Plugin::SpotifyLogi::Plugin->_pluginDataFor('icon');
}

1;
package Plugins::Spotty::ProtocolHandler;

use strict;

use base qw(Slim::Formats::RemoteStream);

use Slim::Plugin::SpotifyLogi::Plugin;
use Slim::Plugin::SpotifyLogi::ProtocolHandler;
use Slim::Utils::Strings qw(cstring);

sub contentType { 'spt' }

sub formatOverride { 
	my ($class, $song) = @_;
	return ($song->streamUrl =~ m|/connect\.| || $song->track->url =~ m|/connect\.|) ? 'sptc' : 'spt';
}

sub canDirectStream { 0 }

sub getMetadataFor {
	my ( $class, $client, $url, undef, $song ) = @_;

	$song ||= $client->currentSongForUrl($url);

	my $meta = Slim::Plugin::SpotifyLogi::ProtocolHandler->getMetadataFor( $client, $url, undef, $song );
	
	if ($song) {
		$meta->{bitrate} = Slim::Schema::Track->buildPrettyBitRate( $song->streambitrate );
		$meta->{type};
		
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
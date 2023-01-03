package Plugins::Spotty::Settings::Player;

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.spotty');
my $log   = logger('plugin.spotty');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub needsClient {
	return 1;
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/player.html');
}

sub prefs {
	my ($class, $client) = @_;
	my @prefs = qw(enableSpotifyConnect replaygain filterExplicitContent reversePodcastOrder);
	push @prefs, 'enableAutoplay' if Plugins::Spotty::Helper->getCapability('autoplay');
	return ($prefs->client($client), @prefs);
}

sub handler {
	my ($class, $client, $params) = @_;

	if ( !Plugins::Spotty::Connect->canSpotifyConnect() ) {
		$params->{errorString} = $client->string('PLUGIN_SPOTTY_NEED_HELPER_UPDATE');
	}

	$params->{canAutoplay} = Plugins::Spotty::Helper->getCapability('autoplay');

	return $class->SUPER::handler( $client, $params );
}

sub validFor {
	return Plugins::Spotty::AccountHelper->hasCredentials() ? 1 : 0;
}

1;
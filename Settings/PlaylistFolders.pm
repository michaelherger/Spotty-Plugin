package Plugins::Spotty::Settings::PlaylistFolders;

# Logitech Media Server Copyright 2001-2011 Logitech.
# This program is free software; you can redistribute it and/or
# modify it under the terms of the GNU General Public License,
# version 2.

use strict;
use base qw(Slim::Web::Settings);

use File::Basename qw(basename);
use File::Spec::Functions qw(catfile);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::DateTime;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Spotty::Plugin;
use Plugins::Spotty::PlaylistFolders;

my $prefs = preferences('plugin.spotty');
my $log   = logger('plugin.spotty');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/playlist-folders.html');
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;

	my $cacheFolder = Plugins::Spotty::AccountHelper->cacheFolder('playlistFolders');

	if ($paramRef->{saveSettings}) {
		foreach (grep /^delete_.*\.file$/, keys %$paramRef) {
			if (/^delete_(.*)/) {
				my $toDelete = catfile($cacheFolder, $1);
				unlink $toDelete if -e $toDelete;
			}
		}

		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'basic.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	my $cacheFiles = Plugins::Spotty::PlaylistFolders->findAllCachedFiles(1);
	$paramRef->{cacheFileInfo} = {};

	$paramRef->{cacheFiles} = [ sort {
		$paramRef->{cacheFileInfo}->{$b}->{timestamp} <=> $paramRef->{cacheFileInfo}->{$a}->{timestamp}
	} map {
		my $name = basename($_);
		$paramRef->{cacheFileInfo}->{$name} = {
			size => Plugins::Spotty::PlaylistFolders::formatKB(-s $_),
			changedate => Slim::Utils::DateTime::shortDateF((stat(_))[9]),
			timestamp => (stat(_))[9]
		};
		$name;
	} grep /\Q$cacheFolder\E/i, @$cacheFiles ];
	$paramRef->{spotifyFiles} = [ grep { $_ !~ /\Q$cacheFolder\E/i } @$cacheFiles ];
	$paramRef->{spotifyCacheFolder} = Plugins::Spotty::PlaylistFolders->spotifyCacheFolder() || Slim::Utils::Strings::string('PLUGIN_SPOTTY_FILE_NOT_FOUND');

	return $class->SUPER::handler( $client, $paramRef, $pageSetup, $httpClient, $response );
}

1;
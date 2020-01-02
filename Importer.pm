package Plugins::Spotty::Importer;

use strict;

use Slim::Utils::Prefs;

use Plugins::Spotty::API::Cache;
use Plugins::Spotty::API::Token;

my $prefs = preferences('plugin.spotty');
my $libraryCache = Plugins::Spotty::API::Cache->new();

sub initPlugin {
	my $class = shift;

	Slim::Music::Import->addImporter($class, {
		'type'         => 'file',
		'weight'       => 200,
		'use'          => 1,
	});

	return 1;
}

sub startScan {
	my $class = shift;
	require Plugins::Spotty::API::Sync;

	my @missing;

	my $albums = Plugins::Spotty::API::Sync->myAlbums();
	foreach (@$albums) {
		my $cached = $libraryCache->get($_->{album}->{uri});
		if (!$cached || !$cached->{image}) {
			push @missing, $_->{id};
		}
	}

	Plugins::Spotty::API::Sync->albums(\@missing);

	foreach (@$albums) {
		_storeAlbumTracks($_->{tracks});
	}
}

sub startAsyncScan {
	require Plugins::Spotty::API;
	my $spotty = Plugins::Spotty::API->new();

	$spotty->myAlbums(sub {
		my ($albums) = @_;

		foreach (@$albums) {
			_storeAlbumTracks($_->{tracks});
		}
	});
}

sub _storeAlbumTracks {
	my ($tracks) = @_;

	return unless $tracks && ref $tracks;

	my $c = 0;

	foreach (@$tracks) {
		my $item = $libraryCache->get($_->{uri}) || $_;

		Slim::Schema->updateOrCreate({
			url        => $item->{uri},
			integrateRemote => 1,
			# new => 1,
			attributes => {
				TITLE        => $item->{name},
				ARTIST       => $item->{artists}->[0]->{name},
				ARTIST_EXTID => $item->{artists}->[0]->{uri},
				ALBUMARTIST  => $item->{album}->{artists}->[0]->{name} || $item->{artists}->[0]->{name},
				ALBUM        => $item->{album}->{name},
				ALBUM_EXTID  => $item->{album}->{uri},
				TRACKNUM     => $item->{track_number},
				GENRE        => 'Spotify',
				# DISC        => $item->{disc_number},
				SECS         => $item->{duration_ms}/1000,
				YEAR         => substr($item->{release_date} || $item->{album}->{release_date}, 0, 4),			# TODO - verify
				COVER        => $item->{album}->{image},
				AUDIO        => 1,
				EXTID        => $item->{uri},
				CONTENT_TYPE => 'spt'
			},
		});

		if (!main::SCANNER && ++$c % 20 == 0) {
			main::idle();
		}
	}

	main::idle() if !main::SCANNER;
}

1;
package Plugins::Spotty::Importer;

use strict;

use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::API::Cache;
use Plugins::Spotty::API::Token;

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');
my $libraryCache = Plugins::Spotty::API::Cache->new();
my $cache = Slim::Utils::Cache->new();

sub initPlugin {
	my $class = shift;

	return unless $prefs->get('integrateWithMyMusic');

	eval {
		require Plugins::Spotty::API::Sync;
	};

	if ($@) {
		$log->error($@);
		$log->warn("Please update your LMS to be able to use online library integration in My Music");
		return;
	}

	Slim::Music::Import->addImporter($class, {
		'type'         => 'file',
		'weight'       => 200,
		'use'          => 1,
		'playlistOnly' => 1,
	});

	return 1;
}

sub startScan {
	my $class = shift;
	require Plugins::Spotty::API::Sync;

	my $playlistsOnly = Slim::Music::Import->scanPlaylistsOnly();
	my $accounts = Plugins::Spotty::AccountHelper->getAllCredentials();

	foreach my $account (keys %$accounts) {
		my $accountId = $accounts->{$account};
		main::INFOLOG && $log->is_info && $log->info("Starting import for user $account");
		my $api = Plugins::Spotty::API::Sync->new($accountId);

		if (!$playlistsOnly) {
			my $progress = Slim::Utils::Progress->new({
				'type'  => 'importer',
				'name'  => 'plugin_spotty_albums',
				'total' => 1,
				'every' => 1,
			});

			my @missingAlbums;

			main::INFOLOG && $log->is_info && $log->info("Reading albums...");
			$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_ALBUMS'));

			my $albums = $api->myAlbums();
			$progress->total(scalar @$albums + 2);

			main::INFOLOG && $log->is_info && $log->info("Getting missing album information...");
			foreach (@$albums) {
				my $cached = $libraryCache->get($_->{album}->{uri});
				if (!$cached || !$cached->{image}) {
					push @missingAlbums, $_->{id};
				}
			}

			$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_TRACKS'));
			$api->albums(\@missingAlbums);

			# if we've got more than one user, then create a virtual library per user
			my $libraryId = md5_hex($accountId) if scalar keys %$accounts > 1;

			main::INFOLOG && $log->is_info && $log->info("Importing album tracks...");
			foreach (@$albums) {
				$progress->update($_->{name});
				main::SCANNER && Slim::Schema->forceCommit;

				_storeTracks($_->{tracks}, $libraryId);
			}

			if ($libraryId) {
				Slim::Music::VirtualLibraries->unregisterLibrary($accountId . 'AndLocal');
				Slim::Music::VirtualLibraries->registerLibrary({
					id => $accountId . 'AndLocal',
					name => Plugins::Spotty::AccountHelper->getDisplayName($account),
					priority => 10,
					sql => qq{
						SELECT tracks.id
						FROM tracks
						WHERE tracks.url like 'file://%' OR tracks.id IN (
							SELECT library_track.track
							FROM library_track
							WHERE library_track.library = '$libraryId'
						)
					},
				});

				Slim::Music::VirtualLibraries->unregisterLibrary($accountId);
				Slim::Music::VirtualLibraries->registerLibrary({
					id => $accountId,
					name => Plugins::Spotty::AccountHelper->getDisplayName($account) . ' (Spotty)',
					priority => 20,
					scannerCB => sub {
						my ($id) = @_;

						my $dbh = Slim::Schema->dbh();
						my $sth = $dbh->prepare_cached("UPDATE library_track SET library = ? WHERE library = ?");
						$sth->execute($id, $libraryId);
					}
				});
			}

			$progress->final();
			main::SCANNER && Slim::Schema->forceCommit;
		}

		my $progress = Slim::Utils::Progress->new({
			'type'  => 'importer',
			'name'  => 'plugin_spotty_playlists',
			'total' => 1,
			'every' => 1,
		});

		$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_PLAYLISTS'));

		main::INFOLOG && $log->is_info && $log->info("Reading playlists...");
		my $playlists = $api->myPlaylists();

		$progress->total((scalar @$playlists)*2 + 1);

		$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_TRACKS'));
		my %tracks;
		my $c = 0;

		main::INFOLOG && $log->is_info && $log->info("Getting playlist tracks...");

		# we need to get the tracks first
		foreach my $playlist (@{$playlists || []}) {
			$progress->update($playlist->{name});
			main::SCANNER && Slim::Schema->forceCommit;

			my $tracks = $api->playlistTrackIDs($playlist->{id});
			$cache->set('spotty_playlist_tracks_' . $playlist->{id}, $tracks);

			foreach (@$tracks) {
				next if defined $tracks{$_};

				my $cached = $libraryCache->get($_);
				$tracks{$_} = $cached && $cached->{image} ? 1 : 0;
			}
		}

		# pre-cache track information for playlist tracks
		main::INFOLOG && $log->is_info && $log->info("Getting playlist track information...");
		$api->tracks([grep { !$tracks{$_} } keys %tracks]);

		# now store the playlists with the tracks
		foreach my $playlist (@{$playlists || []}) {
			$progress->update($playlist->{name});
			my $playlistObj = Slim::Schema->updateOrCreate({
				url        => $playlist->{uri},
				playlist   => 1,
				integrateRemote => 1,
				attributes => {
					TITLE        => $playlist->{name},
					COVER        => $playlist->{image},
					AUDIO        => 1,
					EXTID        => $playlist->{uri},
					CONTENT_TYPE => 'ssp'
				},
			});

			$playlistObj->setTracks($cache->get('spotty_playlist_tracks_' . $playlist->{id}));
		}

		main::INFOLOG && $log->is_info && $log->info("Done, finally!");

		$progress->final();
	}

	Slim::Music::Import->endImporter($class);
}

=pod
sub startAsyncScan {
	require Plugins::Spotty::API;
	my $spotty = Plugins::Spotty::API->new();

	$spotty->myAlbums(sub {
		my ($albums) = @_;

		foreach (@$albums) {
			_storeTracks($_->{tracks});
		}
	});
}
=cut

sub _storeTracks {
	my ($tracks, $libraryId) = @_;

	return unless $tracks && ref $tracks;

	my $dbh = Slim::Schema->dbh();
	my $sth = $dbh->prepare_cached("INSERT OR IGNORE INTO library_track (library, track) VALUES (?, ?)") if $libraryId;
	my $c = 0;

	my $splitChar = substr(preferences('server')->get('splitList'), 0, 1) || ' ';

	foreach my $track (@$tracks) {
		my $item = $libraryCache->get($track->{uri}) || $track;

		my $artist = join($splitChar, map { $_->{name} } @{ $item->{album}->{artists} || [$item->{artists}->[0]] });
		my $extId = join(',', map { $_->{uri} } @{ $item->{album}->{artists} || [$item->{artists}->[0]] });

		my $trackObj = Slim::Schema->updateOrCreate({
			url        => $item->{uri},
			integrateRemote => 1,
			attributes => {
				TITLE        => $item->{name},
				ARTIST       => $artist,
				ARTIST_EXTID => $extId,
				TRACKARTIST  => join($splitChar, map { $_->{name} } @{ $item->{artists} }),
				ALBUM        => $item->{album}->{name},
				ALBUM_EXTID  => $item->{album}->{uri},
				TRACKNUM     => $item->{track_number},
				GENRE        => 'Spotify',
				DISC         => $item->{disc_number},
				SECS         => $item->{duration_ms}/1000,
				YEAR         => substr($item->{release_date} || $item->{album}->{release_date}, 0, 4),
				COVER        => $item->{album}->{image},
				AUDIO        => 1,
				EXTID        => $item->{uri},
				COMPILATION  => $item->{album}->{album_type} eq 'compilation',
				CONTENT_TYPE => 'spt'
			},
		});

		if ($libraryId) {
			$sth->execute($libraryId, $trackObj->id);
		}

		if (!main::SCANNER && ++$c % 20 == 0) {
			main::idle();
		}
	}

	main::idle() if !main::SCANNER;
}

1;
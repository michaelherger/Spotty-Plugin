package Plugins::Spotty::Importer;

use strict;

use Date::Parse qw(str2time);
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
use Slim::Music::OnlineLibraryScan;
use Slim::Utils::Prefs;
use Slim::Utils::Progress;
use Slim::Utils::Strings qw(string);

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::API::Cache;
use Plugins::Spotty::API::Token;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');
my $libraryCache = Plugins::Spotty::API::Cache->new();
my $cache = Slim::Utils::Cache->new();

sub initPlugin {
	my $class = shift;

	if (!CAN_IMPORTER) {
		$log->warn('The library importer feature requires at least Logitech Media Server 8.');
		return;
	}

	return if !Slim::Music::OnlineLibraryScan->isImportEnabled($class);

	Slim::Music::Import->addImporter($class, {
		'type'         => 'file',
		'weight'       => 200,
		'use'          => 1,
		'playlistOnly' => 1,
		'onlineLibraryOnly' => 1,
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

			my ($albums, $libraryMeta) = $api->myAlbums();
			$progress->total(scalar @$albums + 2);

			$cache->set('spotty_latest_album_update' . $accountId, _libraryMetaId($libraryMeta), 86400);

			main::INFOLOG && $log->is_info && $log->info("Getting missing album information...");
			foreach (@$albums) {
				my $cached = $libraryCache->get($_->{uri});
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

		my $timestamp = time() + 86400;
		my $snapshotIds = { map {
			$_->{id} => ($_->{creator} eq 'spotify' ? $timestamp : $_->{snapshot_id})
		} @$playlists };

		$cache->set('spotty_snapshot_ids' . $accountId, $snapshotIds, 86400);

		main::INFOLOG && $log->is_info && $log->info("Done, finally!");

		$progress->final();
	}

	Slim::Music::Import->endImporter($class);
}

# This code is not run in the scanner, but in LMS
sub needsUpdate {
	my ($class, $cb) = @_;

	require Async::Util;
	require Plugins::Spotty::API;

	my $timestamp = time();

	my @workers;
	foreach my $client (Slim::Player::Client::clients()) {
		my $accountId = Plugins::Spotty::AccountHelper->getAccount($client);

		push @workers, sub {
			my ($result, $acb) = @_;

			# don't run any further test in the queue if we already have a result
			return $acb->($result) if $result;

			my $snapshotIds = $cache->get('spotty_snapshot_ids' . $accountId);

			my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
			$api->playlists(sub {
				my ($playlists) = @_;

				my $needUpdate;
				for my $playlist (@$playlists) {
					my $snapshotId = $snapshotIds->{$playlist->{id}};
					# we need an update if
					# - we haven't a snapshot ID for this playlist, OR
					# - the snapshot ID doesn't match, OR
					# - the playlist is Spotify generated and older than a day
					if ( !$snapshotId || ($snapshotId =~ /^\d{10}$/ ? $snapshotId < $timestamp : $snapshotId ne $playlist->{snapshot_id}) ) {
						$needUpdate = 1;
						last;
					}
				}

				$acb->($needUpdate);
			});
		};

		push @workers, sub {
			my ($result, $acb) = @_;

			# don't run any further test in the queue if we already have a result
			return $acb->($result) if $result;

			my $lastUpdateData = $cache->get('spotty_latest_album_update' . $accountId) || '';

			my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
			$api->myAlbumsMeta(sub {
				$acb->(_libraryMetaId($_[0]) eq $lastUpdateData ? 0 : 1);
			});
		};
	}

	if (scalar @workers) {
		Async::Util::achain(
			input => undef,
			steps => \@workers,
			cb    => sub {
				my ($result, $error) = @_;
				$cb->( ($result && !$error) ? 1 : 0 );
			}
		);
	}
	else {
		$cb->();
	}
}

sub _libraryMetaId {
	my $libraryMeta = $_[0];
	return ($libraryMeta->{total} || '') . '|' . ($libraryMeta->{lastAdded} || '');
}

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
				# ??? DISCC?
				SECS         => $item->{duration_ms}/1000,
				YEAR         => substr($item->{release_date} || $item->{album}->{release_date}, 0, 4),
				COVER        => $item->{album}->{image},
				AUDIO        => 1,
				EXTID        => $item->{uri},
				COMPILATION  => $item->{album}->{album_type} eq 'compilation',
				TIMESTAMP    => str2time($item->{album}->{added_at} || 0),
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
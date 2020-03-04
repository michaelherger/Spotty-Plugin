package Plugins::Spotty::Importer;

use strict;

# can't "use base ()", as this would fail in LMS 7
BEGIN {
	eval {
		require Slim::Plugin::OnlineLibraryBase;
		our @ISA = qw(Slim::Plugin::OnlineLibraryBase);
	};
}

use Date::Parse qw(str2time);
use Digest::MD5 qw(md5_hex);

use Slim::Utils::Log;
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

my $dbh;

sub initPlugin {
	my $class = shift;

	if (!CAN_IMPORTER) {
		$log->warn('The library importer feature requires at least Logitech Media Server 8.');
		return;
	}

	$class->SUPER::initPlugin(@_)
}

sub startScan { if (main::SCANNER) {
	my $class = shift;
	require Plugins::Spotty::API::Sync;

	my $accounts = Plugins::Spotty::AccountHelper->getAllCredentials();

	if (ref $accounts && scalar keys %$accounts) {
		$dbh ||= Slim::Schema->dbh();
		$class->initOnlineTracksTable();

		if (!Slim::Music::Import->scanPlaylistsOnly()) {
			$class->scanAlbums($accounts);
			$class->scanArtists($accounts);
		}

		$class->scanPlaylists($accounts);

		$class->deleteRemovedTracks();
	}

	Slim::Music::Import->endImporter($class);
} }

sub scanAlbums { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress;
	# my $deleteLibrary_sth   = $dbh->prepare_cached("DELETE FROM library_track WHERE library = ?");

	foreach my $account (keys %$accounts) {
		my $accountId = $accounts->{$account};
		my $api = Plugins::Spotty::API::Sync->new($accountId);

		if ($progress) {
			$progress->total($progress->total + 1);
		}
		else {
			$progress = Slim::Utils::Progress->new({
				'type'  => 'importer',
				'name'  => 'plugin_spotty_albums',
				'total' => 1,
				'every' => 1,
			});
		}

		# if we've got more than one user, then create a virtual library per user
		# TODO - library support doesn't really work yet. Needs more investigation.
		my $libraryId;
		# if (scalar keys %$accounts > 1) {
		# 	$libraryId = md5_hex($accountId);
		# 	$deleteLibrary_sth->execute($libraryId);
		# }

		my @missingAlbums;

		main::INFOLOG && $log->is_info && $log->info("Reading albums...");
		$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_ALBUMS', $account));

		my ($albums, $libraryMeta) = $api->myAlbums();
		$progress->total($progress->total + scalar @$albums + 1);

		$cache->set('spotty_latest_album_update' . $accountId, $class->libraryMetaId($libraryMeta), 86400 * 7);

		main::INFOLOG && $log->is_info && $log->info("Getting missing album information...");
		foreach (@$albums) {
			my $cached = $libraryCache->get($_->{uri});
			if (!$cached || !$cached->{image}) {
				push @missingAlbums, $_->{id};
			}
		}

		$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_TRACKS', $account));
		$api->albums(\@missingAlbums);

		main::INFOLOG && $log->is_info && $log->info("Importing album tracks...");
		foreach (@$albums) {
			$progress->update($account . string('COLON') . ' ' . $_->{name});
			main::SCANNER && Slim::Schema->forceCommit;

			$class->storeTracks([
				map { _prepareTrack($_) } @{$_->{tracks}}
			], $libraryId);
		}

		# if ($libraryId) {
		# 	Slim::Music::VirtualLibraries->unregisterLibrary($accountId . 'AndLocal');
		# 	Slim::Music::VirtualLibraries->registerLibrary({
		# 		id => $accountId . 'AndLocal',
		# 		name => Plugins::Spotty::AccountHelper->getDisplayName($account),
		# 		priority => 10,
		# 		sql => qq{
		# 			SELECT tracks.id
		# 			FROM tracks
		# 			WHERE tracks.url like 'file://%' OR tracks.id IN (
		# 				SELECT library_track.track
		# 				FROM library_track
		# 				WHERE library_track.library = '$libraryId'
		# 			)
		# 		},
		# 	});

		# 	Slim::Music::VirtualLibraries->unregisterLibrary($accountId);
		# 	Slim::Music::VirtualLibraries->registerLibrary({
		# 		id => $accountId,
		# 		name => Plugins::Spotty::AccountHelper->getDisplayName($account) . ' (Spotty)',
		# 		priority => 20,
		# 		scannerCB => sub {
		# 			my ($id) = @_;

		# 			# needs to be declared locally as it's called in this callback
		# 			my $dbh = Slim::Schema->dbh();
		# 			my $insertTrackInLibrary_sth = $dbh->prepare_cached("UPDATE library_track SET library = ? WHERE library = ?");
		# 			$insertTrackInLibrary_sth->execute($id, $libraryId);
		# 		}
		# 	});
		# }

		main::SCANNER && Slim::Schema->forceCommit;
	}

	$progress->final() if $progress;
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanArtists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress;

	foreach my $account (keys %$accounts) {
		my $accountId = $accounts->{$account};
		my $api = Plugins::Spotty::API::Sync->new($accountId);

		if ($progress) {
			$progress->total($progress->total + 1);
		}
		else {
			$progress = Slim::Utils::Progress->new({
				'type'  => 'importer',
				'name'  => 'plugin_spotty_artists',
				'total' => 1,
				'every' => 1,
			});
		}

		main::INFOLOG && $log->is_info && $log->info("Reading artists...");
		$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_ARTISTS', $account));

		my ($artists, $libraryMeta) = $api->myArtists();

		$cache->set('spotty_latest_artists_update' . $accountId, $class->libraryMetaId($libraryMeta), 86400 * 7);

		$progress->total($progress->total + scalar @$artists + 1);

		foreach my $artist (@$artists) {
			my $name = $artist->{name};

			$progress->update($account . string('COLON') . ' ' . $name);
			main::SCANNER && Slim::Schema->forceCommit;

			Slim::Schema->rs('Contributor')->update_or_create({
				'name'       => $name,
				'namesort'   => Slim::Utils::Text::ignoreCaseArticles($name),
				'namesearch' => Slim::Utils::Text::ignoreCase($name, 1),
				'extid'      => $artist->{uri},
			}, { 'key' => 'namesearch' });
		}

		main::SCANNER && Slim::Schema->forceCommit;
	}

	$progress->final() if $progress;
	main::SCANNER && Slim::Schema->forceCommit;
} }

sub scanPlaylists { if (main::SCANNER) {
	my ($class, $accounts) = @_;

	my $progress = Slim::Utils::Progress->new({
		'type'  => 'importer',
		'name'  => 'plugin_spotty_playlists',
		'total' => 1,
		'every' => 1,
	});

	main::INFOLOG && $log->is_info && $log->info("Removing playlists...");
	$progress->update(string('PLAYLIST_DELETED_PROGRESS'));
	my $deletePlaylists_sth = $dbh->prepare_cached("DELETE FROM tracks WHERE url LIKE 'spotify:playlist:%'");
	$deletePlaylists_sth->execute();

	foreach my $account (keys %$accounts) {
		my $accountId = $accounts->{$account};
		my $api = Plugins::Spotty::API::Sync->new($accountId);

		$progress->total($progress->total + 1);
		$progress->update(string('PLUGIN_SPOTTY_PROGRESS_READ_PLAYLISTS', $account));

		main::INFOLOG && $log->is_info && $log->info("Reading playlists...");
		my $playlists = $api->myPlaylists();

		$progress->total($progress->total + (scalar @$playlists)*2);

		my %tracks;
		my $c = 0;

		main::INFOLOG && $log->is_info && $log->info("Getting playlist tracks...");

		# we need to get the tracks first
		foreach my $playlist (@{$playlists || []}) {
			$progress->update($account . string('COLON') . ' ' . $playlist->{name});
			Slim::Schema->forceCommit;

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

		my $prefix = 'Spotify' . string('COLON') . ' ';
		# now store the playlists with the tracks
		foreach my $playlist (@{$playlists || []}) {
			$progress->update($account . string('COLON') . ' ' . $playlist->{name});
			my $playlistObj = Slim::Schema->updateOrCreate({
				url        => $playlist->{uri},
				playlist   => 1,
				integrateRemote => 1,
				attributes => {
					TITLE        => $prefix . $playlist->{name},
					COVER        => $playlist->{image},
					AUDIO        => 1,
					EXTID        => $playlist->{uri},
					CONTENT_TYPE => 'ssp'
				},
			});

			$playlistObj->setTracks($cache->get('spotty_playlist_tracks_' . $playlist->{id}));
			Slim::Schema->forceCommit;
		}

		my $timestamp = time() + 86400;
		my $snapshotIds = { map {
			$_->{id} => ($_->{creator} eq 'spotify' ? $timestamp : $_->{snapshot_id})
		} @$playlists };

		$cache->set('spotty_snapshot_ids' . $accountId, $snapshotIds, 86400 * 7);

		main::INFOLOG && $log->is_info && $log->info("Done, finally!");
		Slim::Schema->forceCommit;
	}

	$progress->final() if $progress;
	Slim::Schema->forceCommit;
} }

sub trackUriPrefix { 'spotify:track:' }

sub getArtistPicture { if (main::SCANNER) {
	my ($class, $id) = @_;

	my $api = Plugins::Spotty::API::Sync->new() || return '';
	my $artist = $api->artist($id);
	return ($artist && ref $artist) ? $artist->{image} : '';
} }

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
				$acb->($class->libraryMetaId($_[0]) eq $lastUpdateData ? 0 : 1);
			});
		};

		push @workers, sub {
			my ($result, $acb) = @_;

			# don't run any further test in the queue if we already have a result
			return $acb->($result) if $result;

			my $lastUpdateData = $cache->get('spotty_latest_artists_update' . $accountId) || '';

			my $api = Plugins::Spotty::Plugin->getAPIHandler($client);
			$api->myArtists(sub {
				my $artists = shift;

				my $libraryMeta = {
					total => scalar @$artists,
					hash  => md5_hex(join('|', sort map { $_->{id} } @$artists)),
				};

				$acb->($class->libraryMetaId($libraryMeta) eq $lastUpdateData ? 0 : 1);
			}, 1);
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

sub _prepareTrack {
	my ($track) = @_;

	my $splitChar = substr(preferences('server')->get('splitList'), 0, 1);

	my $item = $libraryCache->get($track->{uri}) || $track;

	my $artist = join($splitChar, map { $_->{name} } @{ $item->{album}->{artists} || [$item->{artists}->[0]] });
	my $extId  = join($splitChar, map { $_->{uri} } @{ $item->{album}->{artists} || [$item->{artists}->[0]] });

	return {
		url          => $item->{uri},
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
	};
}

1;
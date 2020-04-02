package Plugins::Spotty::API;

use strict;
use Exporter::Lite;

BEGIN {
	use constant LIBRARY_LIMIT => 500;
	use constant RECOMMENDATION_LIMIT => 100;		# for whatever reason this call does support a maximum chunk size of 100
	use constant DEFAULT_LIMIT => 200;
	use constant MAX_LIMIT => 10_000;
	use constant SPOTIFY_LIMIT => 50;

	use Exporter::Lite;
	our @EXPORT_OK = qw( SPOTIFY_LIMIT DEFAULT_LIMIT uri2url );
}

use base qw(Slim::Utils::Accessor);

use Digest::MD5 qw(md5_hex);
use JSON::XS::VersionOneAndTwo;
use List::Util qw(min max);
use POSIX qw(strftime);
use Scalar::Util qw(blessed);
use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::Plugin;
use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::Helper;
use Plugins::Spotty::API::Pipeline;
use Plugins::Spotty::API::AsyncRequest;
use Plugins::Spotty::API::Token;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);

my $log = logger('plugin.spotty');
my $cache = Slim::Utils::Cache->new();

use Plugins::Spotty::API::Cache;
my $libraryCache = Plugins::Spotty::API::Cache->new();

my $prefs = preferences('plugin.spotty');
my $error429;
my %tokenHandlers;

{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		cache
		_username
		_country
		_canPodcast
	) );
}

sub new {
	my ($class, $args) = @_;

	my $self = $class->SUPER::new();

	$self->client($args->{client});
	$self->cache($args->{cache});
	$self->_username($args->{username});

	$self->_country($prefs->get('country'));

	# update our profile ASAP
	$self->me();

	return $self;
}

sub getToken {
	my ( $self, $cb ) = @_;

	if ($cache->get('spotty_rate_limit_exceeded')) {
		return $cb->(-429) ;
	}

	my $username = $self->username || 'generic';

	my $token = $cache->get('spotty_access_token' . Slim::Utils::Unicode::utf8toLatin1Transliterate($username));

	if (main::DEBUGLOG && $log->is_debug) {
		if ($token) {
			$log->debug("Found cached token: $token");
		}
		else {
			$log->debug("Didn't find cached token. Need to refresh.");
		}
	}

	if ($token) {
		$cb->($token);
	}
	else {
		Plugins::Spotty::API::Token->get($self, $cb);
	}
}

sub me {
	my ( $self, $cb ) = @_;

	$self->_call('me',
		sub {
			my $result = shift;
			if ( $result && ref $result ) {
				$self->country($result->{country});
				$self->_username($result->{username}) if $result->{username};
				Plugins::Spotty::AccountHelper->setName($self->username, $result);

				$cb->($result) if $cb;
			}
		}
	);
}

# get the username - keep it simple. Shouldn't change, don't want nested async calls...
sub username {
	my ($self, $username) = @_;

	$self->_username($username) if $username;
	return $self->_username if $self->_username;

	# fall back to default account if no username was given
	my $credentials = Plugins::Spotty::AccountHelper->getCredentials($self->client);
	if ( $credentials && $credentials->{username} ) {
		$self->_username($credentials->{username})
	}

	return $self->_username;
}

# get the user's country - keep it simple. Shouldn't change, don't want nested async calls...
sub country {
	my ($self, $country) = @_;

	if ($country) {
		$self->_country($country);
		$prefs->set('country', $country);
	}

	return $self->_country || 'US';
}

sub locale {
	cstring($_[0]->client, 'LOCALE');
}

sub user {
	my ( $self, $cb, $username ) = @_;

	if (!$username) {
		$cb->([]);
		return;
	}

	# usernames must be lower case, and space not URI encoded
	$username = lc($username);
	$username =~ s/ /\+/g;

	$self->_call('users/' . uri_escape_utf8($username),
		sub {
			my ($result) = @_;

			if ( $result && ref $result ) {
				$result->{image} = $libraryCache->getLargestArtwork(delete $result->{images});
			}

			$cb->($result || {});
		}
	);
}

sub player {
	my ( $self, $cb ) = @_;

	$self->_call('me/player',
		sub {
			my ($result) = @_;

			if ($result && ref $result) {
				$result->{progress} = $result->{progress_ms} ? $result->{progress_ms} / 1000 : 0;

				if ($result->{item} && $result->{item}->{type} eq 'track') {
					$result->{track} = $libraryCache->normalize($result->{item});
				}

				# keep track of MAC -> ID mapping
				if ( Plugins::Spotty::Connect->canSpotifyConnect() ) {
					Plugins::Spotty::Connect::DaemonManager->checkAPIConnectPlayer($self, $result);
				}

				$cb->($result);
				return;
			}

			$cb->();
		},
		GET => {
			_nocache => 1,
			market => 'from_token',
		}
	)
}

sub playerTransfer {
	my ( $self, $cb, $device ) = @_;

	$self->withIdFromMac(sub {
		my $deviceId = shift;

		if (!$deviceId) {
			$cb->() if $cb;
			return;
		}

		$self->_call('me/player',
			sub {
				$cb->() if $cb;
			},
			PUT => {
				body => encode_json({
					device_ids => [ $deviceId ],
					play => 1
				})
			}
		);
	}, $device);
}

=pod
sub playerPlay {
	my ( $self, $cb, $device, $args ) = @_;

	$self->withIdFromMac(sub {
		$args ||= {};
		$args->{device_id} = $_[0] if $_[0];

		$self->_call('me/player/play',
			sub {
				$cb->() if $cb;
			},
			PUT => $args
		);
	}, $device);
}
=cut

sub playerPause {
	my ( $self, $cb, $device ) = @_;

	$self->withIdFromMac(sub {
		my $args = {};
		$args->{device_id} = $_[0] if $_[0];

		$self->_call('me/player/pause',
			sub {
				$cb->() if $cb;
			},
			PUT => $args
		);
	}, $device);
}

sub playerNext {
	my ( $self, $cb, $device ) = @_;

	$self->withIdFromMac(sub {
		my $args = {};
		$args->{device_id} = $_[0] if $_[0];

		$self->_call('me/player/next',
			sub {
				$cb->() if $cb;
			},
			POST => $args
		);
	}, $device);
}

sub playerSeek {
	my ( $self, $cb, $device, $songtime ) = @_;

	$self->withIdFromMac(sub {
		my $args = {
			position_ms => int($songtime * 1000),
		};

		$args->{device_id} = $_[0] if $_[0];

		$self->_call('me/player/seek',
			sub {
				$cb->() if $cb;
			},
			PUT => $args
		);
	}, $device);
}

sub playerVolume {
	my ( $self, $cb, $device, $volume ) = @_;

	$self->withIdFromMac(sub {
		my $args = {
			volume_percent => $volume,
		};

		$args->{device_id} = $_[0] if $_[0];

		$self->_call('me/player/volume',
			sub {
				$cb->() if $cb;
			},
			PUT => $args
		);
	}, $device);
}

sub idFromMac {
	my ( $class, $mac ) = @_;

	return Plugins::Spotty::Connect->canSpotifyConnect()
		&& Plugins::Spotty::Connect::DaemonManager->idFromMac($mac);
}

sub withIdFromMac {
	my ( $self, $cb, $mac ) = @_;

	my $id = $self->idFromMac($mac);

	if ( $id || $mac !~ /((?:[a-f0-9]{2}:){5}[a-f0-9]{2})/i ) {
		$cb->($id || $mac);
	}
	else {
		# ID wasn't in the cache yet, let's get the playerlist
		$self->devices(sub {
			$cb->($self->idFromMac($mac));
		});
	}
}

sub devices {
	my ( $self, $cb ) = @_;

	$self->_call('me/player/devices',
		sub {
			my ($result) = @_;

			if ( Plugins::Spotty::Connect->canSpotifyConnect() ) {
				Plugins::Spotty::Connect::DaemonManager->checkAPIConnectPlayers($self, $result);
			}

			$cb->() if $cb;
		},
		GET => {
			_nocache => 1,
		}
	);
}

sub search {
	my ( $self, $cb, $args ) = @_;

	return $cb->([]) unless $args->{query} || $args->{series};

	my $type = $args->{type} || 'track';

	my $params = $args->{series}
	? { chunks => $args->{series} }
	: {
		q      => $args->{query},
		type   => $type,
		market => 'from_token',
		limit  => $args->{limit} || DEFAULT_LIMIT
	};

	if ( $type =~ /album|artist|track|playlist|show_audio|episode_audio/ ) {
		Plugins::Spotty::API::Pipeline->new($self, 'search', sub {
			my $type = $type . 's';
			$type =~ s/_audio//;

			my $items = [];

			for my $item ( @{ $_[0]->{$type}->{items} } ) {
				# sometimes we'd get empty list items...
				next unless $item;

				if (main::INFOLOG) {
				# if (main::INFOLOG && $log->is_info) {
					if ( $item->{is_externally_hosted} || ($item->{media_type} || 'audio') ne 'audio' ) {
						$log->warn("This item might need inspection: " . Data::Dump::dump($item));
					}
				}

				$item = $libraryCache->normalize($item);

				push @$items, $item;
			}

			return $items, $_[0]->{$type}->{total}, $_[0]->{$type}->{'next'};
		}, $cb, $params)->get();
	}
	else {
		$log->error("Unknown search type: $type");
		$cb->([])
	}
}

sub album {
	my ( $self, $cb, $args ) = @_;

	my ($id) = $args->{uri} =~ /album:(.*)/;

	$self->_call('albums/' . $id,
		sub {
			my ($album) = @_;

			my $total = $album->{tracks}->{total} if $album->{tracks} && ref $album->{tracks};

			$album = $libraryCache->normalize($album);

			# we might need to grab more tracks: audio books can have hundreds of "tracks"
			if ( $total && $total > SPOTIFY_LIMIT ) {
				Plugins::Spotty::API::Pipeline->new($self, 'albums/' . $id . '/tracks', sub {
					my $items = [];

					my $minAlbum = {
						name => $album->{name},
						image => $album->{image},
					};

					for my $track ( @{ $_[0]->{items} } ) {
						# Add missing album data to track
						$track->{album} = $minAlbum;
						push @$items, $libraryCache->normalize($track);
					}

					return $items, $_[0]->{total}, $_[0]->{'next'};
				}, sub {
					$album->{tracks} = $_[0];
					$cb->($album);
				},{
					market => 'from_token',
					limit  => $args->{limit} || max(LIBRARY_LIMIT, _DEFAULT_LIMIT())
				})->get();

				return;
			}

			$cb->($album);
		},
		GET => {
			market => 'from_token',
			limit  => min($args->{limit} || SPOTIFY_LIMIT, SPOTIFY_LIMIT),
			offset => $args->{offset} || 0,
		}
	);
}

sub addAlbumToLibrary {
	my ( $self, $cb, $albumIds ) = @_;

	$albumIds = join(',', @$albumIds) if ref $albumIds;

	$self->_call("me/albums",
		$cb,
		PUT => {
			ids => $albumIds,
		}
	);
}

sub artist {
	my ( $self, $cb, $args ) = @_;

	my ($id) = $args->{uri} =~ /artist:(.*)/;

	$self->_call('artists/' . $id,
		sub {
			my $artist = $libraryCache->normalize($_[0]);
			$cb->($artist);
		},
		GET => {
			market => 'from_token',
			limit  => min($args->{limit} || SPOTIFY_LIMIT, SPOTIFY_LIMIT),
			offset => $args->{offset} || 0,
		}
	);
}

sub artists {
	my ( $self, $cb, $ids ) = @_;

	if (!ref $ids) {
		$ids = [ $ids ];
	}

	$ids = [ map { /artist:(.*)/ ? $1 : $_ } @$ids ];

	if (!scalar @$ids) {
		$cb->([]);
		return;
	}

	my $chunks = {};

	# build list of chunks we can query in one go
	while ( my @ids = splice @$ids, 0, SPOTIFY_LIMIT) {
		my $idList = join(',', @ids) || next;
		$chunks->{md5_hex($idList)} = {
			ids => $idList
		};
	}

	Plugins::Spotty::API::Pipeline->new($self, 'artists', sub {
		my ($artists) = @_;

		my @artists;

		foreach (@{$artists->{artists}}) {
			# null album info for invalid IDs is returned
			next unless $_ && ref $_;

			my $artist = $libraryCache->normalize($_);

			push @artists, $artist;
		}

		return \@artists;
	}, $cb, {
		chunks => $chunks,
	})->get();
}

sub relatedArtists {
	my ( $self, $cb, $uri ) = @_;

	my ($id) = $uri =~ /artist:(.*)/;

	Plugins::Spotty::API::Pipeline->new($self, 'artists/' . $id . '/related-artists', sub {
		my $artists = $_[0] || {};
		my $items = [ sort _artistSort map {
			$libraryCache->normalize($_)
		} @{$artists->{artists} || []} ];

		return $items, $artists->{total}, $artists->{'next'};
	}, $cb)->get();
}

sub artistTracks {
	my ( $self, $cb, $args ) = @_;

	my ($id) = $args->{uri} =~ /artist:(.*)/;

	$self->_call('artists/' . $id . '/top-tracks',
		sub {
			my $tracks = $_[0] || {};
			$cb->([ map { $libraryCache->normalize($_) } @{$tracks->{tracks} || []} ]);
		},
		GET => {
			# Why the heck would this call need country rather than market?!? And no "from_token"?!?
			country => $self->country(),
		}
	);
}

sub artistAlbums {
	my ( $self, $cb, $args ) = @_;

	my ($id) = $args->{uri} =~ /artist:(.*)/;

	Plugins::Spotty::API::Pipeline->new($self, 'artists/' . $id . '/albums', sub {
		my $albums = $_[0] || {};
		my $items = [ map { $libraryCache->normalize($_)} @{$albums->{items} || []} ];

		return $items, $albums->{total}, $albums->{'next'};
	}, $cb, {
		# "from_token" not allowed here?!?!
		market => $self->country,
		limit  => min($args->{limit} || _DEFAULT_LIMIT(), _DEFAULT_LIMIT()),
		offset => $args->{offset} || 0,
		include_groups => $args->{include} || 'album,single,appears_on,compilation',
	})->get();
}

sub followArtist {
	my ( $self, $cb, $artistIds ) = @_;

	$artistIds = join(',', @$artistIds) if ref $artistIds;

	$self->_call("me/following", $cb,
		PUT => {
			ids => $artistIds,
			type => 'artist'
		}
	);
}

sub playlist {
	my ( $self, $cb, $args ) = @_;

	my ($user, $id) = $self->getPlaylistUserAndId($args->{uri});

	my $limit = $args->{limit};
	# set the limit higher if it's the user's self curated playlist
	$limit ||= lc($user) eq lc($self->username) ? max(LIBRARY_LIMIT, _DEFAULT_LIMIT()) : _DEFAULT_LIMIT();

	Plugins::Spotty::API::Pipeline->new($self, 'playlists/' . $id . '/tracks', sub {
		my $items = [];

		my $cc = $self->country;
		for my $item ( @{ $_[0]->{items} } ) {
			my $track = $item->{track} || next;

			# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
			next unless $self->_isPlayable($track, $cc);

			push @$items, $libraryCache->normalize($track);
		}

		return $items, $_[0]->{total}, $_[0]->{'next'};
	}, $cb, {
		market => 'from_token',
		limit  => $limit
	})->get();
}

sub getPlaylistUserAndId {
	my ($self, $uri) = @_;

	my ($user, $id) = $uri =~ /^spotify:user:([^:]+):playlist:(.+)/;

	if ( !($user && $id) ) {
		($id) = $uri =~ /^spotify:.*?\bplaylist:(.+)/;
		$id ||= '';
		$user = $cache->get('playlist_owner_' . $id) || '';
	}

	return ($user, $id);
}

# USE CAREFULLY! Calling this too often might get us banned
sub track {
	my ( $self, $cb, $uri ) = @_;

	if ($self->canPodcast() && $uri =~ /episode:/) {
		$self->episode($cb, $uri);
	}
	else {
		$self->_track($cb, $uri);
	}
}

sub _track {
	my ( $self, $cb, $uri ) = @_;

	my $id = $uri;
	$id =~ s/(?:spotify|track)://g;

	$self->_call('tracks/' . $id, sub {
		my $track = $libraryCache->normalize(shift);
		$cb->($track, @_) if $cb;
	},
	GET => {
		market => 'from_token'
	});
}

sub episode {
	my ( $self, $cb, $uri ) = @_;

	my $id = $uri;
	$id =~ s/(?:spotify|episode)://g;

	$self->_call('episodes/' . $id, sub {
		my $episode = $libraryCache->normalize(shift);
		$cb->($episode, @_) if $cb;
	},
	GET => {
		market => 'from_token'
	});
}

sub trackCached {
	my ( $self, $cb, $uri, $args ) = @_;

	if ( $uri !~ /^spotify:(?:episode|track)/ ) {
		$cb->() if $cb;
		return;
	}

	if ( my $cached = $uri =~ /:episode:/ ? $cache->get($uri) : $libraryCache->get($uri) ) {
		$cb->($cached) if $cb;
		return $cached;
	}

	# look up track information unless told not to do so
	$self->track($cb, $uri) if blessed $self && !$args->{noLookup};
	return;
}

sub tracks {
	my ( $self, $cb, $ids ) = @_;

	if (!scalar @$ids) {
		$cb->([]);
		return;
	}

	$self->getToken(sub {
		my ($token) = @_;

		if ($token && $token =~ /^-\d+$/) {
			$cb->([ map {
				my $t = {
					title => 'Failed to get access token',
					duration => 1,
					uri => $_,
				};
				$cache->set($_, $t, 60);
				$t;
			} @$ids ]);
		}
		else {
			# TODO - this is potentially dangerous, as we're calling our callback twice.
			# In this particular case it's ok, but we have to fix this should there be more callers.
			$self->_tracks($cb, $ids);
			$self->_episodes($cb, $ids) if $self->canPodcast();
		}
	});
}

sub _tracks() {
	my ($self, $cb, undef, $type ) = @_;

	$type ||= 'track';

	my $chunks = {};

	my $ids = Storable::dclone($_[2]);

	# build list of chunks we can query in one go
	while ( my @ids = splice @$ids, 0, SPOTIFY_LIMIT) {
		my $idList = join(',', map { s/(?:spotify|$type)://g; $_ } grep { $_ && /^(?:spotify:$type|$type):/ } @ids) || next;
		$chunks->{md5_hex($idList)} = {
			market => 'from_token',
			ids => $idList
		};
	}

	if (!keys %$chunks) {
		return $cb->([]);
	}

	$type .= 's';

	Plugins::Spotty::API::Pipeline->new($self, $type, sub {
		my ($tracks) = @_;

		my @tracks;

		foreach (@{$tracks->{$type}}) {
			# track info for invalid IDs is returned
			next unless $_ && ref $_;

			my $track = $libraryCache->normalize($_);

			push @tracks, $track if $self->_isPlayable($_);
		}

		return \@tracks;
	}, $cb, {
		chunks => $chunks,
	})->get();
}

sub _episodes {
	my ($self, $cb, $ids ) = @_;

	$self->_tracks($cb, $ids, 'episode');
}

# try to get a list of track URI
sub trackURIsFromURI {
	my ( $self, $cb, $uri ) = @_;

	my $cb2 = sub {
		$cb->([ map {
			$_->{uri}
		} @{$_[0]} ])
	};

	my $params = {
		uri => $uri
	};

	if ($uri =~ /:playlist:/) {
		$self->playlist($cb2, $params);
	}
	elsif ( $uri =~ /:artist:/ ) {
		$self->artistTracks($cb2, $params);
	}
	elsif ( $uri =~ /:show:/ ) {
		$self->show(sub {
			$cb2->(($_[0] || {})->{episodes});
		}, $params);
	}
	elsif ( $uri =~ /:album:/ ) {
		$self->album(sub {
			$cb2->(($_[0] || {})->{tracks});
		}, $params);
	}
	elsif ( $uri =~ m{:/*(?:track|episode):} ) {
		$cb->([ $uri ]);
	}
	else {
		$log->warn("No tracks found for URI $uri");
		$cb->([]);
	}
}

sub mySongs {
	my ( $self, $cb, $fast ) = @_;

	Plugins::Spotty::API::Pipeline->new($self, 'me/tracks', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $libraryCache->normalize($_->{track}, $fast) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, sub {
		my $results = shift;

		my $items = [ sort { lc($a->{name}) cmp lc($b->{name}) } @{$results || []} ];
		$cb->($items);
	}, {
		limit => max(LIBRARY_LIMIT, _DEFAULT_LIMIT()),
	})->get();
}

sub myAlbums {
	my ( $self, $cb, $fast ) = @_;

	Plugins::Spotty::API::Pipeline->new($self, 'me/albums', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $libraryCache->normalize($_->{album}, $fast) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, sub {
		my $results = shift;

		my $items = [ sort { lc($a->{name}) cmp lc($b->{name}) } @{$results || []} ];
		$cb->($items);
	}, {
		limit => max(LIBRARY_LIMIT, _DEFAULT_LIMIT()),
	})->get();
}

sub myAlbumsMeta {
	my ( $self, $cb ) = @_;

	$self->_call('me/albums', sub {
		my ($response) = @_;

		my $libraryMeta = {};
		if ( $response && $response->{items} && ref $response->{items} ) {
			# keep track of some meta-information about the
			$libraryMeta = {
				total => $response->{total} || 0,
				lastAdded => $response->{items}->[0]->{added_at} || ''
			};
		}

		$cb->($libraryMeta);
	},
	GET => {
		limit => 1
	});
}

sub isInMyAlbums {
	my ( $self, $cb, $ids ) = @_;

	if (!$ids) {
		$cb->([]);
		return;
	}

	$ids = [split /,/, $ids] unless ref $ids;

	my $chunks = {};

	# build list of chunks we can query in one go
	while ( my @ids = splice @$ids, 0, SPOTIFY_LIMIT) {
		my $idList = join(',', map { s/.*://g; $_ } @ids) || next;
		$chunks->{$idList} = { ids => $idList };
	}

	Plugins::Spotty::API::Pipeline->new($self, 'me/albums/contains', sub {
		my ($tracks, $idList) = @_;

		my @ids = split(',', $idList);
		my @results;

		for ( my $x = 0; $x < min((scalar @ids), (scalar @{$tracks || []})) ; $x++ ) {
			push @results, {
				$ids[$x] => 1
			} if $tracks->[$x];
		}

		return \@results;
	}, sub {
		my ($tracks) = @_;

		$cb->({ map {
			my ($k, $v) = each %$_;
			$k => $v;
		} @$tracks });
	}, {
		chunks => $chunks,
	})->get();
}

sub myArtists {
	my ( $self, $cb, $noAlbumArtists ) = @_;

	# Getting the artists list is such a pain. Even when fetching every single request from cache,
	# this would be slow on some systems. Let's just cache the full result...
	my $cacheKey = 'spotify_my_artists' . Slim::Utils::Unicode::utf8toLatin1Transliterate($self->username || '');

	if ( my $cached = $cache->get($cacheKey) ) {
		$cb->($cached);
		return;
	}

	Plugins::Spotty::API::Pipeline->new($self, 'me/following', sub {
		if ( $_[0] && $_[0]->{artists} && $_[0]->{artists} && (my $artists = $_[0]->{artists}) ) {
			return [ map { $libraryCache->normalize($_, 'fast') } @{ $artists->{items} } ], $artists->{total}, $artists->{'next'};
		}
	}, sub {
		my $results = shift;

		# sometimes we get invalid list items back?!?
		my $items = [ grep { $_->{id} } @{$results || []} ];

		if ($noAlbumArtists) {
			$cb->($items);
			return;
		}

		my %knownArtists = map {
			my $id = $_->{id};
			$id => 1
		} @$items;

		# Spotify does include artists from saved albums in their apps, but doesn't provide an API call to do this.
		# Let's do it the hard way: get the list of artists for which we have a stored album.
		$self->myAlbums(sub {
			my $albums = shift || [];

			# the album object comes without the artist image - let's collect IDs and grab them later
			my $missingArtwork = [];

			foreach ( @$albums ) {
				next unless $_->{artists};

				if ( my $artist = $_->{artists}->[0] ) {
					if ( !$knownArtists{$artist->{id}}++ ) {
						$artist = $libraryCache->normalize($artist, 'fast');
						push @$items, $artist;

						if (!$artist->{image}) {
							push @$missingArtwork, $artist->{id};
						}
					}
				}
			}

			$items = [ sort _artistSort @$items ];

			# do one more lookup if the albums list returned artists we don't have artwork for, yet...
			if (scalar @$missingArtwork) {
				$self->artists(sub {
					# now let's merge these new results with what we had already...
					my %artists = map {
						$_->{id} => $libraryCache->normalize($_, 'fast')
					} @{shift || []};

					map {
						if (my $artist = $artists{$_->{id}}) {
							$_->{image} = $artist->{image};
						}
					} @$items;

					$cache->set($cacheKey, $items, 60);
					$cb->($items);
				}, $missingArtwork);
			}
			else {
				$cache->set($cacheKey, $items, 60);
				$cb->($items);
			}
		}, 'fast');
	}, {
		type  => 'artist',
		limit => max(LIBRARY_LIMIT, _DEFAULT_LIMIT()),
	})->get();
}

sub myShows {
	my ( $self, $cb ) = @_;

	Plugins::Spotty::API::Pipeline->new($self, 'me/shows', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $libraryCache->normalize($_->{show}) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, sub {
		my $results = shift;

		my $items = [ sort { lc($a->{name}) cmp lc($b->{name}) } @{$results || []} ];
		$cb->($items);
	}, {
		limit => max(LIBRARY_LIMIT, _DEFAULT_LIMIT()),
	})->get();
}

sub show {
	my ( $self, $cb, $args ) = @_;

	my ($id) = $args->{uri} =~ /show:(.*)/;

	$self->_call('shows/' . $id,
		sub {
			my ($show) = @_;

			my $total = $show->{episodes}->{total} if $show->{episodes} && ref $show->{episodes};

			$show = $libraryCache->normalize($show);
			$cb->($show);
		},
		GET => {
			market => 'from_token',
			limit  => min($args->{limit} || SPOTIFY_LIMIT, SPOTIFY_LIMIT),
			offset => $args->{offset} || 0,
		}
	);
}

sub addShowToLibrary {
	my ( $self, $cb, $showIds ) = @_;

	$showIds = join(',', @$showIds) if ref $showIds;

	$self->_call("me/shows",
		$cb,
		PUT => {
			ids => $showIds,
		}
	);
}

sub playlists {
	my ( $self, $cb, $args ) = @_;

	my $user = $args->{user} || $self->username || 'me';

	my $limit = $args->{limit};
	# set the limit higher if it's the user's self curated playlist
	$limit ||= lc($user) eq lc($self->username) ? max(LIBRARY_LIMIT, _DEFAULT_LIMIT()) : _DEFAULT_LIMIT();

	# usernames must be lower case, and space not URI encoded
	$user = lc($user);
	$user =~ s/ /\+/g;

	Plugins::Spotty::API::Pipeline->new($self, 'users/' . uri_escape_utf8($user) . '/playlists', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $libraryCache->normalize($_) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, $cb, {
		limit  => $limit
	})->get();
}

sub addTracksToPlaylist {
	my ( $self, $cb, $playlist, $trackIds ) = @_;

	if ( $playlist && $trackIds ) {
		$trackIds = join(',', @$trackIds) if ref $trackIds;

		my ($owner, $playlist) = $self->getPlaylistUserAndId($playlist);

		# usernames must be lower case, and space not URI encoded
		$owner = lc($owner);
		$owner =~ s/ /\+/g;

		$self->_call("playlists/$playlist/tracks?uris=$trackIds",
			$cb,
			POST => {
				ids => $trackIds,
				_nocache => 1,
			}
		);
	}
	else {
		$cb->({
			error => 'Error: missing parameters'
		});
	}
}

sub browse {
	my ( $self, $cb, $what, $key, $params ) = @_;

	return [] unless $what;

	$params ||= {};
	$params->{country} ||= $self->country;

 	my $message;

	Plugins::Spotty::API::Pipeline->new($self, "browse/$what", sub {
		my $result = shift;

 		$message ||= $result->{message};

 		if ($result && $result->{$key}) {
			my $cc = $self->country();

			my $items = [ map {
				$libraryCache->normalize($_)
			} grep {
				(!$_->{available_markets} || scalar grep /$cc/i, @{$_->{available_markets}}) ? 1 : 0;
			} @{$result->{$key}->{items} || []} ];

 			return $items, $result->{$key}->{total}, $result->{$key}->{'next'};
 		}
	}, sub {
		$cb->(shift, $message, @_)
	}, $params)->get();
}

sub newReleases {
	my ( $self, $cb ) = @_;
	$self->browse($cb, 'new-releases', 'albums');
}

sub categories {
	my ( $self, $cb ) = @_;

	$self->browse(sub {
		my ($result) = @_;

		my $items = [ map {
			{
				name  => $_->{name},
				id    => $_->{id},
				image => $libraryCache->getLargestArtwork($_->{icons})
			}
		} @$result ];

		$cb->($items);
	}, 'categories', 'categories', {
		locale => $self->locale,
	});
}

sub categoryPlaylists {
	my ( $self, $cb, $category ) = @_;
	$self->browse($cb, 'categories/' . $category . '/playlists', 'playlists');
}

sub featuredPlaylists {
	my ( $self, $cb ) = @_;

	# let's manipulate the timestamp so we only pull updates every few minutes
	my $timestamp = strftime("%Y-%m-%dT%H:%M:00", localtime(time()));
	$timestamp =~ s/\d(:00)$/0$1/;

	my $params = {
		locale => $self->locale,
		timestamp => $timestamp
	};

	$self->browse($cb, 'featured-playlists', 'playlists', $params);
}

sub recommendations {
	my ( $self, $cb, $args ) = @_;

	if ( !$args || (!$args->{seed_artists} && !$args->{seed_tracks} && !$args->{seed_genres}) ) {
		$cb->({ error => 'missing parameters' });
		return;
	}

	my $params = {
		_chunkSize => RECOMMENDATION_LIMIT
	};

	# copy seed information to params hash
	while ( my ($k, $v) = each %$args) {
		next if $k eq 'offset';

		if ( $k =~ /seed_(?:artists|tracks|genres)/ || $k =~ /^(?:min|max)_/ || $k =~ /^(?:limit)$/ ) {
			$params->{$k} = ref $v ? join(',', @$v) : $v;
		}
	}

	$params->{market} ||= $self->country;

	Plugins::Spotty::API::Pipeline->new($self, "recommendations", sub {
		my $result = shift;

 		if ($result && $result->{tracks}) {
			my $items = [ map { $libraryCache->normalize($_) } grep { $self->_isPlayable($_) } @{$result->{tracks}} ];

			my $total = scalar @$items;

			if ( my $seeds = $result->{seeds} ) {
				# see what the smallest pool size is - stop if we've reached it
				$total = min(map {
					min($_->{initialPoolSize}, $_->{afterFilteringSize}, $_->{afterRelinkingSize})
				} @$seeds) || 0;
			}

 			return $items, $total;
 		}
	}, $cb, $params)->get();
}

sub _artistSort {
	lc($a->{sortname} || $a->{name}) cmp lc($b->{sortname} || $b->{name});
}

sub _isPlayable {
	my ($self, $item, $cc) = @_;

	$cc ||= $self->country;

	# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
	return if defined $item->{is_playable} && !$item->{is_playable};
	return if $item->{is_local};

	return if $item->{available_markets} && !(scalar grep /$cc/i, @{$item->{available_markets}});

	return 1;
}

sub _call {
	my ( $self, $url, $cb, $type, $params ) = @_;

	$self->getToken(sub {
		my ($token) = @_;

		if ( !$token || $token =~ /^-(\d+)$/ ) {
			my $error = $1 || 'NO_ACCESS_TOKEN';
			$error = 'NO_ACCESS_TOKEN' if $error !~ /429/;

			$cb->({
				name => string('PLUGIN_SPOTTY_ERROR_' . $error),
				type => 'text'
			});
		}
		else {
			$type ||= 'GET';

			# $uri must not have a leading slash
			$url =~ s/^\///;

			my $content;

			my @headers = ( 'Accept' => 'application/json', 'Accept-Encoding' => 'gzip' );

			if ( !$params->{_no_auth_header} ) {
				push @headers, 'Authorization' => 'Bearer ' . $token;
			}

			if ( my @keys = sort keys %{$params}) {
				my @params;
				foreach my $key ( @keys ) {
					if ($key eq '_headers') {
						push @headers, @{$params->{$key}};
					}

					next if $key =~ /^_/;
					push @params, $key . '=' . uri_escape_utf8( $params->{$key} );
				}

				# PUT requests can come with a body, or query params. In case of body,
				# the caller should stringify the data already.
				if ( $type eq 'GET' || ($type eq 'PUT' && !$params->{body}) ) {
					$url .= '?' . join( '&', sort @params ) if scalar @params;
				}
				elsif ($type eq 'PUT' && $params->{body}) {
					$content .= $params->{body};
				}
				else {
					$content .= join( '&', sort @params );
				}
			}

			my $cached;
			my $cache_key;
			if (!$params->{_nocache} && $type eq 'GET') {
				$cache_key = md5_hex($url . ($url =~ /^me\b/ ? $token : ''));
			}

			main::INFOLOG && $log->is_info && $cache_key && $log->info("Trying to read from cache for $url");

			if ( $cache_key && ($cached = $cache->get($cache_key)) ) {
				main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url");
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
				$cb->($cached);
				return;
			}
			elsif ( main::INFOLOG && $log->is_info ) {
				$log->info("API call: $url");
				main::DEBUGLOG && $content && $log->is_debug && $log->debug($content);
			}

			my $http = Plugins::Spotty::API::AsyncRequest->new(
				sub {
					my $response = shift;
					my $params   = $response->params('params');

					if ($response->code =~ /429/) {
						$self->error429($response, $url);
					}

					my $result;

					if ( $response->headers->content_type =~ /json/i ) {
						eval {
							$result = decode_json(
								$response->content,
							);
						};

						$log->error("Failed to parse JSON response from $url: $@") if $@;

						main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

						if ( !$result || (ref $result && ref $result eq 'HASH' && $result->{error}) ) {
							$result = {
								error => 'Error: ' . ($result->{error_message} || 'Unknown error')
							};
							$log->error($result->{error} . ' (' . $url . ')');
						}
						elsif ( $cache_key ) {
							if ( my $cache_control = $response->headers->header('Cache-Control') ) {
								my ($ttl) = $cache_control =~ /max-age=(\d+)/;

								# cache some items even if max-age is zero. We're navigating them often
								# TODO - verify once usernames are being removed from the playlist ID
								if ( !$ttl && $response->url =~ m|/playlists/([A-Za-z0-9]{22})/tracks| ) {
									my ($user) = $self->getPlaylistUserAndId("spotify:playlist:$1");
									$user ||= '';

									if ( $user eq 'spotify' || $user eq 'spotifycharts' ) {
										$ttl = 3600;
									}
									elsif ( $user ne $self->username ) {
										$ttl = 300;
									}
								}

								$ttl ||= 60;		# we're going to always cache for a minute, as we often do follow up calls while navigating

								if ($ttl) {
									main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl using max-age (" . $response->url . ")");
									$cache->set($cache_key, $result, $ttl);
									main::INFOLOG && $log->is_info && $log->info("Data cached (" . $response->url . ")");
								}
							}
						}
					}
					elsif ( $type =~ /PUT|POST/ && $response->code =~ /^20\d/ ) {
						# ignore - v1/me/following doesn't return anything but 204 on success
						# ignore me/albums?ids=...
					}
					# requires us to enable cache - which leads to other issues
					# if request fails, then we're f...ed, there's not much we can do
					# elsif ( $type eq 'GET' && $response->code =~ /^20\d/
					# 	&& $response->cachedResponse && ($response->cachedResponse->{code} || 0) =~ /^20\d/
					# 	&& (my $json = eval { decode_json($response->cachedResponse->{content}) })
					# ) {
					# 	$log->warn("$url returned an unexpected code (" . $response->code . "). Using cached result instead");
					# 	$result = $json;
					# }
					else {
						$log->error("Invalid data");
						main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
						$result = {
							error => 'Error: Invalid data',
						};
					}

					$cb->($result, $response);
				},
				sub {
					my ($http, $error, $response) = @_;

					# log call if it hasn't been logged already
					if (!$log->is_info) {
						$log->warn("API call: $url");
						$content && $log->warn($content);
					}

					$log->warn("error: $error");

					if ($error =~ /429/ || ($response && $response->code == 429)) {
						$self->error429($response, $url);

						$cb->({
							name => string('PLUGIN_SPOTTY_ERROR_429'),
							type => 'text'
						}, $response);
					}
					else {
						main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
						$cb->({
							name => 'Unknown error: ' . $error,
							type => 'text'
						}, $response);
					}
				},
				{
					cache => $params->{_nocache} ? 0 : 1,
					expires => $params->{_expires} || 3600,
					timeout => 30,
					no_revalidate => $params->{_no_revalidate},
				},
			);

			if ( $type eq 'PUT' || $type eq 'POST' ) {
				push @headers, 'Content-Length' => length($content || '');
			}

			if ( $type eq 'POST' ) {
				$http->post($url, @headers, $content);
			}
			elsif ( $type eq 'PUT' ) {
				$http->put($url, @headers, $content);
			}
			else {
				$http->get($url, @headers);
			}
		}
	});
}

# if we get a "rate limit exceeded" error, pause for the given delay
sub error429 {
	my ($self, $response, $url) = @_;

	my $headers = $response->headers || {};

	# set special token to tell _call not to proceed
	$cache->set('spotty_rate_limit_exceeded', 1, $headers->{'retry-after'} || 5);

	$error429 = sprintf(string('PLUGIN_SPOTTY_ERROR_429_DESC'), $url, $headers->{'retry-after'} || 5);

	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug("Access rate exceeded: " . Data::Dump::dump($response));
	}
	else {
		$log->error($error429);
	}
}

sub uri2url {
	my ($uri) = @_;
	$uri =~ s/(^spotify:)/$1\/\//;
	return $uri;
}

sub hasError429 {
	return $error429;
}

sub canPodcast {
	my $self = $_[0];

	return $self->_canPodcast if defined $self->_canPodcast;

	$self->_canPodcast(Plugins::Spotty::Helper->getCapability('podcasts') || 0);
}

sub _DEFAULT_LIMIT {
	Plugins::Spotty::Plugin->hasDefaultIcon() ? DEFAULT_LIMIT : MAX_LIMIT;
};

1;

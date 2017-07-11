package Plugins::Spotty::API;

use strict;

BEGIN {
	use constant CACHE_TTL  => 86400 * 7;
	use constant LIBRARY_LIMIT => 500;
	use constant RECOMMENDATION_LIMIT => 100;		# for whatever reason this call does support a maximum chunk size of 100
	use constant DEFAULT_LIMIT => 200;
	use constant SPOTIFY_LIMIT => 50;

	use Exporter::Lite;
	our @EXPORT_OK = qw( SPOTIFY_LIMIT DEFAULT_LIMIT );
}

use base qw(Slim::Utils::Accessor);

use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);
use List::Util qw(min);
use POSIX qw(strftime);
use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::Plugin;
use Plugins::Spotty::API::Pipeline;
use Plugins::Spotty::API::AsyncRequest;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(cstring string);

my $log = logger('plugin.spotty');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.spotty');
my $error429;

# override the scope list hard-coded in to the spotty helper application
use constant SPOTIFY_SCOPE => join(',', qw(
  user-read-private
  user-follow-modify
  user-follow-read
  user-library-read
  user-library-modify
  user-top-read
  user-read-recently-played
  user-read-playback-state
  playlist-read-private
  playlist-read-collaborative
  playlist-modify-public
  playlist-modify-private
));


{
	__PACKAGE__->mk_accessor( 'rw', 'client');
	__PACKAGE__->mk_accessor( 'rw', '_username' );
	__PACKAGE__->mk_accessor( 'rw', '_country' );
}

sub new {
	my ($class, $args) = @_;
	
	my $self = $class->SUPER::new();

	$self->client($args->{client});
	$self->_username($args->{username});
	
	$self->_country($prefs->get('country'));
	
	# update our profile ASAP
	$self->me();
	
	return $self;
}

sub getToken {
	my ( $self, $force ) = @_;
	
	return '-429' if $cache->get('spotty_rate_limit_exceeded');
	
	my $cacheKey = 'spotty_access_token' . ($self->username || '');

	my $token = $cache->get($cacheKey) unless $force;
	
	if (main::DEBUGLOG && $log->is_debug) {
		if ($token) {
			$log->debug("Found cached token: $token");
		}
		else {
			$log->debug("Didn't find cached token. Need to refresh.");
		}
	}
	
	if ( $force || !$token ) {
		# try to use client specific credentials
		foreach ($prefs->client($self->client)->get('account'), undef) {
			my $cmd = sprintf('%s -n Squeezebox -c "%s" -i %s --get-token --scope "%s"', 
				scalar Plugins::Spotty::Plugin->getHelper(), 
				Plugins::Spotty::Plugin->cacheFolder($_),
				$prefs->get('iconCode'),
				SPOTIFY_SCOPE
			);
	
			my $response;
	
			eval {
				main::DEBUGLOG && $log->is_debug && $log->debug("Trying to get access token: $cmd");
				$response = `$cmd 2>&1`;
				main::INFOLOG && $log->is_info && $log->info("Got response: $response");
				$response = decode_json($response);
			};
			
			$log->error("Failed to get Spotify access token: $@ \n$response") if $@;
			
			if ( $response && ref $response ) {
				if ( $token = $response->{accessToken} ) {
					if ( main::INFOLOG && $log->is_info ) {
						$log->info("Received access token: " . Data::Dump::dump($response));
						$log->info("Caching for " . ($response->{expiresIn} || 3600) . " seconds.");
					}
					
					# Cache for the given expiry time (less some to be sure...)
					$cache->set($cacheKey, $token, ($response->{expiresIn} || 3600) - 300);
					last;
				}
			}
		}
	}
	
	if (!$token) {
		$log->error("Failed to get Spotify access token");
		# store special value to prevent hammering the backend
		$cache->set($cacheKey, $token = -1, 60);
	}
	
	return $token;
}

sub ready {
	my ($self) = @_;
	my $token = $self->getToken();
	
	return $token && $token !~ /^-\d+$/ ? 1 : 0;
}

sub me {
	my ( $self, $cb ) = @_;
	
	$self->_call('me',
		sub {
			my $result = shift;
			if ( $result && ref $result ) {
				$self->country($result->{country});
				$self->_username($result->{username}) if $result->{username};
				
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
	my $credentials = Plugins::Spotty::Plugin->getCredentials($self->client);
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
				$result->{image} = _getLargestArtwork(delete $result->{images});
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
				my $info = {
					deviceName => $result->{device}->{name}
				};

				if ($result->{item} && $result->{item}->{type} eq 'track') {
					$info->{track} = $self->_normalize($result->{item});
				}
				
				# unfortunately context only is transfered for playlists - otherwise let's assume the album
				if ($result->{context} && $result->{context}->{uri}) {
					$info->{context} = $result->{context}->{uri};
				}
				elsif ($info->{track} && $info->{track}->{album}) {
					$info->{context} = $info->{track}->{album}->{uri};
				}
				
				$info->{no_context} if !$result->{context};

				$info->{progress} = $result->{progress_ms} ? $result->{progress_ms} / 1000 : 0;
				$info->{shuffle_state} = $result->{shuffle_state};

				$cb->($info);
				return;
			}
			
			$cb->();
		}
	)
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
	
	if ( $type =~ /album|artist|track|playlist/ ) {
		Plugins::Spotty::API::Pipeline->new($self, 'search', sub {
			my $type = $type . 's';
			my $items = [];
			
			for my $item ( @{ $_[0]->{$type}->{items} } ) {
				$item = $self->_normalize($item);
	
				push @$items, $item;
			}

			return $items, $_[0]->{$type}->{total}, $_[0]->{$type}->{'next'};
		}, $cb, $params)->get();
	}
	else {
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

			$album = $self->_normalize($album);

			for my $track ( @{ $album->{tracks} || [] } ) {
				# Add missing album data to track
				$track->{album} = {
					name => $album->{name},
					image => $album->{image}, 
				};
				$track = $self->_normalize($track);
			}

			# we might need to grab more tracks: audio books can have hundreds of "tracks"
			if ( $total && $total > SPOTIFY_LIMIT ) {
				Plugins::Spotty::API::Pipeline->new($self, 'albums/' . $id . '/tracks', sub {
					my $items = [];
					
					for my $track ( @{ $_[0]->{items} } ) {
						# Add missing album data to track
						$track->{album} = {
							name => $album->{name},
							image => $album->{image}, 
						};
						push @$items, $self->_normalize($track);
					}
				
					return $items, $_[0]->{total}, $_[0]->{'next'};
				}, sub {
					$album->{tracks} = $_[0];
					$cb->($album);
				},{
					market => 'from_token',
					limit  => $args->{limit} || LIBRARY_LIMIT
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
			my $artist = $self->_normalize($_[0]);
			$cb->($artist);
		},
		GET => {
			market => 'from_token',
			limit  => min($args->{limit} || SPOTIFY_LIMIT, SPOTIFY_LIMIT),
			offset => $args->{offset} || 0,
		}
	);
}

sub relatedArtists {
	my ( $self, $cb, $uri ) = @_;

	my ($id) = $uri =~ /artist:(.*)/;
		
	Plugins::Spotty::API::Pipeline->new($self, 'artists/' . $id . '/related-artists', sub {
		my $artists = $_[0] || {};
		my $items = [ sort {
			lc($a->{sortname} || $a->{name}) cmp lc($b->{sortname} || $b->{name})
		} map { 
			$self->_normalize($_)
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
			$cb->([ map { $self->_normalize($_) } @{$tracks->{tracks} || []} ]);
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
		my $items = [ map { $self->_normalize($_)} @{$albums->{items} || []} ];

		return $items, $albums->{total}, $albums->{'next'};
	}, $cb, {
		# "from_token" not allowed here?!?!
		market => $self->country,
		limit  => min($args->{limit} || DEFAULT_LIMIT, DEFAULT_LIMIT),
		offset => $args->{offset} || 0,
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
	
	my ($user, $id) = $args->{uri} =~ /^spotify:user:([^:]+):playlist:(.+)/;
	
	Plugins::Spotty::API::Pipeline->new($self, 'users/' . $user . '/playlists/' . $id . '/tracks', sub {
		my $items = [];
		
		my $cc = $self->country;
		for my $item ( @{ $_[0]->{items} } ) {
			my $track = $item->{track} || next;
					
			# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
			next if defined $track->{is_playable} && !$track->{is_playable};
					
			next if $track->{available_markets} && !(scalar grep /$cc/i, @{$track->{available_markets}});

			push @$items, $self->_normalize($track);
		}
	
		return $items, $_[0]->{total}, $_[0]->{'next'};
	}, $cb, {
		market => 'from_token',
		limit  => $args->{limit} || DEFAULT_LIMIT
	})->get();
}

# USE CAREFULLY! Calling this too often might get us banned
sub track {
	my ( $self, $cb, $uri ) = @_;

	my $id = $uri;
	$id =~ s/(?:spotify|track)://g;

	$self->_call('tracks/' . $id, sub {
		$cb->(@_) if $cb;
	}, {
		market => 'from_token'
	})
}

sub trackCached {
	my ( $self, $cb, $uri, $args ) = @_;
	
	if ( $uri !~ /^spotify:track/ ) {
		$cb->() if $cb;
		return;
	}
	
	if ( my $cached = $cache->get($uri) ) {
		$cb->($cached) if $cb;
		return $cached;
	}
	
	# look up track information unless told not to do so
	$self->track($cb, $uri) if !$args->{noLookup};
	return;
}

sub tracks {
	my ( $self, $cb, $ids ) = @_;
	
	if ( !$self->ready ) {
		$cb->([ map {
			my $t = {
				title => 'Failed to get access token',
				duration => 1,
				uri => $_,
			};
			$cache->set($_, $t, 60);
			$t;
		} @$ids ]);
		return;
	}

	my $chunks = {};

	# build list of chunks we can query in one go
	while ( my @ids = splice @$ids, 0, SPOTIFY_LIMIT) {
		my $idList = join(',', map { s/(?:spotify|track)://g; $_ } grep { $_ && /^(?:spotify|track):/ } @ids) || next;
		$chunks->{md5_hex($idList)} = {
			market => 'from_token',
			ids => $idList
		};
	}

	Plugins::Spotty::API::Pipeline->new($self, 'tracks', sub {
		my ($tracks) = @_;
		
		my @tracks;
	
		foreach (@{$tracks->{tracks}}) {
			# track info for invalid IDs is returned
			next unless $_ && ref $_;

			my $track = $self->_normalize($_);
			
			push @tracks, $track if $self->_isPlayable($_);
		}
		
		return \@tracks;
	}, $cb, {
		chunks => $chunks,
	})->get();
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
	elsif ( $uri =~ /:album:/ ) {
		$self->album(sub {
			$cb2->(($_[0] || {})->{tracks});
		}, $params);
	}
	elsif ( $uri =~ m|:/*track:| ) {
		$cb->([ $uri ]);
	}
	else {
		$log->warn("No tracks found for URI $uri");
		$cb->([]);
	}
}

sub myAlbums {
	my ( $self, $cb ) = @_;
	
	Plugins::Spotty::API::Pipeline->new($self, 'me/albums', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $self->_normalize($_->{album}) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, sub {
		my $results = shift;
		
		my $items = [ sort { $a->{name} cmp $b->{name} } @{$results || []} ];
		$cb->($items);
	}, {
		limit => LIBRARY_LIMIT,
	})->get();
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
		
		for ( my $x = 0; $x < min((scalar @ids), (scalar @$tracks)) ; $x++ ) {
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
	my ( $self, $cb ) = @_;
	
	Plugins::Spotty::API::Pipeline->new($self, 'me/following', sub {
		if ( $_[0] && $_[0]->{artists} && $_[0]->{artists} && (my $artists = $_[0]->{artists}) ) {
			return [ map { $self->_normalize($_) } @{ $artists->{items} } ], $artists->{total}, $artists->{'next'};
		}
	}, sub {
		my $results = shift;
		
		# sometimes we get invalid list items back?!?
		my $items = [ grep { $_->{id} } @{$results || []} ];

		my %knownArtists = map {
			my $id = $_->{id};
			$id => 1
		} @$items;
		
		# Spotify does include artists from saved albums in their apps, but doesn't provide an API call to do this.
		# Let's do it the hard way: get the list of artists for which we have a stored album.
		$self->myAlbums(sub {
			my $albums = shift || [];
			
			foreach ( @$albums ) {
				next unless $_->{artists};
				
				if ( my $artist = $_->{artists}->[0] ) {
					if ( !$knownArtists{$artist->{id}}++ ) {
						push @$items, $self->_normalize($artist);
					}
				}
			}

			$cb->([ sort { $a->{name} cmp $b->{name} } @$items ]);
		})
	}, {
		type  => 'artist',
		limit => LIBRARY_LIMIT,
	})->get();
}

=pod
# XXX - unfortunately tracks played through LMS aren't part of this menu.
# Therefore it's rather confusing. Let's not use it.
sub recentlyPlayed {
	my ( $self, $cb, $args ) = @_;
	
	Plugins::Spotty::API::Pipeline->new($self, 'me/player/recently-played', sub {
		my $items = [];
		my %seen;
		
		foreach ( sort { $b->{played_at} cmp $a->{played_at} } @{ $_[0]->{items} || [] } ) {
			if (my $c = $_->{context}) {
				# don't return playlists or albums more than once
				next if $seen{$c->{uri}}++;
				
				if ($c->{type} eq 'playlist') {
					push @$items, {
						name => $c->{uri},
						uri => $c->{uri},
						type => 'playlist',
					}
				}
				elsif ( $c->{type} eq 'album' && $_->{track} && $_->{track}->{album} ) {
					push @$items, $self->_normalize($_->{track}->{album})
				}
				else {
					$log->error("Unexpected contex type found: " . $c->{type});
					main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($_));
				}
			}
			elsif ($_->{track}) {
				warn $_->{track}->{uri};
				next if $seen{$_->{track}->{uri}}++;
				push @$items, $self->_normalize($_->{track});
			}
		}
		
		return $items, $_[0]->{'next'} ? DEFAULT_LIMIT : 0, $_[0]->{'next'};
	}, $cb)->get();
} 
=cut

sub playlists {
	my ( $self, $cb, $args ) = @_;
	
	my $user = $args->{user} || $self->username || 'me';

	# usernames must be lower case, and space not URI encoded
	$user = lc($user);
	$user =~ s/ /\+/g;
	
	Plugins::Spotty::API::Pipeline->new($self, 'users/' . uri_escape_utf8($user) . '/playlists', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $self->_normalize($_) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, $cb, {
		limit  => $args->{limit} || DEFAULT_LIMIT
	})->get();
}

sub addTracksToPlaylist {
	my ( $self, $cb, $playlist, $trackIds ) = @_;

	if ( $playlist && $trackIds ) {
		$trackIds = join(',', @$trackIds) if ref $trackIds;

		my ($owner, $playlist) = $playlist =~ /^spotify:user:([^:]+):playlist:(.+)/;

		# usernames must be lower case, and space not URI encoded
		$owner = lc($owner);
		$owner =~ s/ /\+/g;
		
		$self->_call("users/$owner/playlists/$playlist/tracks?uris=$trackIds",
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
				$self->_normalize($_)
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
				image => _getLargestArtwork($_->{icons})
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

	# let's manipulate the timestamp so we only pull updated every few minutes
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
			my $items = [ map { $self->_normalize($_) } grep { $self->_isPlayable($_) } @{$result->{tracks}} ];
			
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

sub _normalize {
	my ( $self, $item ) = @_;
	
	my $type = $item->{type} || '';
	
	if ($type eq 'album') {
		$item->{image}   = _getLargestArtwork(delete $item->{images});
		$item->{artist}  ||= $item->{artists}->[0]->{name} if $item->{artists} && ref $item->{artists}; 
		
		$item->{tracks}  = [ map { $self->_normalize($_) } @{ $item->{tracks}->{items} } ] if $item->{tracks};
	}
	elsif ($type eq 'playlist') {
		$item->{creator} = $item->{owner}->{id} if $item->{owner} && ref $item->{owner};
		$item->{image}   = _getLargestArtwork(delete $item->{images});
	}
	elsif ($type eq 'artist') {
		$item->{sortname} = Slim::Utils::Text::ignoreArticles($item->{name});
		$item->{image} = _getLargestArtwork(delete $item->{images});
		
		if (!$item->{image}) {
			$item->{image} = $cache->get('spotify_artist_image_' . $item->{id});
		}
		else {
			$cache->set('spotify_artist_image_' . $item->{id}, $item->{image});
		}
	}
	# track
	else {
		$item->{album}  ||= {};
		$item->{album}->{image} ||= _getLargestArtwork(delete $item->{album}->{images}) if $item->{album}->{images};
		delete $item->{album}->{available_markets};
					
		# Cache all tracks for use in track_metadata
		$cache->set( $item->{uri}, $item, CACHE_TTL ) if $item->{uri};
		
		# sometimes we'd get metadata for an alternative track ID
		if ( $item->{linked_from} && $item->{linked_from}->{uri} ) {
			$cache->set( $item->{linked_from}->{uri}, $item, CACHE_TTL );
		}
	}

	delete $item->{available_markets};		# this is rather lengthy, repetitive and never used
	
	return $item;
}

sub _getLargestArtwork {
	my ( $images ) = @_;
	
	if ( $images && ref $images && ref $images eq 'ARRAY' ) {
		my ($image) = sort { $b->{height} <=> $a->{height} } @$images;
		
		return $image->{url} if $image;
	}
	
	return '';
}

sub _isPlayable {
	my ($self, $item, $cc) = @_;
	
	$cc ||= $self->country;

	# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
	return if defined $item->{is_playable} && !$item->{is_playable};
			
	return if $item->{available_markets} && !(scalar grep /$cc/i, @{$item->{available_markets}});
	
	return 1;
}

sub _call {
	my ( $self, $url, $cb, $type, $params ) = @_;
	
	$type ||= 'GET';
	
	# $uri must not have a leading slash
	$url =~ s/^\///;

	my $content;

	my @headers = ( 'Accept' => 'application/json', 'Accept-Encoding' => 'gzip' );
	
	my $token = $self->getToken();
	
	if ( !$token || $token =~ /^-(\d+)$/ ) {
		my $error = $1 || 1;
		$cb->({
			name => string('PLUGIN_SPOTTY_ERROR_' . $error),
			type => 'text' 
		});

		return;
	}

	if ( !$params->{_no_auth_header} ) {
		push @headers, 'Authorization' => 'Bearer ' . $token;
	}
	
	if ( my @keys = sort keys %{$params}) {
		my @params;
		foreach my $key ( @keys ) {
			next if $key =~ /^_/;
			push @params, $key . '=' . uri_escape_utf8( $params->{$key} );
		}

		if ( $type =~ /GET|PUT/ ) {
			$url .= '?' . join( '&', sort @params ) if scalar @params;
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
				$self->error429($response);
			}
			
			my $result;
			
			if ( $response->headers->content_type =~ /json/ ) {
				$result = decode_json(
					$response->content,
				);
				
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
						if ( !$ttl && $response->url =~ m|v1/users/([^\/]+?)/playlists/[A-Za-z0-9]{22}/tracks| ) {
							if ( $1 eq 'spotify' || $1 eq 'spotifycharts' ) {
								$ttl = 3600;
							}
							elsif ( $1 ne $self->username ) {
								$ttl = 300;
							}
						}
						
						$ttl ||= 60;		# XXX - we're going to always cache for a minute, as we often do follow up calls while navigating
						
						if ($ttl) {
							main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl using max-age (" . $response->url . ")");
							$cache->set($cache_key, $result, $ttl);
							main::INFOLOG && $log->is_info && $log->info("Data cached (" . $response->url . ")");
						}
					}
				}
			}
			elsif ( $type eq 'PUT' && $response->code =~ /^20\d/ ) {
				# ignore - v1/me/following doesn't return anything but 204 on success
				# ignore me/albums?ids=...
			}
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

			$log->warn("error: $error");

			if ($error =~ /429/ || ($response && $response->code == 429)) {
				$self->error429($response);

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
			cache => 1,
			expires => 3600,
			timeout => 30,
			no_revalidate => $params->{_no_revalidate},
		},
	);
	
	if ( $type eq 'POST' ) {
		$http->post($url, @headers, $content);
	}
	elsif ( $type eq 'PUT' ) {
		$http->put($url, @headers);
	}
	else {
		$http->get($url, @headers);
	}
}

# if we get a "rate limit exceeded" error, pause for the given delay
sub error429 {
	my ($self, $response) = @_;
	
	my $headers = $response->headers || {};

	# set special token to tell _call not to proceed
	$cache->set('spotty_rate_limit_exceeded', 1, $headers->{'retry-after'} || 5);

	$error429 = sprintf(string('PLUGIN_SPOTTY_ERROR_429_DESC'), $response->url, $headers->{'retry-after'} || 5);
	
	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug("Access rate exceeded: " . Data::Dump::dump($response));
	}
	else {
		$log->error($error429);
	}
	
}

sub hasError429 {
	return $error429;
}

1;
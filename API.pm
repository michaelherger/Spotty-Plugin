package Plugins::Spotty::API;

use strict;

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

use constant API_URL    => 'https://api.spotify.com/v1/%s';
use constant CACHE_TTL  => 86400 * 7;
use constant MAX_RECENT => 25;
use constant LIBRARY_LIMIT => 500;
use constant DEFAULT_LIMIT => 200;
use constant SPOTIFY_LIMIT => 50;

my $log = logger('plugin.spotty');
my $cache = Slim::Utils::Cache->new();
my $prefs = preferences('plugin.spotty');

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
		foreach ($self->client, undef) {
			my $cmd = sprintf('%s -n Squeezebox -c "%s" --client-id %s --get-token', 
				Plugins::Spotty::Plugin->getHelper(), 
				Plugins::Spotty::Plugin->cacheFolder($_),
				$prefs->get('ohmy')
			);
	
			my $response;
	
			eval {
				$response = `$cmd`;
				main::INFOLOG && $log->is_info && $log->info("Got response: $response");
				$response = decode_json($response);
			};
			
			$log->error("Failed to get Spotify access token: $@") if $@;
			
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
	my $credentials = Plugins::Spotty::Plugin->getCredentials();
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

sub search {
	my ( $self, $cb, $args ) = @_;
	
	return $cb->([]) unless $args->{query};
	
	my $type = $args->{type} || 'track';

	my $params = {
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
			my $album = $self->_normalize($_[0]);

			for my $track ( @{ $album->{tracks} || [] } ) {
				# Add missing album data to track
				$track->{album} = {
					name => $album->{name},
					image => $album->{image}, 
				};
				$track = $self->_normalize($track);
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
	my ( $self, $uri, $args ) = @_;
	
	return unless $uri =~ /^spotify:track/;
	
	my $cached = $cache->get($uri);
	
	# look up track information unless told not to do so
	if ( !$cached && !$args->{noLookup} ) {
		$self->track(undef, $uri);
	}
	
	return $cached;
}

sub tracks {
	my ( $self, $cb, $ids ) = @_;

	my @tracks;
	my $chunks = {};
	
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

	# build list of chunks we can query in one go
	while ( my @ids = splice @$ids, 0, SPOTIFY_LIMIT) {
		my $idList = join(',', map { s/(?:spotify|track)://g; $_ } grep { $_ && /^(?:spotify|track):/ } @ids) || next;
		$chunks->{md5_hex($idList)} = $idList;
	}

	# query all chunks in parallel, waiting for them all to return before we call the callback
	foreach my $idList (values %$chunks) {
		my $idHash = md5_hex($idList);
		
		$self->_call("tracks", 
			sub {
				my ($tracks) = @_;

				# only handle tracks which are playable
				my $cc = $self->country;
			
				foreach (@{$tracks->{tracks}}) {
					# track info for invalid IDs is returned
					next unless $_ && ref $_;
					
					# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
					next if defined $_->{is_playable} && !$_->{is_playable};
							
					next if $_->{available_markets} && !(scalar grep /$cc/i, @{$_->{available_markets}});
			
					push @tracks, $self->_normalize($_);
				}
				
				# delete the chunk information
				delete $chunks->{$idHash};
				
				# once we have no more chunks to process, call callback with the track list
				if ($cb && !scalar keys %$chunks) {
					$cb->(\@tracks);
				}
			}, 
			GET => {
				ids => $idList,
				market => 'from_token'
			}
		);
	}
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
	
	Plugins::Spotty::API::Pipeline->new($self, '/me/albums', sub {
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

sub myArtists {
	my ( $self, $cb ) = @_;
	
	Plugins::Spotty::API::Pipeline->new($self, '/me/following', sub {
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

sub _call {
	my ( $self, $method, $cb, $type, $params ) = @_;
	
	$type ||= 'GET';
	
	# $method must not have a leading slash
	$method =~ s/^\///;
	my $url  = sprintf(API_URL, $method);

	my $content;
	
	# only use from_token if we've got a token
#	if ( $params->{market} && $params->{market} eq 'from_token' ) {
#		if ( !(my $token = $self->getToken()) ) {
#			$params->{market} = $self->country;
#			$params->{_no_auth_header} = 1;
#		}
#	}

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
		$cache_key = md5_hex($url);
	}
		
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
				
				if ( !$result || $result->{error} ) {
					$result = {
						error => 'Error: ' . ($result->{error_message} || 'Unknown error')
					};
					$log->error($result->{error} . ' (' . $url . ')');
				}
				elsif ( $cache_key ) {
					if ( my $cache_control = $response->headers->header('Cache-Control') ) {
						my ($ttl) = $cache_control =~ /max-age=(\d+)/;
						$ttl ||= 60;		# XXX - we're going to always cache for a minute, as we often do follow up calls while navigating
						
						if ($ttl) {
							main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl using max-age (" . $response->url . ")");
							$cache->set($cache_key, $result, $ttl);
						}
					}
				}
			}
			else {
				$log->error("Invalid data");
				$result = { 
					error => 'Error: Invalid data',
				};
			}

			$cb->($result);
		},
		sub {
			my ($http, $error, $response) = @_;

			$log->warn("error: $error");

			if ($error =~ /429/ || $response->code == 429) {
				$self->error429($response);

				$cb->({ 
					name => string('PLUGIN_SPOTTY_ERROR_429'),
					type => 'text' 
				});
			}
			else {
				$cb->({ 
					name => 'Unknown error: ' . $error,
					type => 'text' 
				});
			}
		},
		{
#			params  => $params,
			cache => 1,
			timeout => 30,
		},
	);
	
	# XXXX
	if ( $type eq 'POST' ) {
		$http->post($url, @headers, $content);
	}
	# XXXX
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
	
	if ( main::DEBUGLOG && $log->is_debug ) {
		$log->debug("Access rate exceeded: " . Data::Dump::dump($response));
	}
	else {
		$log->warn("Access rate exceeded for: " . $response->url);
	}
}

1;
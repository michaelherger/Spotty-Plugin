package Plugins::Spotty::API;

use strict;

#use Encode;
use JSON::XS::VersionOneAndTwo;
use Digest::MD5 qw(md5_hex);
use List::Util qw(min);
use POSIX qw(strftime);
use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::API::Pipeline;

use Slim::Networking::SimpleAsyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(cstring);

use constant API_URL    => 'https://api.spotify.com/v1/%s';
use constant CACHE_TTL  => 86400 * 7;
use constant MAX_RECENT => 25;
use constant LIBRARY_LIMIT => 500;
use constant DEFAULT_LIMIT => 200;
use constant SPOTIFY_LIMIT => 50;

my $log = logger('plugin.spotty');
my $cache = Slim::Utils::Cache->new();
my ($username, $country, $locale);

sub init {
	my ($class) = @_;
	$class->me();
}

sub getToken {
	my ( $class, $force ) = @_;
	
	my $token = $cache->get('spotty_access_token') unless $force;
	
	if (main::DEBUGLOG && $log->is_debug) {
		if ($token) {
			$log->debug("Found cached token: $token");
		}
		else {
			$log->debug("Didn't find cached token. Need to refresh.");
		}
	}
	
	if ( $force || !$token ) {
		my $cmd = sprintf('%s -n Squeezebox -c "%s" -i 169b15c360bd4d8bae89b0d0499a9bfe --get-token', 
			Plugins::Spotty::Plugin->getHelper(), 
			Plugins::Spotty::Plugin->cacheFolder(),
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
				$cache->set('spotty_access_token', $token, ($response->{expiresIn} || 3600) - 600)
			}
		}
	}
	
	$log->error("Failed to get Spotify access token") unless $token;
	
	return $token;
}

sub me {
	my ( $class ) = @_;
	
	$class->_call('me',
		sub {
			my $result = shift;
			if ( $result && ref $result ) {
				$country = $result->{country} if $result->{country};
				$username => $result->{username} if $result->{username};
				return $result;
			}
		}
	);
}

# get the username - keep it simple. Shouldn't change, don't want nested async calls...
sub username {
	return $username if $username;
	
	my $credentials = Plugins::Spotty::Plugin->getCredentials();
	return $username ||= $credentials->{username};
}

# get the user's country - keep it simple. Shouldn't change, don't want nested async calls...
sub country {
	my $class = $_[0];

	$class->me() if (!$country);

	return $country || 'US';
}

sub locale {
	cstring($_[1], 'LOCALE');
}

sub search {
	my ( $class, $cb, $args ) = @_;
	
	return $cb->([]) unless $args->{query};
	
	my $type = $args->{type} || 'track';

	my $params = {
		q      => $args->{query},
		type   => $type,
		market => 'from_token',
		limit  => $args->{limit} || DEFAULT_LIMIT
	};
	
	if ( $type =~ /album|artist|track|playlist/ ) {
		Plugins::Spotty::API::Pipeline->new('search', sub {
			my $type = $type . 's';
			my $items = [];
			
			for my $item ( @{ $_[0]->{$type}->{items} } ) {
				$item = $class->_normalize($item);
	
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
	my ( $class, $cb, $args ) = @_;
	
	my ($id) = $args->{uri} =~ /album:(.*)/;
	
	$class->_call('albums/' . $id,
		sub {
			my $album = $class->_normalize($_[0]);

			for my $track ( @{ $album->{tracks} || [] } ) {
				# Add missing album data to track
				$track->{album} = {
					name => $album->{name},
					image => $album->{image}, 
				};
				$track = $class->_normalize($track);
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
	my ( $class, $cb, $args ) = @_;
	
	my ($id) = $args->{uri} =~ /artist:(.*)/;
	
	$class->_call('artists/' . $id,
		sub {
			my $artist = $class->_normalize($_[0]);
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
	my ( $class, $cb, $args ) = @_;
	
	my ($id) = $args->{uri} =~ /artist:(.*)/;
	
	$class->_call('artists/' . $id . '/top-tracks',
		sub {
			my $tracks = $_[0] || {};
			$cb->([ map { $class->_normalize($_) } @{$tracks->{tracks} || []} ]);
		},
		GET => {
			# Why the heck would this call need country rather than market?!? And no "from_token"?!?
			country => $class->country(),
		}
	);
}

sub artistAlbums {
	my ( $class, $cb, $args ) = @_;
	
	my ($id) = $args->{uri} =~ /artist:(.*)/;

	Plugins::Spotty::API::Pipeline->new('artists/' . $id . '/albums', sub {
		my $albums = $_[0] || {};
		my $items = [ map { $class->_normalize($_)} @{$albums->{items} || []} ];

		return $items, $albums->{total}, $albums->{'next'};
	}, $cb, {
		# "from_token" not allowed here?!?!
		market => $class->country,
		limit  => min($args->{limit} || DEFAULT_LIMIT, DEFAULT_LIMIT),
		offset => $args->{offset} || 0,
	})->get();
}

sub playlist {
	my ( $class, $cb, $args ) = @_;
	
	my ($user, $id) = $args->{uri} =~ /^spotify:user:([^:]+):playlist:(.+)/;
	
	Plugins::Spotty::API::Pipeline->new('users/' . $user . '/playlists/' . $id . '/tracks', sub {
		my $items = [];
		
		my $cc = $class->country;
		for my $item ( @{ $_[0]->{items} } ) {
			my $track = $item->{track} || next;
					
			# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
			next if defined $track->{is_playable} && !$track->{is_playable};
					
			next if $track->{available_markets} && !(scalar grep /$cc/i, @{$track->{available_markets}});

			push @$items, $class->_normalize($track);
		}
	
		return $items, $_[0]->{total}, $_[0]->{'next'};
	}, $cb, {
		market => 'from_token',
		limit  => $args->{limit} || DEFAULT_LIMIT
	})->get();
}

sub myAlbums {
	my ( $class, $cb ) = @_;
	
	Plugins::Spotty::API::Pipeline->new('/me/albums', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $class->_normalize($_->{album}) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
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
	my ( $class, $cb ) = @_;
	
	Plugins::Spotty::API::Pipeline->new('/me/following', sub {
		if ( $_[0] && $_[0]->{artists} && $_[0]->{artists} && (my $artists = $_[0]->{artists}) ) {
			return [ map { $class->_normalize($_) } @{ $artists->{items} } ], $artists->{total}, $artists->{'next'};
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
		$class->myAlbums(sub {
			my $albums = shift || [];
			
			foreach ( @$albums ) {
				next unless $_->{artists};
				
				if ( my $artist = $_->{artists}->[0] ) {
					if ( !$knownArtists{$artist->{id}}++ ) {
						push @$items, $class->_normalize($artist);
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
	my ( $class, $cb, $args ) = @_;
	
	my $user = $args->{user} || $class->username || 'me';

	# usernames must be lower case, and space not URI encoded
	$user = lc($user);
	$user =~ s/ /\+/g;
	
	Plugins::Spotty::API::Pipeline->new('users/' . uri_escape_utf8($user) . '/playlists', sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $class->_normalize($_) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, $cb, {
		limit  => $args->{limit} || DEFAULT_LIMIT
	})->get();
}

sub browse {
	my ( $class, $cb, $what, $key, $params ) = @_;
	
	return [] unless $what;
	
	$params ||= {};
	$params->{country} ||= $class->country;

 	my $message;

	Plugins::Spotty::API::Pipeline->new("browse/$what", sub {
		my $result = shift;
		
 		$message ||= $result->{message};
 		
 		if ($result && $result->{$key}) {
			my $cc = $class->country();
	
			my $items = [ map { 
				$class->_normalize($_)
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
	my ( $class, $cb ) = @_;
	$class->browse($cb, 'new-releases', 'albums');
}

sub categories {
	my ( $class, $cb ) = @_;
	
	$class->browse(sub {
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
		locale => $class->locale,
	});
}

sub categoryPlaylists {
	my ( $class, $cb, $category ) = @_;
	
	$class->browse($cb, 'categories/' . $category . '/playlists', 'playlists');
}

sub featuredPlaylists {
	my ( $class, $cb ) = @_;

	# let's manipulate the timestamp so we only pull updated every few minutes
	my $timestamp = strftime("%Y-%m-%dT%H:%M:00", localtime(time()));
	$timestamp =~ s/\d(:00)$/0$1/;
	
	my $params = { 
		locale => $class->locale,
		timestamp => $timestamp
	};
	
	$class->browse($cb, 'featured-playlists', 'playlists', $params);
}

sub _normalize {
	my ( $class, $item ) = @_;
	
	my $type = $item->{type} || '';
	
	if ($type eq 'album') {
		$item->{image}   = _getLargestArtwork(delete $item->{images});
		$item->{artist}  ||= $item->{artists}->[0]->{name} if $item->{artists} && ref $item->{artists}; 
		
		$item->{tracks}  = [ map { $class->_normalize($_) } @{ $item->{tracks}->{items} } ] if $item->{tracks};
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
	my ( $class, $method, $cb, $type, $params ) = @_;
	
	$type ||= 'GET';
	
	# $method must not have a leading slash
	$method =~ s/^\///;
	my $url  = sprintf(API_URL, $method);

	my $content;
	
	# only use from_token if we've got a token
#	if ( $params->{market} && $params->{market} eq 'from_token' ) {
#		if ( !(my $token = $class->getToken()) ) {
#			$params->{market} = $class->country;
#			$params->{_no_auth_header} = 1;
#		}
#	}

	my @headers = ( 'Accept' => 'application/json', 'Accept-Encoding' => 'gzip' );

	if ( !$params->{_no_auth_header} && (my $token = $class->getToken()) ) {
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
	
	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $params   = $response->params('params');
			
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
							main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl using max-age");
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
			warn Data::Dump::dump(@_);
			$log->warn("error: $_[1]");
			$cb->({ 
				name => 'Unknown error: ' . $_[1],
				type => 'text' 
			});
		},
		{
#			params  => $params,
			timeout => 30,
		},
	);
	
	# XXXX
	if ( $type eq 'POST' ) {
		$http->post($url, @headers, $content);
	}
	# XXXX
	elsif ( $type eq 'PUT' ) {
		$http->_createHTTPRequest( POST => $url );
	}
	else {
		$http->get($url, @headers);
	}
}


1;
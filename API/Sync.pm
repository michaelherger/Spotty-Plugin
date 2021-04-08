package Plugins::Spotty::API::Sync;

use strict;

use base qw(Slim::Utils::Accessor);

use Digest::MD5 qw(md5_hex);
use IO::Socket::SSL;
use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Networking::SimpleSyncHTTP;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Spotty::API::Cache;

{
	__PACKAGE__->mk_accessor( rw => qw(
		username
		userid
	) );
}

use constant SPOTIFY_LIMIT => 50;
use constant SPOTIFY_ALBUMS_LIMIT => 20;
use constant SPOTIFY_PLAYLIST_TRACKS_LIMIT => 100;
use constant SPOTIFY_MAX_LIMIT => 10_000;

my $log = logger('plugin.spotty');
my $cache = Slim::Utils::Cache->new();
my $libraryCache = Plugins::Spotty::API::Cache->new();
my $prefs = preferences('plugin.spotty');

# our old LWP::UserAgent doesn't support ssl_opts yet
IO::Socket::SSL::set_defaults(
	SSL_verify_mode => 0
);

use constant API_URL => 'https://api.spotify.com/v1/%s';

sub new {
	my ($class, $accountId) = @_;

	$accountId ||= Plugins::Spotty::AccountHelper->getSomeAccount();

	my $self = $class->SUPER::new();
	$self->userid($accountId);

	return $self;
}

sub getToken {
	my ($self) = @_;

	if ($cache->get('spotty_rate_limit_exceeded')) {
		return -429;
	}

	return Plugins::Spotty::API::Token->get(undef, undef, { accountId => $self->userid });
}

sub myAlbums {
	my ($self, $args) = @_;
	$args ||= {};

	my $offset = 0;
	my $albums = [];
	my $libraryMeta;

	do {
		$args->{offset} = $offset;

		my $response = $self->_call('me/albums', $args);

		$offset = 0;

		if ( $response && $response->{items} && ref $response->{items} ) {
			# keep track of some meta-information about the albums
			$libraryMeta ||= {
				total => $response->{total} || 0,
				lastAdded => $response->{items}->[0]->{added_at} || ''
			};

			($offset) = $response->{'next'} =~ /offset=(\d+)/;
			push @$albums, map {
				my $totalTracks = $_->{album}->{total_tracks};
				if ($totalTracks > SPOTIFY_LIMIT) {
					my $trackOffset = scalar @{$_->{album}->{tracks}->{items}} || 0;

					while ($trackOffset < $totalTracks) {
						my $tracksResponse = $self->_call('albums/' . $_->{album}->{id} . '/tracks', {
							offset => $trackOffset,
							limit => SPOTIFY_LIMIT
						});

						if ( $tracksResponse && $tracksResponse->{items} && ref $tracksResponse->{items} && ref $tracksResponse->{items} eq 'ARRAY' ) {
							push @{$_->{album}->{tracks}->{items}}, @{$tracksResponse->{items}};
						}

						$trackOffset += SPOTIFY_LIMIT;
					}
				}

				$_->{album}->{added_at} = $_->{added_at} if $_->{added_at};
				$libraryCache->normalize($_->{album});
			} @{ $response->{items} };
		}
	} while $offset;

	return wantarray ? ($albums, $libraryMeta) : $albums;
}

# sub _albumTracks {
# 	my ($self, $id, $offset) = @_;

# 	my $response = $self->_call("albums/$id/tracks", {
# 		offset => $offset || 0,
# 		limit => SPOTIFY_LIMIT
# 	});

# 	my $tracks = [];
# 	if ( $response && $response->{items} && ref $response->{items} ) {
# 		push @$tracks, @{ $response->{items} };
# 	}

# 	return $tracks;
# }

sub myArtists {
	my ($self, $args) = @_;
	$args ||= {};

	my $offset = '';
	my $artists = [];
	my $libraryMeta;
	$args->{type} = 'artist';

	do {
		$args->{after} = $offset if $offset;

		my $response = $self->_call('me/following', $args);

		$response = $response && ref $response && $response->{artists};

		$offset = '';

		if ( $response && $response->{items} && ref $response->{items} ) {
			# keep track of some meta-information about the artists
			$libraryMeta ||= {
				total => $response->{total} || 0,
			};

			$offset = $response->{'cursors'}->{'after'};
			push @$artists, map {
				$libraryCache->normalize($_);
			} @{ $response->{items} };
		}
	} while $offset;

	if (wantarray) {
		$libraryMeta->{hash} = md5_hex(join('|', sort map { $_->{id} } @$artists));
		return ($artists, $libraryMeta);
	}

	return $artists;
}

sub mySongs {
	my ($self) = @_;

	my $offset = 0;
	my $tracks = [];

	do {
		my $response = $self->_call('me/tracks', {
			offset => $offset
		});

		$offset = 0;

		if ( $response && $response->{items} && ref $response->{items} ) {
			push @$tracks, map { $libraryCache->normalize($_->{track}) } @{ $response->{items} };
			($offset) = $response->{'next'} =~ /offset=(\d+)/;
		}
	} while $offset;

	return $tracks;
}

sub myPlaylists {
	my ($self) = @_;

	my $offset = 0;
	my $playlists = [];

	do {
		my $response = $self->_call('me/playlists', {
			offset => $offset
		});

		$offset = 0;

		if ( $response && $response->{items} && ref $response->{items} ) {
			push @$playlists, map { $libraryCache->normalize($_) } @{$response->{items}};
			($offset) = $response->{'next'} =~ /offset=(\d+)/;
		}
	} while $offset;

	return $playlists;
}

sub tracks {
	my ($self, $ids) = @_;

	my $tracks;
	$ids = [ sort map { s/^spotify:(episode|track)://; $_ } @$ids ];
	while (my @ids = splice(@$ids, 0, SPOTIFY_LIMIT)) {
		my $response = $self->_call('tracks', {
			ids => join(',', @ids),
			limit => SPOTIFY_LIMIT
		});

		if ( $response && $response->{tracks} && ref $response->{tracks} ) {
			push @$tracks, map { $libraryCache->normalize($_) } grep { $_->{uri} =~ /^spotify:(episode|track):/ } @{ $response->{tracks} };
		}
	}

	return $tracks;
}

sub albums {
	my ($self, $ids) = @_;

	my $albums;
	$ids = [ sort map { s/^spotify:album://; $_ } @$ids ];
	while (my @ids = splice(@$ids, 0, SPOTIFY_ALBUMS_LIMIT)) {
		my $response = $self->_call('albums', {
			ids => join(',', @ids),
			limit => SPOTIFY_ALBUMS_LIMIT
		});

		if ( $response && $response->{albums} && ref $response->{albums} ) {
			push @$albums, map { $libraryCache->normalize($_) } @{ $response->{albums} };
		}
	}

	return $albums;
}

sub artist {
	my ($self, $id) = @_;

	$id =~ s/spotify:artist://;

	my $response = $self->_call('artists/' . $id);

	return $libraryCache->normalize($response) if $response && ref $response;
}

# attempt at creating the cheapest/fastest call to get the track IDs/URIs only
sub playlistTrackIDs {
	my ($self, $id, $getFullData) = @_;

	my $offset = 0;
	my $tracks;

	do {
		my $params = {
			market => 'from_token',
			offset => $offset,
			limit => SPOTIFY_PLAYLIST_TRACKS_LIMIT,
		};

		$params->{fields} = 'next,items(track(uri,restrictions))' if !$getFullData;

		my $response = $self->_call("playlists/$id/tracks", $params);

		$offset = 0;

		if ( $response && $response->{items} && ref $response->{items} ) {
			push @$tracks, map {
				$libraryCache->normalize($_->{track}) if $getFullData;
				$_->{track}->{uri};
			} grep {
				$_->{track} && ref $_->{track} && $_->{track}->{uri} && $_->{track}->{uri} =~ /^spotify:(episode|track):/ && !$_->{track}->{restrictions}
			} @{$response->{items}};
			($offset) = $response->{'next'} =~ /offset=(\d+)/;
		}
	} while $offset && $offset < SPOTIFY_MAX_LIMIT;

	return $tracks;
}

sub _call {
	my ( $self, $url, $params ) = @_;

	$params ||= {};
	$params->{limit} ||= SPOTIFY_LIMIT;

	my $token = $self->getToken();

	if ( !$token || $token =~ /^-(\d+)$/ ) {
		my $error = $1 || 'NO_ACCESS_TOKEN';
		$error = 'NO_ACCESS_TOKEN' if $error !~ /429/;

		return {
			error => $error,
		};
	}

	# $uri must not have a leading slash
	$url =~ s/^\///;

	my $content;

	my @headers = (
		'Accept' => 'application/json',
		'Authorization' => 'Bearer ' . $token
	);

	if ( my @keys = sort keys %{$params}) {
		my @params;
		foreach my $key ( @keys ) {
			next if $key =~ /^_/;
			push @params, $key . '=' . uri_escape_utf8( $params->{$key} );
		}

		$url .= '?' . join( '&', sort @params ) if scalar @params;
	}

	my $cached;
	my $cache_key = md5_hex($url . ($url =~ /^me\b/ ? $token : ''));

	main::INFOLOG && $log->is_info && $cache_key && $log->info("Trying to read from cache for $url");

	if ( $cached = $cache->get($cache_key) ) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached data for $url");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		return $cached;
	}
	elsif ( main::INFOLOG && $log->is_info ) {
		$log->info("API call: $url");
	}

	my $response = Slim::Networking::SimpleSyncHTTP->new()->get(
		sprintf(API_URL, $url),
		@headers
	);

	# try again in x seconds
	if ($response->code =~ /429/) {
		my $retryAfter = ($response->headers->{'retry-after'} || 5) + 1;
		main::INFOLOG && $log->is_info && $log->info("Got rate limited - try again in $retryAfter seconds...");
		sleep $retryAfter;

		$response = Slim::Networking::SimpleSyncHTTP->new()->get(
			sprintf(API_URL, $url),
			@headers
		);
	}

	if ($response->code =~ /429/) {
		my $retryAfter = ($response->headers->{'retry-after'} || 5) + 1;
		$log->warn("Got rate limited - waiting $retryAfter seconds before continuing...");
		sleep $retryAfter;

		return {
			error => 429
		};
	}

	my $result;

	eval {
		$result = decode_json(
			$response->content,
		);
	};

	if ($@) {
		my $error = "Failed to parse JSON response from $url: $@";
		$log->error($error);
		main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
		return {
			error => $error
		};
	}

	main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

	if ( !$result || (ref $result && ref $result eq 'HASH' && $result->{error}) ) {
		$result = {
			error => 'Error: ' . ($result->{error_message} || 'Unknown error')
		};
		$log->error($result->{error} . ' (' . $url . ')');
	}
	else {
		if ( my $cache_control = $response->headers->header('Cache-Control') ) {
			my ($ttl) = $cache_control =~ /max-age=(\d+)/;

			$ttl ||= 60;		# we're going to always cache for a minute, as we often do follow up calls while navigating

			if ($ttl) {
				main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl using max-age (" . $url . ")");
				$cache->set($cache_key, $result, $ttl);
				main::INFOLOG && $log->is_info && $log->info("Data cached (" . $url . ")");
			}
		}
	}

	return $result;
}

1;
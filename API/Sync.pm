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

	my $self = $class->SUPER::new();
	$self->userid($accountId);

	return $self;
}

sub getToken {
	my ($self) = @_;

	if ($cache->get('spotty_rate_limit_exceeded')) {
		return -429;
	}

	my $userId = $self->userid || '_scanner';
	my $token = $cache->get('spotty_access_token' . $userId);

	if (main::INFOLOG && $log->is_info) {
		if ($token) {
			$log->info("Found cached token: $token");
		}
		else {
			$log->info("Didn't find cached token. Need to refresh.");
		}
	}

	return $token || Plugins::Spotty::API::Token->get(undef, undef, $userId);
}

sub myAlbums {
	my ($self) = @_;

	my $offset = 0;
	my $albums = [];

	do {
		my $response = $self->_call('me/albums', {
			offset => $offset
		});

		$offset = 0;

		if ( $response && $response->{items} && ref $response->{items} ) {
			($offset) = $response->{'next'} =~ /offset=(\d+)/;
			push @$albums, map { $libraryCache->normalize($_->{album}) } @{ $response->{items} };
		}
	} while $offset;

	return $albums;
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
	$ids = [ sort map { s/^spotify:track://; $_ } @$ids ];
	while (my @ids = splice(@$ids, 0, SPOTIFY_LIMIT)) {
		my $response = $self->_call('tracks', {
			ids => join(',', @ids),
			limit => SPOTIFY_LIMIT
		});

		if ( $response && $response->{tracks} && ref $response->{tracks} ) {
			push @$tracks, map { $libraryCache->normalize($_) } grep { $_->{uri} =~ /^spotify:track:/ } @{ $response->{tracks} };
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

# attempt at creating the cheapest/fastest call to get the track IDs/URIs only
sub playlistTrackIDs {
	my ($self, $id) = @_;

	my $offset = 0;
	my $tracks;

	do {
		my $response = $self->_call("playlists/$id/tracks", {
			offset => $offset,
			limit => SPOTIFY_PLAYLIST_TRACKS_LIMIT,
			fields => 'next,items(track(uri))'
		});

		$offset = 0;

		if ( $response && $response->{items} && ref $response->{items} ) {
			push @$tracks, map { $_->{track}->{uri} } grep { $_->{track} && ref $_->{track} && $_->{track}->{uri} && $_->{track}->{uri} =~ /^spotify:track:/ } @{$response->{items}};
			($offset) = $response->{'next'} =~ /offset=(\d+)/;
		}
	} while $offset;

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

	if ($response->code =~ /429/) {
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
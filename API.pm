package Plugins::Spotty::API;

# Spotify API deprecations:
# https://developer.spotify.com/blog/2026-02-06-update-on-developer-access-and-platform-security
# https://developer.spotify.com/documentation/web-api/references/changes/february-2026

use strict;
use Exporter::Lite;

BEGIN {
	use constant API_URL => 'https://api.spotify.com/v1/%s';
	use constant TOKEN_URL => 'https://accounts.spotify.com/api/token';
	use constant LIBRARY_LIMIT => 500;
	use constant RECOMMENDATION_LIMIT => 100;		# for whatever reason this call does support a maximum chunk size of 100
	use constant DEFAULT_LIMIT => 200;
	use constant MAX_LIMIT => 10_000;
	use constant SPOTIFY_LIMIT => 50;
	use constant PERSONAL_MIX_CATEGORY => '0JQ5DAt0tbjZptfcdMSKl3';   # https://community.spotify.com/t5/Spotify-for-Developers/How-can-I-get-access-to-Made-for-You-playlist-by-Web-API/m-p/5905136/highlight/true#M12816

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

# `@KNOWN_DEPRECATED_FAMILIES` is the canonical pattern-key derivation list for the URL-pattern
# hint cache. The hint cache is NOT pre-warmed at init — these regexes are used only to derive
# a stable pattern KEY when a 403/410 leads to a bundled-fallback success at runtime, so similar
# URLs hit the cached hint on subsequent calls. First call after server restart pays the 2x cost
# (own attempt → 403/410 → bundled retry); subsequent calls within 24h hit bundled directly.
# The `me/*` family is NOT here — `me/*` MUST stay on own flavor.
my @KNOWN_DEPRECATED_FAMILIES = (
	qr{^browse/featured-playlists\b},
	qr{^browse/categories/[^/?]+/playlists\b},
	qr{^browse/categories\b},
	qr{^browse/new-releases\b},
	qr{^recommendations\b},
	qr{^users/[^/?]+/playlists\b},
	qr{^artists/[^/?]+/top-tracks\b},
	qr{^artists/[^/?]+/related-artists\b},
	# SPOTTY-NG (Phase 2.6 plan-02 / HARDEN-03 / closes 02-REVIEW.md CR-03) — Spotify-curated
	# playlists (Mix der Woche, Release Radar, Discover Weekly, Daily Mix, "Made For You",
	# Genre/Mood charts) consistently use the `37i9` ID prefix as the editorial-content
	# subnamespace (stable since ~2016, with sub-prefixes like `37i9dQZ` for personalised
	# mixes). User-owned playlist IDs are random base62 — the narrowed regex matches ONLY
	# the curated `37i9` subnamespace, so a deleted user playlist 404 STAYS ON OWN FLAVOR
	# and surfaces the 404 to the caller as before (per the invariant documented at the
	# comment block in the _call body, line ~1383). Collision probability between random
	# base62 and the `37i9` prefix is ~1 in 14.7M; even on collision the user-owned
	# playlist returns 200 under own with no harm done. The broader `37i9` prefix (rather
	# than the narrower `37i9dQZ`) is intentional — it covers all curated subnamespaces
	# including future sub-prefixes Spotify might introduce while keeping `37i9` stable.
	# Per D2.6-10: if Spotify changes the curated prefix scheme, fail gracefully — bundled
	# retries simply won't fire on the new scheme until the regex is updated. No proactive
	# detection logic.
	qr{^playlists/37i9[A-Za-z0-9]+\b},
);

# 24h TTL — long enough to avoid burning the 2x cost on every Start-menu browse,
# short enough to self-heal if Spotify reverses a deprecation.
use constant SPOTTY_NG_BUNDLED_HINT_TTL => 86400;
use constant SPOTTY_NG_BUNDLED_HINT_KEY_PREFIX => 'spotty_ng_bundled_hint_';

# Sentinel cache flag for "this user needs bundled-default OAuth".
# 7d TTL = long enough to span an evening-after-morning gap, short enough that any flag we
# miss-clearing self-heals within a week. Authoritative source is the render-time probe in
# Settings.pm; this flag is belt-and-suspenders, not load-bearing.
use constant SPOTTY_NG_NEEDS_BUNDLED_AUTH_TTL        => 7 * 24 * 3600;
use constant SPOTTY_NG_NEEDS_BUNDLED_AUTH_KEY_PREFIX => 'spotty_ng_needs_bundled_auth_';

# me/* family guard for the routing decision.
# Matches v1/me, v1/me/*, v1/me?... — i.e. the userId-scoped endpoint family that MUST
# stay on own flavor (Liked Songs, Saved Albums, etc.). Tested AT THE TOP of _call's
# routing decision so a transient 403 on me/tracks (e.g. Spotify glitch) cannot fall
# back to bundled and silently return wrong data.
my $_spottyNgMeFamilyRegex = qr{^me(?:$|/|\?)};
{
	__PACKAGE__->mk_accessor( rw => qw(
		client
		cache
		_userId
		_country
		_canPodcast
	) );
}

sub new {
	my ($class, $args) = @_;

	if (Slim::Networking::SimpleHTTP::Base->can('shouldNotRevalidate')) {
		require Plugins::Spotty::API::AsyncRequest;
	}
	else {
		require Plugins::Spotty::API::AsyncRequestLegacy;
	}

	my $self = $class->SUPER::new();

	$self->client($args->{client});
	$self->cache($args->{cache});
	$self->_userId($args->{userId});

	$self->_country($prefs->get('country'));

	# update our profile ASAP
	$self->me() unless $args->{noProfileUpdate};

	return $self;
}

sub getToken {
	my ( $self, $cb, $args ) = @_;

	if ($cache->get('spotty_rate_limit_exceeded')) {
		return $cb->(-429) ;
	}

	Plugins::Spotty::API::Token->get($self, $cb, $args);
}

sub codeExchange {
	my ( $self, $cb, $args ) = @_;

	# SPOTTY-NG (Phase 2.5 follow-up / closes GAP-02.5-VFY-01) — propagate the
	# caller's `_client_id` override into the params handed to _tokenCall, so the
	# flavor-correct Client ID lands on Spotify's /api/token endpoint at
	# code-exchange time. Mirrors the existing refreshToken fix below (Phase 2-07
	# follow-up commit 7e233a6). Without this, a bundled-flavor authorization_code
	# (minted at /authorize under the bundled-default Client ID via oauthRedirect)
	# gets exchanged with the user's own Dev ID — Spotify rejects with 400 Bad
	# Request because /api/token requires the same client_id at code exchange as
	# was used at /authorize. Discovered during Phase 2.5 Probe 5 (HUMAN-UAT).
	$self->_tokenCall($cb, {
		grant_type => 'authorization_code',
		code => $args->{code},
		redirect_uri => $args->{callbackUrl},
		code_verifier => $args->{codeVerifier},
		_client_id => $args->{_client_id},
	}, $cb);
}

sub refreshToken {
	my ( $self, $cb, $args ) = @_;

	# SPOTTY-NG (Phase 2, plan 05 follow-up / FIX-11 / D-07) — propagate the caller's
	# `_client_id` override into the params handed to _tokenCall so the flavor-correct
	# Client ID lands on Spotify's /api/token endpoint. Without this, bundled-flavor
	# refresh tokens (minted under the bundled-default Client ID) get sent with the
	# user's own Dev ID, and Spotify replies 400 Bad Request — the bundled-fallback
	# silently fails and OPML.pm:204 sets $customClientLimitations++ on the empty
	# featuredPlaylists() result. Discovered during plan-07 validation.
	$self->_tokenCall($cb, {
		grant_type => 'refresh_token',
		refresh_token => $args->{refreshToken},
		_client_id => $args->{_client_id},
	}, $cb);
}

sub me {
	my ( $self, $cb, $token ) = @_;

	$self->_call('me',
		sub {
			my $result = shift;
			if ( $result && ref $result ) {
				$self->country($result->{country});
				$self->_userId($result->{id}) if $result->{id};
				Plugins::Spotty::AccountHelper->setName($self->userId, $result);
				Plugins::Spotty::AccountHelper->setProduct($self->userId, $result);

				$cb->($result) if $cb;
			}
		},'',{
			_token => $token,
		}
	);
}

sub home {
	my ($self, $cb) = @_;

	$self->categoryPlaylists($cb, PERSONAL_MIX_CATEGORY );
}

# get the userId - keep it simple. Shouldn't change, don't want nested async calls...
sub userId {
	my ($self, $userId) = @_;

	$self->_userId($userId) if $userId;
	return $self->_userId if $self->_userId;

	# fall back to default account if no userId was given
	my $credentials = Plugins::Spotty::AccountHelper->getCredentials($self->client);
	if ( $credentials && ref $credentials && $credentials->{username} ) {
		$self->_userId($credentials->{username})
	}

	return $self->_userId;
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

# XXX SPOTIFY DEPRECATION
sub user {
	my ( $self, $cb, $userId ) = @_;

	if (!$userId) {
		$cb->({});
		return;
	}

	# usernames must be lower case, and space not URI encoded
	$userId = lc($userId);
	$userId =~ s/ /\+/g;

	$self->_call('users/' . uri_escape_utf8($userId),
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

	if ( $type =~ /album|artist|track|playlist|show|episode/ ) {
		Plugins::Spotty::API::Pipeline->new($self, 'search', sub {
			my $type = $type . 's';

			my $items = [];

			for my $item ( @{ $_[0]->{$type}->{items} } ) {
				# sometimes we'd get empty list items...
				next unless $item && $self->_isPlayable($item);

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
						push @$items, $libraryCache->normalize($track) if $self->_isPlayable($track);
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

			$album->{tracks} = [ grep {
				$_ && $self->_isPlayable($_)
			} @{$album->{tracks} || []} ];

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

# XXX SPOTIFY DEPRECATION ???
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

# XXX SPOTIFY DEPRECATION
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
	$limit ||= lc($user) eq lc($self->userId) ? max(LIBRARY_LIMIT, _DEFAULT_LIMIT()) : _DEFAULT_LIMIT();

	Plugins::Spotty::API::Pipeline->new($self, 'playlists/' . $id . '/tracks', sub {
		my $items = [];

		my $rawItems = $_[0]->{items};
		if ($prefs->get('sortPlaylisttracksByAddition')) {
			$rawItems = [ sort {
				$b->{added_at} cmp $a->{added_at}
			} @$rawItems ];
		}

		my $cc = $self->country;
		for my $item ( @$rawItems ) {
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

sub _tracks {
	my ($self, $cb, undef, $type ) = @_;

	$type ||= 'track';

	my $chunks = {};

	my $ids = [ sort @{Storable::dclone($_[2])} ];

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

	$self->tracksFromURI($cb2, $uri);
}

sub tracksFromURI {
	my ( $self, $cb, $uri ) = @_;

	my $params = {
		uri => $uri
	};

	if ($uri =~ /:playlist:.*:recommended/) {
		main::INFOLOG && $log->is_info && $log->info("Not looking up playlist, as it's the :recommended continuation");
		$cb->([]);
	}
	elsif ($uri =~ /:playlist:/) {
		$self->playlist($cb, $params);
	}
	elsif ( $uri =~ /:artist:/ ) {
		$self->artistTracks($cb, $params);
	}
	elsif ( $uri =~ /:show:/ ) {
		$self->show(sub {
			$cb->(($_[0] || {})->{episodes});
		}, $params);
	}
	elsif ( $uri =~ /:album:/ ) {
		$self->album(sub {
			$cb->(($_[0] || {})->{tracks});
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
		my $items = shift;

		$items = [ sort {
			Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name})
		} @{$items || []} ] if $prefs->get('sortSongsAlphabetically');

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
		my $items = shift;

		$items = [ sort {
			Slim::Utils::Text::ignoreCaseArticles($a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{name})
		} @{$items || []} ] if $prefs->get('sortAlbumsAlphabetically');

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
	my $cacheKey = 'spotify_my_artists' . Slim::Utils::Unicode::utf8toLatin1Transliterate($self->userId || '');

	if ( my $cached = $cache->get($cacheKey) ) {
		$cb->($cached);
		return;
	}

# XXX - SPOTIFY DEPRECATION ???
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

			$items = [ sort _artistSort @$items ] if $prefs->get('sortArtistsAlphabetically');

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

sub episodes {
	my ( $self, $cb, $args ) = @_;

	my ($id) = $args->{id};

	Plugins::Spotty::API::Pipeline->new($self, "shows/$id/episodes", sub {
		if ( $_[0] && $_[0]->{items} && ref $_[0]->{items} ) {
			return [ map { $libraryCache->normalize($_) } @{ $_[0]->{items} } ], $_[0]->{total}, $_[0]->{'next'};
		}
	}, $cb, {
		market => 'from_token',
		limit  => min($args->{limit} || _DEFAULT_LIMIT(), _DEFAULT_LIMIT()),
		offset => $args->{offset} || 0,
	})->get();
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

# XXX SPOTIFY DEPRECATION
sub playlists {
	my ( $self, $cb, $args ) = @_;

	my $user = $args->{user} || $self->userId || 'me';

	my $limit = $args->{limit};
	# set the limit higher if it's the user's self curated playlist
	$limit ||= lc($user) eq lc($self->userId) ? max(LIBRARY_LIMIT, _DEFAULT_LIMIT()) : _DEFAULT_LIMIT();

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

# XXX SPOTIFY DEPRECATION
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

	my $params = {
		locale => $self->locale,
		timestamp => _getTimestamp(),
	};

	$self->browse($cb, 'featured-playlists', 'playlists', $params);
}

# XXX SPOTIFY DEPRECATION ???
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
	Slim::Utils::Text::ignoreCaseArticles($a->{sortname} || $a->{name}) cmp Slim::Utils::Text::ignoreCaseArticles($b->{sortname} || $b->{name});
}

sub _isPlayable {
	my ($self, $item, $cc) = @_;

	return unless $item && ref $item;

	$cc ||= $self->country;

	# if we set market => 'from_token', then we don't get available_markets back, but only a is_playable flag
	# podcast episodes in playlists a flagged with is_playable=false and episode=false despite being perfectly playable...
	return if defined $item->{is_playable} && !$item->{is_playable} && !(defined $item->{episode} && !$item->{episode} && $item->{uri} =~ /^spotify:episode:/);
	return if $item->{is_local};

	return if $item->{available_markets} && scalar @{$item->{available_markets}} && !(scalar grep /$cc/i, @{$item->{available_markets}});

	return 1;
}

sub _getTimestamp {
	# let's manipulate the timestamp so we only pull updates every few minutes
	my $timestamp = strftime("%Y-%m-%dT%H:%M:00", localtime(time()));
	$timestamp =~ s/\d(:00)$/0$1/;
	return $timestamp;
}

# SPOTTY-NG (Phase 2, plan 05 / D-05 / FIX-09) — single-shot HTTP dispatch helper.
# Extracted from the body of _call's inner $call closure (Phase-1 shape) so the
# try-own-then-fallback retry path can re-dispatch with a different flavor without
# recursing back into _call (which would re-trigger the hint-cache lookup, response
# cache check, Pipeline correlation, etc. — Pitfall #2 in 02-RESEARCH.md).
#
# Caller contract:
# - $token: the bearer string already obtained for the chosen flavor
# - $self, $url, $cb, $type, $params: same as _call
# - $params->{_spottyNgFlavor}: flavor in use ('own' | 'bundled') for log/REQ correlation
sub _callOneShot {
	my ($self, $token, $url, $cb, $type, $params) = @_;

	# SPOTTY-NG (Phase 3, plan 01 / POLISH-03 / closes 02.6-REVIEW.md WR-03) — restructure
	# the `$1` capture so it's only read inside the branch where the regex actually
	# matched. Pre-fix code used `if (!$token || $token =~ /^-(\d+)$/) { my $error = $1 || ... }`
	# which relies on Perl's dynamic-scope `$1` carrying whatever the previous regex match
	# in the same scope last captured when the LHS short-circuit fired (i.e. when $token was
	# empty/undef, the regex on the RHS never ran). Practically safe today (no other regex
	# in _callOneShot's frame), but a future refactor adding any regex match earlier would
	# silently change the value of $1. Make the capture intent explicit.
	my $error;
	if (!$token) {
		$error = 'NO_ACCESS_TOKEN';
	}
	elsif ($token =~ /^-(\d+)$/) {
		$error = $1;
		$error = 'NO_ACCESS_TOKEN' if $error !~ /429/;
	}
	if ($error) {
		$cb->({
			name => string('PLUGIN_SPOTTY_ERROR_' . $error),
			type => 'text'
		});
		return;
	}

	$type ||= 'GET';
	$url =~ s/^\///;

	my ($content, $headers);
	($url, $content, $headers) = _prepareCall($type, $url, $params);
	push @$headers, 'Authorization' => 'Bearer ' . $token;

	my $cached;
	my $cache_key;
	if (!$params->{_nocache} && $type eq 'GET') {
		# SPOTTY-NG (Phase 3, plan 01 / POLISH-11 / closes 02-REVIEW.md IN-01 / promoted from
		# .planning/todos/pending/HARDEN-DEFER-IN-01.md) — strip the bearer from the cache key
		# for `browse/*` URLs. Pre-fix code keyed `me|browse` URLs by token, which under the
		# Phase 2 try-own-then-fallback dispatch caused browse responses to be cached TWICE
		# (once under the own-flavor bearer's MD5, once under the bundled-flavor bearer's MD5).
		# Browse responses are functionally identical across flavor (only the routing differs);
		# `me/*` continues to scope by token (different users see different Liked Songs).
		# Post-fix: bundled and own browse responses share a single cache row.
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

	# SPOTTY-NG instrumentation (Phase 1, plan 03) — REQ-side log emission (D-08, D-16).
	# Gated on DEBUG of plugin.spotty so default WARN produces zero output (D-14).
	my $_spottyNgPipe   = $params->{_pipeline};
	my $_spottyNgPipeId = (ref $_spottyNgPipe && $_spottyNgPipe->can('_pipeId')) ? $_spottyNgPipe->_pipeId : '--------';
	my $_spottyNgPerPipeInflight = (ref $_spottyNgPipe && $_spottyNgPipe->can('_inflight')) ? $_spottyNgPipe->_inflight : 0;
	my $_spottyNgIssuedAt = int(Time::HiRes::time() * 1000);    # ms-resolution

	Plugins::Spotty::API::_spottyNgIncGlobalInflight();

	if ( main::DEBUGLOG && $log->is_debug ) {
		my $_ts = strftime('%Y-%m-%dT%H:%M:%S', localtime) . sprintf('.%03dZ', $_spottyNgIssuedAt % 1000);
		my $_method = uc($type || 'GET');
		my $_fullUrl = sprintf(API_URL, $url);
		my $_hdrs = _spottyNgFormatHeaders($headers);
		my $_flavor = $params->{_spottyNgFlavor} || 'own';
		# SPOTTY-NG (Phase 2, plan 05 / D-15 / FIX-14) — drop the `+ 1` over-count; Pipeline._inflight
		# is already incremented by plan-05 wiring upstream of this emit, so the as-of-emission value
		# IS the right one to render.
		# SPOTTY-NG (Phase 2, plan 05 / D-05) — append flavor=<own|bundled> field for log readability;
		# this is in addition to (not replacing) the AUTH redaction that _spottyNgFormatHeaders does.
		$log->debug(sprintf('[%s] [SPOTTY-NG pipe=%s inflight=%d/%d flavor=%s] REQ %s %s hdrs=%s',
			$_ts, $_spottyNgPipeId, $_spottyNgPerPipeInflight, $_spottyNgGlobalInflight,
			$_flavor, $_method, $_fullUrl, $_hdrs));
	}

	my $http = Plugins::Spotty::API::AsyncRequest->new(
		\&_gotResponse,
		\&_gotError,
		{
			cache => $params->{_nocache} ? 0 : 1,
			expires => $params->{_expires} || 3600,
			timeout => 30,
			no_revalidate => $params->{_no_revalidate},
			self => $self,
			cb => $cb,
			cache_key => $cache_key,
			# SPOTTY-NG (Phase 1, plan 03) — for response-side log correlation (plan 04).
			_spottyNgIssuedAt => $_spottyNgIssuedAt,
			_spottyNgPipeId   => $_spottyNgPipeId,
			_spottyNgPipe     => $_spottyNgPipe,
		},
	);

	if ( $type eq 'POST' ) {
		$http->post(sprintf(API_URL, $url), @$headers, $content);
	}
	elsif ( $type eq 'PUT' ) {
		$http->put(sprintf(API_URL, $url), @$headers, $content);
	}
	else {
		$http->get(sprintf(API_URL, $url), @$headers);
	}
}

sub _call {
	my ( $self, $url, $cb, $type, $params ) = @_;

	$params ||= {};

	# SPOTTY-NG (Phase 3, plan 01 / POLISH-01 / closes 02.6-REVIEW.md WR-01) — `_call`
	# cooldown gate: blocks ALL `_call` entries during cooldown, including the
	# `_token`-injected literal-token bypass below and `me/*` calls (which previously
	# could reuse a cached access token without going through token resolution). This
	# is BROADER than the pre-Phase-2 `getToken`-only gate — intentional, for
	# conservative 429 backoff: every observed 429 from Spotify is a clear signal
	# from the server that we should stop sending traffic for the Retry-After window,
	# even traffic that would technically reuse pre-cached state. The flag setter in
	# `error429` / `_gotResponse` is unchanged from Phase 2.
	#
	# Originally landed in Phase 2.6 (HARDEN-01 / closes 02-REVIEW.md CR-01); the prior
	# comment described this gate as "restoring the pre-Phase-2 reactive 429 contract"
	# which understated the scope (pre-Phase-2 cooldown only fired during AT/RT
	# resolve, not during cached-AT reuse). See 02.6-REVIEW.md WR-01 for the rationale
	# of widening the documentation to match the implementation.
	#
	# Per D2.6-04: gate is placed at the head of _call (before any flavor decision);
	# per D2.6-05: ordering — gate fires before hint-cache lookup so we don't waste a
	# `$cache->get` on a known-rate-limited account.
	#
	# `_callOneShot` already recognises a leading-`-(\d+)` $token as a sentinel (see
	# its own body, line ~1232-1242) and converts `-429` to the user-facing
	# PLUGIN_SPOTTY_ERROR_429 reply via `string()` lookup — same path that `tracks()`
	# (the only existing `getToken` caller post-Phase-2) takes when it sees the same
	# `-429` value out of `getToken`. Routing the cooldown response through
	# `_callOneShot` here keeps the user-facing error symmetrical with the pre-Phase-2
	# behavior without re-implementing the lookup.
	if ($cache->get('spotty_rate_limit_exceeded')) {
		return _callOneShot($self, '-429', $url, $cb, $type, $params);
	}


	# If the caller injected a literal token (extremely rare path), preserve today's
	# behavior and bypass the routing — they're explicitly asking to use *that* token.
	if ($params->{_token}) {
		return _callOneShot($self, $params->{_token}, $url, $cb, $type, $params);
	}

	# SPOTTY-NG (Phase 2, plan 05 / D-05 / D-06 / FIX-09 / FIX-10 / FIX-13) — try-own-then-fallback dispatch.
	# Strip leading slash so URL matches the @KNOWN_DEPRECATED_FAMILIES regex anchors.
	my $cleanUrl = $url;
	$cleanUrl =~ s/^\///;

	# Step 0: me/* family guard. me/* MUST stay on own — Pitfall #1 in 02-RESEARCH.md.
	# If the URL is in the me/* family, dispatch under own flavor and SKIP the retry path.
	my $isMeFamily = ($cleanUrl =~ $_spottyNgMeFamilyRegex);

	# Step 1: hint-cache lookup — for non-me URLs only. If the URL pattern was
	# learned in a previous bundled-fallback success, dispatch directly to bundled.
	my $hintFlavor = $isMeFamily ? undef : _spottyNgLookupBundledHint($cleanUrl);
	my $startFlavor = $hintFlavor || 'own';

	# SPOTTY-NG (Phase 3 follow-up / Case-A UAT 2026-05-09 regression close) —
	# Standard-User-mode dispatch bypass. When the user has NOT configured their
	# own Spotify Developer App (`iconCode == initIcon()`), no own-flavor refresh
	# token is ever cached: HARDEN-13's cache-write side at
	# Settings/Callback.pm:331-333 lands OAuth output under flavor=bundled in this
	# mode. Without this override, $startFlavor='own' here causes
	# Token::get(flavor=>'own') to hard-fail at API/Token.pm:275-279, the user
	# callback is invoked with undef, me/* and featuredPlaylists return empty, and
	# OPML.pm:204 increments customClientLimitations (hides "Start"). Mirroring the
	# write-side predicate (iconCode == initIcon → flavor=bundled) here restores
	# upstream-equivalent behavior for default-bundled installs without affecting
	# the Power-User flow (hasDefaultIcon() returns 0 when own iconCode is set).
	# Placed AFTER the me-family guard and the hint-cache lookup so me/* calls in
	# Standard-User mode also dispatch directly under bundled (the only flavor
	# with a cached RT in this mode).
	if (Plugins::Spotty::Plugin->hasDefaultIcon()) {
		$startFlavor = 'bundled';
	}

	# Closure-wrapped retry: invoke once with $startFlavor; on 403/410 from the
	# own-flavor result (and ONLY 403/410), re-issue under bundled flavor. Always
	# call user $cb exactly once via the $userCbCalled guard.
	my ($callOnce, $userCb);
	my $userCbCalled = 0;
	$userCb = sub {
		return if $userCbCalled++;
		$cb->(@_);
	};

	$callOnce = sub {
		my ($flavor, $isRetry) = @_;
		$isRetry //= 0;

		# Build a per-attempt $params copy that carries the flavor marker for the
		# REQ-emit log line. Shallow copy preserves _pipeline ref (gotcha #6).
		my $attemptParams = { %$params, _spottyNgFlavor => $flavor };

		# Build the inner $cb that intercepts 403/410 and decides to retry or surface.
		my $interceptCb = sub {
			my ($result, $response) = @_;
			my $code = $response ? eval { $response->code } : undef;
			$code //= '';

			# If we just dispatched under own flavor and got 403/410/404, AND the URL is
			# NOT me/* (defense-in-depth — already gated above but cheap to re-assert),
			# AND we haven't already retried, attempt the bundled fallback.
			#
			# SPOTTY-NG (Phase 2 plan-07 follow-up): empirically, post-Feb-2026 Spotify
			# returns 404 (not 403/410) on the dev-mode-deprecated browse/* endpoints —
			# discovered when browse/featured-playlists started consistently returning
			# `RES 404 body=<error: 404 Not Found>` under own Dev ID. To avoid false
			# positives on legitimate "resource not found" responses, 404 only triggers
			# the fallback when the URL matches @KNOWN_DEPRECATED_FAMILIES.
			#
			# SPOTTY-NG (Phase 2.6 plan-02 / HARDEN-03): the playlists/{id} entry was
			# narrowed to the `37i9` Spotify-curated subnamespace prefix (Mix der Woche,
			# Release Radar, Discover Weekly, Daily Mix, etc. — including sub-prefixes
			# like `37i9dQZ`). See the regex comment in @KNOWN_DEPRECATED_FAMILIES at
			# the top of this file. A user-owned playlist 404 (e.g. a deleted playlist)
			# NO LONGER triggers a bundled retry, eliminating the contradiction the
			# comment had with the pre-2.6 broad regex.
			# SPOTTY-NG (Phase 3, plan 01 / POLISH-05 / closes 02.6-REVIEW.md IN-02) —
			# capture the matched regex object so the success-path `_spottyNgRememberBundledHint`
			# call below doesn't re-walk @KNOWN_DEPRECATED_FAMILIES. Cosmetic; impact is
			# microscopic (the inner `for` loop iterates 3-9 entries on an HTTP-retry path).
			my $is404Deprecated = 0;
			my $matchedRx;
			if ($code eq '404' && !$isMeFamily) {
				for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
					if ($cleanUrl =~ $rx) { $is404Deprecated = 1; $matchedRx = $rx; last; }
				}
			}
			if (!$isRetry && $flavor eq 'own' && !$isMeFamily
					&& ($code eq '403' || $code eq '410' || $is404Deprecated)) {
				# D-09: probe BEFORE attempting bundled retry. If bundled refresh token
				# is missing, surface the original 403/410 to the caller and log a
				# structured sentinel — DO NOT trigger inline OAuth (Phase 2.5 owns that).
				if (!Plugins::Spotty::API::Token->hasRefreshToken($self, flavor=>'bundled')) {
					$log->error(sprintf(
						'[SPOTTY-NG] bundled-fallback unavailable: no refresh token under flavor=bundled for user=%s url=%s',
						($self->userId // '<unknown>'), $cleanUrl));
					# SPOTTY-NG (Phase 2.5 / D-2.5-02(1)) — flag this user as needing bundled-default OAuth
					# so the next Settings render surfaces an "Authorize browsing" link in the credentials table.
					_spottyNgRememberNeedsBundledAuth($self->userId) if $self->userId;
					return $userCb->($result, $response);
				}

				main::INFOLOG && $log->is_info &&
					$log->info(sprintf('[SPOTTY-NG] retrying under bundled flavor: status=%s url=%s', $code, $cleanUrl));

				# SPOTTY-NG (Phase 2.6, plan 02 / HARDEN-02 / closes 02-REVIEW.md CR-02) — wrap the
				# bundled-attempt $cb so we cache the URL pattern hint ONLY when the bundled retry
				# actually succeeds (HTTP 2xx). Pre-fix code wrote the hint unconditionally before
				# the retry ran, which violated D-06's self-healing TTL semantic ("when a 403/410 →
				# bundled-fallback succeeds, cache the URL pattern hint for 24h"): a transient
				# bundled-side failure (revoked RT, 5xx, network blip) would lock the URL pattern
				# in cache for 24h and route subsequent calls to a known-broken bundled path.
				#
				# $userCb is still invoked exactly once via the $userCbCalled guard at the top of
				# this closure; $bundledCb is just an interceptor on the way to $userCb.
				my $bundledCb = sub {
					my ($bundledResult, $bundledResponse) = @_;
					my $bundledCode = $bundledResponse ? eval { $bundledResponse->code } : undef;
					if (defined $bundledCode && $bundledCode =~ /^2\d\d$/) {
						# Bundled retry succeeded — cache the URL pattern hint so subsequent calls
						# skip own-attempt and go straight to bundled. POLISH-05: pass the already-
						# matched regex (captured in the $is404Deprecated iteration above) so the
						# helper can skip its own iteration. $matchedRx may be undef on the
						# 403/410 path (the iteration is gated on $code eq '404'); the helper
						# falls back to its own iteration when $matchedRx is undef.
						_spottyNgRememberBundledHint($cleanUrl, $matchedRx);
					}
					$userCb->($bundledResult, $bundledResponse);
				};

				# Retry under bundled flavor. Issue a fresh getToken call to fetch the
				# bundled-flavor bearer; do NOT recurse into _call (Pitfall #2).
				Plugins::Spotty::API::Token->get($self, sub {
					my ($bundledToken) = @_;
					return _callOneShot($self, $bundledToken, $url, $bundledCb, $type,
					                    { %$attemptParams, _spottyNgFlavor => 'bundled' });
				}, { flavor => 'bundled' });
				return;
			}

			# Not a 403/410 retry-trigger (or we already retried, or me/*). Surface.
			$userCb->($result, $response);
		};

		# Fetch the flavor-correct bearer and dispatch.
		Plugins::Spotty::API::Token->get($self, sub {
			my ($token) = @_;
			return _callOneShot($self, $token, $url, $interceptCb, $type, $attemptParams);
		}, { flavor => $flavor });
	};

	$callOnce->($startFlavor, 0);
}

sub _tokenCall {
	my ( $self, $cb, $params ) = @_;

	# SPOTTY-NG (Phase 2, plan 05 / D-07 / FIX-11) — honor caller-injected _client_id for
	# flavor-aware OAuth refresh. Token.pm (plan 04) passes `_client_id => <bundled-icon>`
	# when refreshing under flavor='bundled'; absent override, today's behavior is preserved.
	$params->{client_id} = delete $params->{_client_id} || $prefs->get('iconCode');
	my ($url, $content, $headers) = _prepareCall('POST', '', $params);

	push @$headers, 'Content-Type' => 'application/x-www-form-urlencoded';

	main::INFOLOG && $log->is_info && $log->info("Auth Token API call: " . $params->{grant_type});
	main::DEBUGLOG && $content && $log->is_debug && logSensitive($content);

	my $req = Plugins::Spotty::API::AsyncRequest->new(
		\&_gotResponse,
		\&_gotError,
		{
			cache => 0,
			timeout => 30,
			self => $self,
			cb => $cb,
		},
	);

	$req->post(TOKEN_URL, @$headers, $content);
}

# URL-pattern hint cache lookup.
# Returns 'bundled' if (a) the URL matches one of the known-deprecated families AND
# (b) we've previously seen a successful 403/410 → bundled-fallback for that family
# within SPOTTY_NG_BUNDLED_HINT_TTL seconds. Otherwise returns undef (caller proceeds
# to the own-flavor first attempt). Tested AFTER the me/* guard, NEVER for me/* URLs.
sub _spottyNgLookupBundledHint {
	my ($url) = @_;
	return undef unless defined $url && length $url;

	for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
		if ($url =~ $rx) {
			my $patternKey = "$rx";   # stringify the qr{} for use in cache key
			return 'bundled' if $cache->get(SPOTTY_NG_BUNDLED_HINT_KEY_PREFIX . $patternKey);
			return undef;     # known family but not yet learned at runtime
		}
	}
	return undef;
}

# URL-pattern hint cache write.
# Called after a 403/410/404 → bundled-fallback succeeds. Caches the matching pattern
# key for SPOTTY_NG_BUNDLED_HINT_TTL seconds (24h) so subsequent matching URLs hit
# bundled directly. If the URL doesn't match any known family, log a warn line.
#
# SPOTTY-NG (Phase 3, plan 01 / POLISH-05 / closes 02.6-REVIEW.md IN-02) — accepts an optional
# pre-matched regex object from the caller's closure scope. When provided, the iteration over
# @KNOWN_DEPRECATED_FAMILIES is skipped; the helper writes the hint key derived from $matchedRx
# directly. When undef (e.g. the caller didn't capture it, like the 403/410 trigger path), the
# helper falls back to its own iteration. Backward-compatible — the 1-arg call shape still works.
sub _spottyNgRememberBundledHint {
	my ($url, $matchedRx) = @_;
	return unless defined $url && length $url;

	# Fast path: caller already matched a regex; trust it and skip the iteration.
	if (defined $matchedRx) {
		my $patternKey = "$matchedRx";
		$cache->set(SPOTTY_NG_BUNDLED_HINT_KEY_PREFIX . $patternKey,
		            1, SPOTTY_NG_BUNDLED_HINT_TTL);
		main::INFOLOG && $log->is_info &&
			$log->info(sprintf('[SPOTTY-NG] cached bundled-hint pattern=%s ttl=%ds (matched url=%s, fast-path)',
				$patternKey, SPOTTY_NG_BUNDLED_HINT_TTL, $url));
		return;
	}

	# Slow path: caller didn't pre-match; iterate ourselves.
	for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
		if ($url =~ $rx) {
			my $patternKey = "$rx";
			$cache->set(SPOTTY_NG_BUNDLED_HINT_KEY_PREFIX . $patternKey,
			            1, SPOTTY_NG_BUNDLED_HINT_TTL);
			main::INFOLOG && $log->is_info &&
				$log->info(sprintf('cached bundled-hint pattern=%s ttl=%ds (matched url=%s)',
					$patternKey, SPOTTY_NG_BUNDLED_HINT_TTL, $url));
			return;
		}
	}
	$log->warn(sprintf('bundled-fallback succeeded for url=%s — no matching pattern; hint NOT cached. Either the bundled retry was triggered by a non-deprecation 403/410 (e.g. permission), or Spotify deprecated a new endpoint family — review regex list.', $url));
}

# Flag a user as needing bundled-default OAuth. Called when bundled retry would have been
# attempted but no bundled refresh token is cached, and after own-flavor OAuth completes
# but bundled RT is still absent. Best-effort signal — the render-time probe in Settings.pm
# is authoritative. Self-clears on successful bundled-OAuth via $cache->remove.
sub _spottyNgRememberNeedsBundledAuth {
	my ($userId) = @_;
	return unless defined $userId && length $userId;
	my $key = SPOTTY_NG_NEEDS_BUNDLED_AUTH_KEY_PREFIX . $userId;
	$cache->set($key, 1, SPOTTY_NG_NEEDS_BUNDLED_AUTH_TTL);
	main::INFOLOG && $log->is_info &&
		$log->info(sprintf('flagged user=%s as needing bundled-default OAuth (ttl=%ds)',
			$userId, SPOTTY_NG_NEEDS_BUNDLED_AUTH_TTL));
}

# Flush all bundled-hint cache entries. Called at OAuth completion so any successful
# re-OAuth (own or bundled) invalidates routing decisions made under the previous identity.
# Slim::Utils::Cache does NOT expose a prefix-iterate method; we iterate
# @KNOWN_DEPRECATED_FAMILIES (same list the writer uses) to derive keys — guaranteeing
# no orphaned hint rows. Best-effort: remove() returns undef on missing key without throwing.
sub _spottyNgFlushBundledHints {
	my $removed = 0;
	for my $rx (@KNOWN_DEPRECATED_FAMILIES) {
		my $patternKey = "$rx";
		my $cacheKey = SPOTTY_NG_BUNDLED_HINT_KEY_PREFIX . $patternKey;
		if (defined $cache->get($cacheKey)) {
			$cache->remove($cacheKey);
			$removed++;
		}
	}
	main::INFOLOG && $log->is_info &&
		$log->info(sprintf('flushed %d bundled-hint cache row(s) (called from OAuth completion)', $removed));
	return $removed;
}


sub _prepareCall {
	my ($type, $url, $params) = @_;

	my $content;

	my @headers = ( 'Accept' => 'application/json', 'Accept-Encoding' => 'gzip' );

	if ( my @keys = sort keys %{$params}) {
		my @params;
		foreach my $key ( @keys ) {
			if ($key eq '_headers') {
				push @headers, @{$params->{$key}};
			}

			next if $key =~ /^_/;
			my $value = uri_escape_utf8($params->{$key});
			$value =~ s/~/%7E/g;  # uri_escape_utf8 doesn't escape ~
			push @params, $key . '=' . $value;
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

	if ( $type eq 'PUT' || $type eq 'POST' ) {
		push @headers, 'Content-Length' => length($content || '');
	}

	return ($url, $content, \@headers);
}

sub _gotResponse {
	my $response = shift;
	my $url      = $response->url;
	my $params   = $response->params();

	my $cb       = $params->{cb};
	my $self     = $params->{self};
	my $cache_key= $params->{cache_key};

	if ($response->code =~ /429/) {
		$self->error429($response, $url);
	}
	else {
		$error429 = '';
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
				if ( !$ttl && $url =~ m|/playlists/([A-Za-z0-9]{22})/tracks| ) {
					my ($user) = $self->getPlaylistUserAndId("spotify:playlist:$1");
					$user ||= '';

					if ( $user eq 'spotify' || $user eq 'spotifycharts' ) {
						$ttl = _PLAYLIST_CACHE_TTL();
					}
					elsif ( $user ne $self->userId ) {
						$ttl = 3600;
					}
				}
				# call to /me is super popular, and content changes rarely - cache for a while
				elsif ( !$ttl && $url =~ m|/me$| ) {
					$ttl = 60 * 60;
				}

				$ttl ||= 60;		# we're going to always cache for a minute, as we often do follow up calls while navigating

				if ($ttl) {
					main::INFOLOG && $log->is_info && $log->info("Caching result for $ttl (" . $url . ")");
					$cache->set($cache_key, $result, $ttl);
				}
			}
		}
	}
	elsif ( $response->type =~ /PUT|POST/ && $response->code =~ /^20\d/ ) {
		# ignore - v1/me/following doesn't return anything but 204 on success
		# ignore me/albums?ids=...
	}
	else {
		$log->error("Invalid data: " . ($response->code || ''));
		main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
		$result = {
			error => 'Error: Invalid data',
		};
	}

	$cb->($result, $response);
}

sub _gotError {
	my ($http, $error, $response) = @_;

	my $url    = $http->url;
	my $cb     = $http->params('cb');
	my $self   = $http->params('self');

	# log call if it hasn't been logged already
	if (!$log->is_info) {
		$log->warn("API call: $url");
		$http->contentRef && $log->warn(${ $http->contentRef });
	}

	$log->error("error: $error ($url)");

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

sub logSensitive {
	if (main::INFOLOG && $log->is_info) {
		my ($line) = @_;
		$line =~ s/--client-id ["a-f0-9]+/--client-id ***/;
		$line =~ s/(client_id=)[a-f0-9]+/$1=***/;
		$line =~ s/(access[-_]token|refresh[-_]token)=[-_\w]+/$1=***/g;
		$log->info("Trying to get access token: $line");
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

sub _PLAYLIST_CACHE_TTL {
	Plugins::Spotty::Plugin->hasDefaultIcon() ? 8*3600 : 3600;
}

1;

__DATA__
3635623730383037336663303438306561393261303737323333636138376264
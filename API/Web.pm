package Plugins::Spotty::API::Web;

use strict;

use JSON::XS::VersionOneAndTwo;
use List::Util qw(shuffle);
use URI;
use URI::Escape qw(uri_escape_utf8 uri_unescape);
use URI::QueryParam;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

require Plugins::Spotty::AccountHelper;
require Plugins::Spotty::API::Cache;
require Plugins::Spotty::API::Token;

use constant API_URL => 'https://api.spotify.com/v1/%s';
use constant PLAYLIST_TREE_URL => 'https://spclient.wg.spotify.com/playlist/v2/user/%s/rootlist';
use constant IMAGE_MOSAIC_URL => 'https://mosaic.scdn.co/640/%s%s%s%s';

my $libraryCache = Plugins::Spotty::API::Cache->new();

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

sub getToken {
	my ($class, $api, $cb) = @_;

	Plugins::Spotty::API::Token->get($api, sub {
		my $webToken = shift;

		if ($webToken) {
			$cb->($webToken);
		}
		else {
			$class->_getTokenFromWebCookie($api, $cb);
		}
	},{
		code => _code(),
		scope => 'playlist-read'
	});
}

sub _getTokenFromWebCookie {
	my ($class, $api, $cb) = @_;

	my $webToken = Plugins::Spotty::AccountHelper->getWebToken($api->client);
	my $username = $api->username || 'generic';

	main::INFOLOG && $log->is_info && $log->info("Getting web token for $username: " . Slim::Utils::DbCache::_key('spotty_access_token_web' . $username));

	my $cacheKey = 'spotty_access_token_web' . $webToken;

	if (my $cached = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Found cached web access token for $username");
		main::DEBUGLOG && $log->is_debug && $log->debug($cached);
		$cb->($cached);
		return;
	}

	my $cookieJar = Slim::Networking::Async::HTTP::cookie_jar();
	$cookieJar->set_cookie(0, 'sp_dc', $webToken || '', '/', 'open.spotify.com');
	$cookieJar->set_cookie(0, 'sp_dc', $webToken || '', '/', '.spotify.com');
	$cookieJar->save();

	$class->_call('https://open.spotify.com/get_access_token', sub {
		my $response = shift || {};

		if ($response && ref $response && $response->{accessToken}) {
			$cache->set($cacheKey, $response->{accessToken}, 1800);
			main::INFOLOG && $log->is_info && $log->info("Received web access token for $username");
			main::DEBUGLOG && $log->is_debug && $log->debug($response->{accessToken});
			$cb->($response->{accessToken});
		}
		else {
			$log->warn("Failed to get web token for $username");
			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response)) if $response;
			$cb->();
		}
	},{
		reason => 'transport',
		productType => 'web_player',
	});
}

sub home {
	my ( $class, $api, $cb ) = @_;

	my $username = $api->username || 'generic';
	my $cacheKey = "spotty_webhome_$username";

	if (my $cached = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info(sprintf('Returning cached Home menu structure for %s (%s)', $username, Slim::Utils::DbCache::_key($cacheKey)));
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	$class->_call(sprintf(API_URL, 'views/desktop-home'), sub {
		my ($result) = @_;

		my $items = [ map {
			my $item = {
				name  => $_->{name},
				tag_line => $_->{tag_line},
				id    => $_->{id},
				href  => $_->{content}->{href},
			};

			# try to get four images to create a mosaic
			my %seen;
			my @imageIds = grep { $_ && !$seen{$_}++ } map {
				my $url = $_->{images}->[0]->{url};
				$url =~ m|/([a-f0-9]{40})(?:/.*?)?$|;
				$1;
			} grep {
				$_->{images} && (ref $_->{images} || '') eq 'ARRAY'
			} @{$_->{content}->{items}};

			if (@imageIds >= 4) {
				$item->{image} = sprintf(IMAGE_MOSAIC_URL, shuffle @imageIds);
			}

			$item;
		} grep {
			$_->{name} && $_->{content} && $_->{content}->{items} && (ref $_->{content}->{items} || '') eq 'ARRAY' && scalar @{$_->{content}->{items}}
		} @{$result->{content}->{items}} ];

		$cache->set($cacheKey, $items, 900);

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($items));
		$cb->($items);
	},{
		content_limit => 20,
		locale => $api->locale,
		# platform => 'web',
		country => $api->country,
		timestamp => $api->_getTimestamp(),
		types => 'album,playlist,artist,show,station',
		limit => 20,
		# offset => 0,
		_api => $api,
	});
}

sub getPlaylistHierarchy {
	my ( $class, $api, $cb ) = @_;

	my $username = $api->username || 'generic';
	my $cacheKey = "spotty_playlisttree_$username";

	if (my $cached = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached playlist menu structure for $username");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	$class->_call(sprintf(PLAYLIST_TREE_URL, $username), sub {
		my ($data) = @_;

		my $map;

		if ($data && ref $data && $data->{contents} && ref $data->{contents} && $data->{contents}->{items} && ref $data->{contents}->{items}) {
			$map = {};
			my $i = 0;

			my @stack = ();
			my $parent = '/';

			foreach my $playlistItem (@{$data->{contents}->{items}}) {
				if (my ($name) = $playlistItem->{uri} =~ /^spotify:start-group:(.*)/) {
					my @tags = split ':', $playlistItem->{uri};
					my $name = uri_unescape($tags[-1]);
					$name =~ s/\+/ /g;
					$name = Slim::Utils::Unicode::utf8decode($name);

					main::INFOLOG && $log->is_info && $log->info("Start Group $name : $parent ($i)");

					$map->{$tags[-2]} = {
						name => $name,
						order => $i++,
						isFolder => 1,
						parent => $parent
					};

					push @stack, $parent;
					$parent = $tags[-2];
					main::INFOLOG && $log->is_info && $log->info("Start Group Push : $parent ($i)");
				}
				elsif ($playlistItem->{uri} =~ /^spotify:end-group/) {
					$parent = pop @stack;
					main::INFOLOG && $log->is_info && $log->info("End Group : $parent ($i)");
				}
				else {
					$map->{$playlistItem->{uri}} = {
						order => $i++,
						parent => $parent
					};
				}
			}
		}

		$cache->set($cacheKey, $map, 3600);

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($map));
		$cb->($map);
	},{
		market => "from_token",
		_api => $api,
	});
}

sub browseWebUrl {
	my ( $class, $api, $cb, $url ) = @_;

	my $uri   = URI->new($url);
	my $query = $uri->query_form_hash;

	my $username = $api->username || 'generic';
	my $cacheKey = "spotty_$username" . $uri->as_string;

	if (my $cached = $cache->get($cacheKey)) {
		main::INFOLOG && $log->is_info && $log->info("Returning cached playlist menu structure for $username");
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	$query->{limit} = Plugins::Spotty::API::SPOTIFY_LIMIT;
	$query->{timestamp} = $api->_getTimestamp();
	$query->{_api} = $api;

	$url =~ s/\?.*//;

	$class->_call($url, sub {
		my ($result) = @_;

		my $items = [ map {
			my $type = $_->{type};
			$libraryCache->normalize($_);
			$_->{type} = $type;
			$_;
		} @{$result->{content}->{items}} ];

		$cache->set($cacheKey, $items, 3600);

		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($items));
		$cb->($items);
	}, $query);
}

my $_CODE;
sub _code { $_CODE ||= pack "H*",<Plugins::Spotty::API::DATA> }

sub _call {
	my ($class, $url, $cb, $params) = @_;

	my @headers = ( 'Accept' => 'application/json', 'Accept-Encoding' => 'gzip' );

	if ( my @keys = sort keys %{$params}) {
		my @params;
		foreach my $cacheKey ( sort @keys ) {
			if ($cacheKey eq '_headers') {
				push @headers, @{$params->{$cacheKey}};
			}

			next if $cacheKey =~ /^_/;
			push @params, $cacheKey . '=' . uri_escape_utf8( $params->{$cacheKey} );
		}

		$url .= '?' . join( '&', sort @params ) if scalar @params;
	}

	my $http = Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;

			if ( $response->headers->content_type =~ /json/i ) {
				my $result = eval { decode_json($response->content) };

				$log->error("Failed to parse JSON response from $url: $@") if $@;

				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

				$cb->($result);
			}
			else {
				$log->warn("Failed to get web page");

				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
				$cb->();
			}
		},
		sub {
			my ($http, $error, $response) = @_;

			# log call if it hasn't been logged already
			if (!$log->is_info) {
				$log->warn("API call: $url");
			}

			$log->warn("error: $error");

			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
			$cb->({
				error => 'Unexpected error: ' . $error,
			});
		}
	);

	if ($url =~ /get_access_token/) {
		main::INFOLOG && $log->is_info && $log->info("Get Web Token call: $url");
		# warn Data::Dump::dump(\@headers);
		$http->get($url, @headers);
	}
	else {
		$class->getToken($params->{_api}, sub {
			my $token = shift;
			push @headers, 'Authorization' => 'Bearer ' . $token;

			main::INFOLOG && $log->is_info && $log->info("Web API call: $url");
			# warn Data::Dump::dump(\@headers);

			$http->get($url, @headers);
		});
	}
}

1;
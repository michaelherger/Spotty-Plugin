package Plugins::Spotty::API::Web;

use strict;

use JSON::XS::VersionOneAndTwo;
use URI::Escape qw(uri_escape_utf8);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

require Plugins::Spotty::AccountHelper;
require Plugins::Spotty::API::Cache;

use constant API_URL => 'https://api.spotify.com/v1/%s';

my $libraryCache = Plugins::Spotty::API::Cache->new();

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

sub getToken {
	my ($class, $cb, $user) = @_;

	$user ||= 'generic';

	main::INFOLOG && $log->is_info && $log->info("Getting web token for $user: " . Slim::Utils::DbCache::_key('spotty_access_token_web' . $user));

	if (my $cached = $cache->get('spotty_access_token_web' . $user)) {
		main::INFOLOG && $log->is_info && $log->info("Found cached web access token for $user: $cached");
		$cb->($cached);
		return;
	}

	my $webTokens = $prefs->get('webTokens') || {};

	my $cookieJar = Slim::Networking::Async::HTTP::cookie_jar();
	$cookieJar->set_cookie(0, 'sp_dc', $webTokens->{$user} || '', '/', 'open.spotify.com');
	$cookieJar->set_cookie(0, 'sp_dc', $webTokens->{$user} || '', '/', '.spotify.com');
	$cookieJar->save();

	$class->_call('https://open.spotify.com/get_access_token', sub {
		my $response = shift || {};

		if ($response && ref $response && $response->{accessToken}) {
			$cache->set('spotty_access_token_web' . $user, $response->{accessToken}, 1800);
			$cb->($response->{accessToken});
		}
		else {
			$log->warn("Failed to get web token for $user");
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

	if (my $cached = $cache->get("spotty_webhome_$username")) {
		main::INFOLOG && $log->is_info && $log->info(sprintf('Returning cached Home menu structure for %s (%s)', $username, Slim::Utils::DbCache::_key("spotty_webhome_$username")));
		main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($cached));
		$cb->($cached);
		return;
	}

	$class->_call(sprintf(API_URL, 'views/desktop-home'), sub {
		my ($result) = @_;

		my $items = [ map {
			{
				name  => $_->{name},
				tag_line => $_->{tag_line},
				id    => $_->{id},
				items => [ map {
					my $type = $_->{type};
					$libraryCache->normalize($_);
					$_->{type} = $type;
					$_;
				} @{$_->{content}->{items}} ]
			};
		} grep {
			$_->{name} && $_->{content} && $_->{content}->{items} && (ref $_->{content}->{items} || '') eq 'ARRAY' && scalar @{$_->{content}->{items}}
		} @{$result->{content}->{items}} ];

		$cache->set("spotty_webhome_$username", $items, 3600);

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
		_user => Plugins::Spotty::AccountHelper->getAccount($api->client),
	});
}

sub _call {
	my ($class, $url, $cb, $params) = @_;

	my @headers = ( 'Accept' => 'application/json', 'Accept-Encoding' => 'gzip' );

	if ( my @keys = sort keys %{$params}) {
		my @params;
		foreach my $key ( sort @keys ) {
			if ($key eq '_headers') {
				push @headers, @{$params->{$key}};
			}

			next if $key =~ /^_/;
			push @params, $key . '=' . uri_escape_utf8( $params->{$key} );
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
		$class->getToken(sub {
			my $token = shift;
			push @headers, 'Authorization' => 'Bearer ' . $token;

			main::INFOLOG && $log->is_info && $log->info("Web API call: $url");
			# warn Data::Dump::dump(\@headers);

			$http->get($url, @headers);
		}, $params->{_user});
	}
}

1;
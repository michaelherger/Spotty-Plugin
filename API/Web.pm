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

	if (my $cached = $cache->get('spotty_access_token_web' . $user)) {
		$cb->($cached);
		return;
	}

	my $webTokens = $prefs->get('webTokens') || {};

	$class->_call('https://open.spotify.com/get_access_token', sub {
		my $response = shift || {};

		if ($response && ref $response && $response->{accessToken}) {
			$cache->set('spotty_access_token_web' . $user, $response->{accessToken}, $response->{accessTokenExpirationTimestampMs} / 1000);
			$cb->($response->{accessToken});
		}
		else {
			$cb->();
		}
	},{
		reason => 'transport',
		productType => 'web_player',
		_headers => ['Cookie' => 'sp_dc=' . $webTokens->{$user}],
	});
}

sub home {
	my ( $class, $api, $cb ) = @_;

	my $username = $api->username || 'generic';

	if (my $cached = $cache->get("spotty_webhome_$username")) {
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

				$cb->($result, $response);
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
				name => 'Unknown error: ' . $error,
				type => 'text'
			}, $response);
		}
	);

	if ($url =~ /get_access_token/) {
		$http->get($url, @headers);
	}
	else {
		$class->getToken(sub {
			my $token = shift;
			push @headers, 'Authorization' => 'Bearer ' . $token;

			$http->get($url, @headers);
		}, $params->{_user});
	}
}

1;
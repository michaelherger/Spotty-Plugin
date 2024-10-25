package Plugins::Spotty::Settings::Callback;

use strict;

use Digest::SHA;
use JSON::XS::VersionOneAndTwo;
use URI::Escape;
use UUID::Tiny;

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant REDIRECT_URI => 'plugins/Spotty/settings/callback';
use constant PKCE_AUTH_URL => 'https://accounts.spotify.com/authorize?client_id=%s&response_type=code&redirect_uri=%s&code_challenge=%s&code_challenge_method=S256&scope=%s&state=%s';
use constant PKCE_TOKEN_URL => 'https://accounts.spotify.com/api/token';
use constant PKCE_CODE_VERIFIER_CACHEKEY => 'spotty_auth_code_verifier';
use constant USERINFO_URL => 'https://api.spotify.com/v1/me';

use constant SCOPE => join('+', qw(
	playlist-read
	playlist-read-private
	playlist-read-collaborative
	playlist-modify-public
	playlist-modify-private
	user-follow-modify
	user-follow-read
	user-library-read
	user-library-modify
	user-read-private
	user-read-email
	user-top-read
	app-remote-control
	streaming
	user-read-playback-state
	user-modify-playback-state
	user-read-currently-playing
	user-modify-private
	user-modify
	user-read-playback-position
	user-read-recently-played
));


my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

sub init {
	Slim::Web::Pages->addPageFunction(REDIRECT_URI, \&oauthCallback);
}

sub getRedirectUri {
	# return Slim::Utils::Network::serverAddr() . ':' . preferences('server')->get('httpport') . '/' . REDIRECT_URI,
	return 'http://localhost:' . preferences('server')->get('httpport') . '/' . REDIRECT_URI;
}

sub getAuthURL {
	require Bytes::Random::Secure;

	# https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow#code-verifier
	my $code_verifier = Bytes::Random::Secure::random_string_from(
		'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789_-~.',
		128,
	);

	# https://developer.spotify.com/documentation/web-api/tutorials/code-pkce-flow#code-challenge
	my $code_challenge = Digest::SHA::sha256_base64($code_verifier);
	$code_challenge =~ tr/\+\/=/-_/;

	$cache->set(PKCE_CODE_VERIFIER_CACHEKEY, $code_verifier);

	return sprintf(PKCE_AUTH_URL,
		$prefs->get('iconCode'),
		URI::Escape::uri_escape_utf8(getRedirectUri()),
		$code_challenge,
		SCOPE,
		'123456'
	);
}

sub oauthCallback {
	my ($client, $params, $callback, @args) = @_;

	my $code = $params->{code};

	my $body = sprintf('grant_type=authorization_code&code=%s&redirect_uri=%s&client_id=%s&code_verifier=%s',
		$code,
		URI::Escape::uri_escape_utf8(getRedirectUri()),
		$prefs->get('iconCode'),
		$cache->get(PKCE_CODE_VERIFIER_CACHEKEY),
	);

	my $renderCb = sub {
		my $error = shift;

		if ($error) {
			$params->{auth_error} = $error;
			$log->error($error);
		}

		my $response = $args[1];

		# $response->code(404);
		$response->content_type('text/html');
		$response->expires( time() - 1 );
		$response->header( 'Cache-Control' => 'no-cache' );

		$callback->($client, $params, Slim::Web::HTTP::filltemplatefile(REDIRECT_URI . '.html', $params), @args);
	};

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $error;

			if ( $response->headers->content_type =~ /json/i ) {
				my $result = eval { decode_json($response->content) };

				$error = $@;
				$log->error("Failed to parse token exchange response.") if $@;

				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($result));

				if ($result && (my $accessToken = $result->{access_token})) {
					# TODO - async token refresh, timeout
					my $cmd = sprintf('"%s" -n "Squeezebox" -c "%s" --client-id "%s" --disable-discovery --get-token --scope "%s" %s',
						scalar Plugins::Spotty::Helper->get(),
						Plugins::Spotty::Settings::Auth->_cacheFolder(),
						$prefs->get('iconCode'),
						SCOPE,
						'--access-token=' . $accessToken,
					);

					Plugins::Spotty::API::Token::_logCommand($cmd);

					`$cmd 2>&1`;
				}
				elsif ($result->{error}) {
					$error = $result->{error};
				}
			}
			else {
				$error = 'Failed to get token';
				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
			}

			$renderCb->($error);
		},
		sub {
			my ($http, $error, $response) = @_;
			$log->error("Failed to get token") if $error;

			$renderCb->($error);
		},
		{
			cache => 0,
			timeout => 10,
		}
	)->post(PKCE_TOKEN_URL,
		'Content-Type' => 'application/x-www-form-urlencoded',
		$body,
	);

	return;
}



1;
package Plugins::Spotty::Settings::Callback;

use strict;

use Digest::SHA;
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(encode_base64);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant CALLBACK_PATH => 'plugins/Spotty/settings/callback';
use constant REDIRECT_PATH => 'plugins/Spotty/settings/redirect';
use constant PKCE_AUTH_URL => 'https://accounts.spotify.com/authorize?client_id=%s&response_type=code&redirect_uri=%s&code_challenge=%s&code_challenge_method=S256&scope=%s&state=%s';
use constant PKCE_TOKEN_URL => 'https://accounts.spotify.com/api/token';
use constant PKCE_CODE_VERIFIER_CACHEKEY => 'spotty_auth_code_verifier';

use constant CALLBACK_URL => 'https://lms-auth-redirector.nixda.workers.dev/auth/callback';
# use constant REGISTER_CALLBACK_URL => 'http://localhost:8787/auth/prepare';
use constant REGISTER_CALLBACK_URL => 'https://lms-auth-redirector.nixda.workers.dev/auth/prepare';

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
	Slim::Web::Pages->addPageFunction(REDIRECT_PATH, \&oauthRedirect);
	Slim::Web::Pages->addPageFunction(CALLBACK_PATH, \&oauthCallback);
}

sub getRedirectUri {
	return sprintf('http://%s:%s/%s', Slim::Utils::Network::serverAddr(), preferences('server')->get('httpport'), CALLBACK_PATH);
}

sub getCallbackUrl { CALLBACK_URL }

sub getAuthURL { '/' . REDIRECT_PATH }

sub oauthRedirect {
	my ($client, $params, $callback, @args) = @_;

	my $body = {
		url => getRedirectUri(),
		ua => $params->{userAgent},
	};

	my $redirectCb = sub {
		my $error = shift;

		$params->{auth_error} = $error if $error;

		feedbackPage($client, $params, $callback, @args)
	};

	Slim::Networking::SimpleAsyncHTTP->new(
		sub {
			my $response = shift;
			my $error;

			if ( $response->headers->content_type =~ /json/i ) {
				main::DEBUGLOG && $log->is_debug && $log->debug(Data::Dump::dump($response));

				my $result = eval { decode_json($response->content) };

				$error = $@;
				$log->error("Failed to parse token exchange response: " . $response->content) if $@;

				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($result));

				if ($result && (my $nonce = $result->{nonce})) {
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

					my $url = sprintf(PKCE_AUTH_URL,
						$prefs->get('iconCode'),
						CALLBACK_URL,
						$code_challenge,
						SCOPE,
						encode_base64(to_json({
							nonce => $nonce
						})),
					);

					my $response = $args[1];

					$response->code(302);
					$response->expires( time() - 1 );
					$response->header('Location' => $url);

					return $callback->($client, $params, '', @args);
				}
				elsif ($result->{error}) {
					$error = $result->{error};
				}
			}
			else {
				$error = 'Failed to get token';
				main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($response));
			}

			$redirectCb->($error);
		},
		sub {
			my ($http, $error, $response) = @_;
			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($http));

			$redirectCb->($error);
		},
		{
			cache => 0,
			timeout => 10,
		}
	)->post(REGISTER_CALLBACK_URL,
		to_json($body),
	);

	main::INFOLOG && $log->is_info && $log->info("Registering callback: " . Data::Dump::dump($body, REGISTER_CALLBACK_URL));

	return;
}

sub oauthCallback {
	my ($client, $params, $callback, @args) = @_;

	my $code = $params->{code};

	my $body = sprintf('grant_type=authorization_code&code=%s&redirect_uri=%s&client_id=%s&code_verifier=%s',
		$code,
		CALLBACK_URL,
		$prefs->get('iconCode'),
		$cache->get(PKCE_CODE_VERIFIER_CACHEKEY),
	);

	my $renderCb = sub {
		my $error = shift;

		$params->{auth_error} = $error if $error;

		feedbackPage($client, $params, $callback, @args)
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

	main::INFOLOG && $log->is_info && $log->info("Fetching Access Token: " . Data::Dump::dump($body), PKCE_AUTH_URL);

	return;
}

sub feedbackPage {
	my ($client, $params, $callback, @args) = @_;

	if (my $error = $params->{auth_error}) {
		$log->error($error);
	}

	my $response = $args[1];

	$response->content_type('text/html');
	$response->expires( time() - 1 );
	$response->header( 'Cache-Control' => 'no-cache' );

	$callback->($client, $params, Slim::Web::HTTP::filltemplatefile(CALLBACK_PATH . '.html', $params), @args);
}

1;

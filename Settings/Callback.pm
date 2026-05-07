package Plugins::Spotty::Settings::Callback;

use strict;

use Digest::SHA;
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(encode_base64 decode_base64);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# SPOTTY-NG (Phase 2, plan 04 follow-up / FIX-11) — needed for initIcon() in the
# flavor-aware OAuth cache write below. Plugin.pm is normally loaded before any
# Settings page is rendered; the explicit `use` makes the dependency visible to
# perl -c and avoids relying on import ordering.
use Plugins::Spotty::Plugin;

use constant CALLBACK_PATH => 'plugins/Spotty/settings/callback';
use constant REDIRECT_PATH => 'plugins/Spotty/settings/redirect';
use constant PKCE_AUTH_URL => 'https://accounts.spotify.com/authorize?client_id=%s&response_type=code&redirect_uri=%s&code_challenge=%s&code_challenge_method=S256&scope=%s&state=%s';
use constant PKCE_CODE_VERIFIER_CACHEKEY => 'spotty_auth_code_verifier';

use constant CALLBACK_URL => 'https://api.lms-community.org/auth/callback';
use constant REGISTER_CALLBACK_URL => 'https://api.lms-community.org/auth/prepare';

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

use constant PLUGIN_PACKAGE => __PACKAGE__ =~ s/Settings::Callback$/Plugin/r;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');

sub init {
	Slim::Web::Pages->addPageFunction(Slim::Web::HTTP::CSRF->protectURI(REDIRECT_PATH), \&oauthRedirect);
	Slim::Web::Pages->addPageFunction(CALLBACK_PATH, \&oauthCallback);
}

sub getRedirectUri {
	return Slim::Utils::Network::serverURL() . '/' . CALLBACK_PATH;
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

					# SPOTTY-NG (Phase 2.5 / D-2.5-04 / SETUP-05) — flavor-aware client_id selection without
					# pref mutation. When ?flavor=bundled query-param is present (the basic.html "Authorize
					# browsing" link, plan-03), build the PKCE-AUTH-URL with the bundled-default Client ID
					# rather than the user's iconCode pref. $prefs is NOT touched — per-request override only.
					my $flavor   = (($params->{flavor} // '') eq 'bundled') ? 'bundled' : 'own';
					my $clientId = ($flavor eq 'bundled')
						? Plugins::Spotty::Plugin->initIcon()
						: $prefs->get('iconCode');

					my $url = sprintf(PKCE_AUTH_URL,
						$clientId,
						CALLBACK_URL,
						$code_challenge,
						SCOPE,
						# SPOTTY-NG (Phase 2.5 / D-2.5-04 / SETUP-05) — thread flavor into the state JSON so
						# the value survives the OAuth round-trip. Spotify echoes `state` verbatim per OAuth
						# 2.0 spec; oauthCallback decodes the JSON and recovers $params->{flavor}.
						encode_base64(to_json({
							nonce  => $nonce,
							flavor => $flavor,
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
			my ($http, $error) = @_;
			main::INFOLOG && $log->is_info && $log->info(Data::Dump::dump($http));

			$redirectCb->($error);
		},
		{
			cache => 0,
			timeout => 10,
		}
	)->post(REGISTER_CALLBACK_URL,
		Slim::Utils::Misc->can('apiHeaders') ? Slim::Utils::Misc::apiHeaders(PLUGIN_PACKAGE) : ('X-LMS-Plugin-ID' => PLUGIN_PACKAGE),
		to_json($body),
	);

	main::INFOLOG && $log->is_info && $log->info("Registering callback: " . Data::Dump::dump($body, REGISTER_CALLBACK_URL));

	return;
}

sub oauthCallback {
	my ($client, $params, $callback, @args) = @_;

	my $code = $params->{code};

	# SPOTTY-NG (Phase 2.5 / D-2.5-04 / SETUP-05) — decode the OAuth state param to recover
	# the flavor query-param oauthRedirect encoded into state JSON at lines 121-126. Spotify
	# echoes `state` verbatim per OAuth 2.0 spec; pre-Phase-2.5 callbacks (no flavor in state)
	# leave $params->{flavor} undef and the downstream flavor decision falls through to
	# HARDEN-13's iconCode-vs-initIcon test (backward-compat preserved).
	if ($params->{state}) {
		my $decodedState = eval { from_json(decode_base64($params->{state})) };
		if (ref $decodedState eq 'HASH' && defined $decodedState->{flavor}) {
			$params->{flavor} = $decodedState->{flavor};
		}
	}

	my $renderCb = sub {
		my $error = shift;

		$params->{auth_error} = $error if $error;

		feedbackPage($client, $params, $callback, @args)
	};

	main::INFOLOG && $log->is_info && $log->info("Exchange code for access token");
	my $defaultCode = $prefs->get('iconCode');

	my $api = Plugins::Spotty::API->new({ noProfileUpdate => 1 });
	$api->codeExchange(
		sub {
			my $result = shift;
			my $error;

			if ($result && (my $accessToken = $result->{access_token})) {
				my $refreshToken = $result->{refresh_token};
				my $url = 'https://api.spotify.com/v1/me';

				$api->me(
					sub {
						my $meResult = shift;

						if ($meResult->{name} && $meResult->{name} =~ /error/i) {
							$error = $result->{name};
							$log->error("Failed to get user profile");
						}
						else {
							my $userId = $meResult->{id};

							$log->warn(sprintf("Authenticated Spotify user: %s (%s, %s)", $userId, $meResult->{display_name} || 'no display name', $meResult->{product} || 'no product info'));

						# Re-read iconCode at OAuth completion so the flavor decision uses
							# the live pref value, not a captured-at-start snapshot.
							my $currentCode = $prefs->get('iconCode');

							# Flush the bundled-hint cache. A successful OAuth completion means the
							# routing identity has just changed. Routing decisions previously cached
							# in the bundled-hint cache may no longer be correct under the new identity.
							Plugins::Spotty::API::_flushBundledHints();

							# Clear the needs-bundled-auth flag on successful OAuth completion.
							# The render-time probe in Settings.pm is authoritative; clearing the flag
							# here avoids a brief flicker of stale prompt on the next Settings render.
							$cache->remove(
								Plugins::Spotty::API::NEEDS_BUNDLED_AUTH_KEY_PREFIX() . $userId
							) if $userId;

							# Flavor decision overlay. When ?flavor=bundled flowed through state-JSON,
							# $params->{flavor} is 'bundled' and we land the RT under the bundled-flavor
							# cache key irrespective of what iconCode happens to be set to right now.
							# When the param is absent (legacy callbacks, manual OAuth), fall back to
							# comparing $currentCode vs initIcon().
							my $oauthFlavor = ((($params->{flavor} // '') eq 'bundled')
								? 'bundled'
								: (($currentCode eq Plugins::Spotty::Plugin->initIcon()) ? 'bundled' : 'own'));

							# When bundled-flavor, the cache-key $code segment MUST equal what
							# Token::hasRefreshToken(flavor=>'bundled') derives at probe time
							# (Plugin->initIcon() per Token.pm). Otherwise the bundled RT lands
							# under <ownDevID>_<userId>_bundled but the probe looks under
							# <bundledIcon>_<userId>_bundled -> permanent miss.
							# $prefs is NOT mutated; this is a per-call $code arg override only.
							my $oauthCode = ($oauthFlavor eq 'bundled')
								? Plugins::Spotty::Plugin->initIcon()
								: $currentCode;
							Plugins::Spotty::API::Token->cacheAccessToken($oauthCode, $userId, $accessToken, $result->{expires_in}, $oauthFlavor);
							Plugins::Spotty::API::Token->cacheRefreshToken($oauthCode, $userId, $refreshToken, $oauthFlavor) if $refreshToken;

							# When flavor=bundled, the spotty helper subprocess MUST receive the bundled
							# Client ID so the cached AT it stores is keyed under the bundled flavor too.
							my $helperClientId = ($oauthFlavor eq 'bundled')
								? Plugins::Spotty::Plugin->initIcon()
								: $currentCode;

							# TODO - async token refresh, timeout
							my $cmd = sprintf('"%s" -n "Squeezebox" -c "%s" --client-id "%s" --disable-discovery --get-token --scope "%s" %s',
								scalar Plugins::Spotty::Helper->get(),
								Plugins::Spotty::Settings::Auth->_cacheFolder(),
							$helperClientId,
								SCOPE,
								'--access-token=' . $accessToken,
							);

							Plugins::Spotty::API::logSensitive($cmd);

							`$cmd 2>&1`;

							# SPOTTY-NG (Phase 2.5 / D-2.5-02(2) / SETUP-07) — post-OAuth probe. When this
							# completion was an OWN-flavor OAuth (the user just configured their own Dev-ID
							# for the first time, or re-OAuthed under their own Dev-ID), check whether they
							# have a bundled-flavor RT cached. If not, set the needs-bundled-auth flag so the
							# next Settings render surfaces the "Authorize browsing" link without requiring
							# the user to first hit a 403/410 on a deprecated browse endpoint.
							# Skip when this completion was itself a bundled OAuth — the flag was already
							# cleared above and the user is fine.
							if ($oauthFlavor eq 'own' && $userId
									&& !Plugins::Spotty::API::Token->hasRefreshToken(
											$api, flavor => 'bundled', userId => $userId)) {
								Plugins::Spotty::API::_spottyNgRememberNeedsBundledAuth($userId);
							}
						}

						$renderCb->($error);
					},
					$accessToken,
				);

				return;
			}
			elsif ($result->{name} && $result->{name} =~ /error/i) {
				$error = $result->{name};
			}

			$renderCb->($error);
		},
		{
			code => $params->{code},
			callbackUrl => CALLBACK_URL,
			codeVerifier => $cache->get(PKCE_CODE_VERIFIER_CACHEKEY),
		},
	);
}

sub feedbackPage {
	my ($client, $params, $callback, @args) = @_;

	if (my $error = $params->{auth_error}) {
		$log->error($error);
	}

	# always use Default skin for this page, as Material wouldn't render correctly outside its own context
	$params->{skinOverride} = 'Default';

	my $response = $args[1];

	$response->content_type('text/html');
	$response->expires( time() - 1 );
	$response->header( 'Cache-Control' => 'no-cache' );

	$callback->($client, $params, Slim::Web::HTTP::filltemplatefile(CALLBACK_PATH . '.html', $params), @args);
}

1;

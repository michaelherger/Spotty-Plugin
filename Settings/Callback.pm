package Plugins::Spotty::Settings::Callback;

use strict;

use Digest::SHA;
use JSON::XS::VersionOneAndTwo;
use MIME::Base64 qw(encode_base64 decode_base64);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

# Needed for initIcon() in the flavor-aware OAuth cache write below.
use Plugins::Spotty::Plugin;

use constant CALLBACK_PATH => 'plugins/Spotty/settings/callback';
use constant REDIRECT_PATH => 'plugins/Spotty/settings/redirect';
use constant PKCE_AUTH_URL => 'https://accounts.spotify.com/authorize?client_id=%s&response_type=code&redirect_uri=%s&code_challenge=%s&code_challenge_method=S256&scope=%s&state=%s';
use constant PKCE_CODE_VERIFIER_CACHEKEY => 'spotty_auth_code_verifier';
# Flavor is cached server-side because api.lms-community.org's relay strips Spotify's
# `state` query parameter when bouncing the callback to LMS (only `code` survives).
# This cache key acts as a server-side fallback for oauthCallback to recover the flavor.
use constant OAUTH_PENDING_FLAVOR_CACHEKEY => 'spotty_oauth_pending_flavor';
use constant OAUTH_PENDING_FLAVOR_TTL      => 600;  # seconds; one-shot, cleared in oauthCallback

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

					# Flavor-aware client_id selection without pref mutation.
					# When ?flavor=bundled is present, use the bundled-default Client ID.
					my $flavor   = (($params->{flavor} // '') eq 'bundled') ? 'bundled' : 'own';
					my $clientId = ($flavor eq 'bundled')
						? Plugins::Spotty::Plugin->initIcon()
						: $prefs->get('iconCode');

					# Cache the flavor server-side so oauthCallback can recover it if the relay
					# strips the `state` parameter. One-shot — cleared in oauthCallback.
					$cache->set(OAUTH_PENDING_FLAVOR_CACHEKEY, $flavor, OAUTH_PENDING_FLAVOR_TTL);

					# Build the OAuth state value as URL-safe base64 with no embedded newlines.
					# encode_base64 with empty eol suppresses \n; translate to base64url alphabet
					# and strip = padding before placing in the query string.
					my $stateJson = to_json({
						nonce  => $nonce,
						flavor => $flavor,
					});
					my $stateB64 = encode_base64($stateJson, '');
					$stateB64 =~ tr|+/|-_|;
					$stateB64 =~ s/=+\z//;

					my $url = sprintf(PKCE_AUTH_URL,
						$clientId,
						CALLBACK_URL,
						$code_challenge,
						SCOPE,
						$stateB64,
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

	# Decode the OAuth state param to recover the flavor. Spotify echoes `state` verbatim;
	# callbacks without a flavor in state leave $params->{flavor} undef and the downstream
	# decision falls through to the iconCode-vs-initIcon test (backward-compat preserved).
	if ($params->{state}) {
		# Reverse the base64url substitution from oauthRedirect and restore = padding.
		# eval-wrap + ref/defined guards survive malformed payloads (legacy callbacks,
		# attacker-injected garbage).
		my $b64 = $params->{state};
		$b64 =~ tr|-_|+/|;
		$b64 .= '=' x ((4 - length($b64) % 4) % 4);
		my $decodedState = eval { from_json(decode_base64($b64)) };
		if (ref $decodedState eq 'HASH' && defined $decodedState->{flavor}) {
			$params->{flavor} = $decodedState->{flavor};
		}
	}

	# Relay-strip fallback: if the relay stripped `state`, recover flavor from the
	# LMS-side cache oauthRedirect populated. Clear the cache entry in both cases.
	if (!defined $params->{flavor}) {
		my $cachedFlavor = $cache->get(OAUTH_PENDING_FLAVOR_CACHEKEY);
		$params->{flavor} = $cachedFlavor if defined $cachedFlavor && length $cachedFlavor;
	}
	$cache->remove(OAUTH_PENDING_FLAVOR_CACHEKEY);

	my $renderCb = sub {
		my $error = shift;

		$params->{auth_error} = $error if $error;

		feedbackPage($client, $params, $callback, @args)
	};

	main::INFOLOG && $log->is_info && $log->info("Exchange code for access token");

	# Re-read iconCode at OAuth completion (inside the me-callback), not at OAuth start.
	# The pref value captured here is the authoritative $currentCode for both the flavor
	# decision below and the spotty helper binary --client-id arg further down.

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

							my $currentCode = $prefs->get('iconCode');

							# Flush the bundled-hint cache on successful OAuth completion (own or bundled).
							# Routing decisions cached under the old identity may no longer be correct
							# under the new identity; flushing forces the next browse cycle to re-learn.
							Plugins::Spotty::API::_flushBundledHints();

							# Self-heal the needs-bundled-auth cache flag on successful OAuth completion.
							# The render-time probe in Settings.pm is authoritative; clearing here avoids
							# a brief flicker of a stale prompt on the next Settings render.
							# Note: NEEDS_BUNDLED_AUTH_KEY_PREFIX() is called with explicit parens because
							# this file does not `use Plugins::Spotty::API` and bare constants from another
							# package can be mis-parsed as barewords under `use strict`.
							$cache->remove(
								Plugins::Spotty::API::NEEDS_BUNDLED_AUTH_KEY_PREFIX() . $userId
							) if $userId;

							# Flavor decision: when ?flavor=bundled flowed through state-JSON, land the RT
							# under the bundled-flavor cache key regardless of current iconCode.
							# When the param is absent (legacy callbacks, manual OAuth), fall back to
							# comparing $currentCode to initIcon().
							my $oauthFlavor = ((($params->{flavor} // '') eq 'bundled')
								? 'bundled'
								: (($currentCode eq Plugins::Spotty::Plugin->initIcon()) ? 'bundled' : 'own'));

							# When bundled-flavor, the cache-key $code segment MUST equal what
							# Token::hasRefreshToken(flavor=>'bundled') derives at probe time
							# (Plugin->initIcon()). Otherwise the bundled RT lands under
							# <ownDevID>_<userId>_bundled but the probe looks under
							# <bundledIcon>_<userId>_bundled — a permanent miss.
							# $prefs is NOT mutated; this is a per-call $code arg override only.
							my $oauthCode = ($oauthFlavor eq 'bundled')
								? Plugins::Spotty::Plugin->initIcon()
								: $currentCode;
							Plugins::Spotty::API::Token->cacheAccessToken($oauthCode, $userId, $accessToken, $result->{expires_in}, $oauthFlavor);
							Plugins::Spotty::API::Token->cacheRefreshToken($oauthCode, $userId, $refreshToken, $oauthFlavor) if $refreshToken;

							# When flavor=bundled, the spotty helper subprocess must receive the bundled
							# Client ID so the AT it stores is keyed under the bundled flavor.
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

							# Post-OAuth probe: when this was an own-flavor OAuth completion and the user
							# has no bundled-flavor RT cached, set the needs-bundled-auth flag so the
							# next Settings render surfaces the "Authorize browsing" link proactively.
							# Skip when this completion was itself bundled OAuth — flag already cleared above.
							if ($oauthFlavor eq 'own' && $userId
									&& !Plugins::Spotty::API::Token->hasRefreshToken(
											$api, flavor => 'bundled', userId => $userId)) {
								Plugins::Spotty::API::_rememberNeedsBundledAuth($userId);
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
		# Flavor-aware _client_id for the /api/token authorization_code exchange.
		# Mirrors oauthRedirect: when state-JSON decoded $params->{flavor} == 'bundled',
		# the /authorize URL was built with the bundled initIcon, so the exchange must
		# use the same Client ID. $prefs is NOT mutated; per-call _client_id arg only.
		{
			code => $params->{code},
			callbackUrl => CALLBACK_URL,
			codeVerifier => $cache->get(PKCE_CODE_VERIFIER_CACHEKEY),
			_client_id => ((($params->{flavor} // '') eq 'bundled')
				? Plugins::Spotty::Plugin->initIcon()
				: $prefs->get('iconCode')),
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

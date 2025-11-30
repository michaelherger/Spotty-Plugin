package Plugins::Spotty::Settings::Player;

use strict;
use base qw(Slim::Web::Settings);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

my $prefs = preferences('plugin.spotty');
my $log   = logger('plugin.spotty');

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub needsClient {
	return 1;
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/player.html');
}

sub prefs {
	my ($class, $client) = @_;
	my @prefs = qw(replaygain filterExplicitContent reversePodcastOrder);
	return ($prefs->client($client), @prefs);
}

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	$params->{canAutoplay} = Plugins::Spotty::Helper->getCapability('autoplay');

	# get Home menu items if a client is connected
	Plugins::Spotty::Plugin->getAPIHandler($client)->home(sub {
		_initHomeMenuItems($client, $params, shift);
		my $body = $class->SUPER::handler($client, $params);
		$callback->( $client, $params, $body, $httpClient, $response );
	});

	return;
}

sub validFor {
	return Plugins::Spotty::AccountHelper->hasCredentials() ? 1 : 0;
}

sub _initHomeMenuItems {
	my ($client, $params, $homeItems) = @_;
	my $ignoreItems = $prefs->client($client)->get('ignoreHomeItems') || {};

	$params->{homeItems} = [ map {
		if ($params->{saveSettings}) {
			if ($params->{'pref_homeItem_' . $_->{id}}) {
				delete $ignoreItems->{$_->{id}};
			}
			else {
				$ignoreItems->{$_->{id}} = 1;
			}
		}

		{
			name => $_->{name} . ($_->{description} ? ' - ' . $_->{description} : ''),
			id => $_->{id},
			disabled => $ignoreItems->{$_->{id}},
		};
	} grep {
		$_->{id} && $_->{name}
	} @{ Plugins::Spotty::OPML::sortHomeItems($homeItems) } ];

	$prefs->client($client)->set('ignoreHomeItems', $ignoreItems);

	return $params->{homeItems};
}

1;
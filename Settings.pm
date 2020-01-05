package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::Spotty::Plugin;
use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::Settings::Auth;
use Plugins::Spotty::Settings::Player;
use Plugins::Spotty::Settings::PlaylistFolders;

use constant SETTINGS_URL => 'plugins/Spotty/settings/basic.html';

my $prefs = preferences('plugin.spotty');

sub new {
	my $class = shift;

	Plugins::Spotty::Settings::Auth->new();
	Plugins::Spotty::Settings::Player->new();
	Plugins::Spotty::Settings::PlaylistFolders->new();

	if (!Slim::Networking::Async::HTTP->hasSSL()) {
		Slim::Web::Pages->addPageFunction(SETTINGS_URL, $class);
	}

	return $class->SUPER::new(@_);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI(
		Slim::Networking::Async::HTTP->hasSSL()
		? SETTINGS_URL
		: 'plugins/Spotty/settings/noSSL.html'
	);
}

sub prefs {
	my @prefs = qw(myAlbumsOnly bitrate iconCode accountSwitcherMenu helper optimizePreBuffer);
	push @prefs, 'disableDiscovery', 'checkDaemonConnected' if Plugins::Spotty::Plugin->canDiscovery();
	return ($prefs, @prefs);
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;

	my ($helperPath, $helperVersion) = Plugins::Spotty::Helper->get();

	# rename temporary authentication cache folder (if existing)
	Plugins::Spotty::Settings::Auth->cleanup();

	my $osDetails = Slim::Utils::OSDetect::details();

	# don't even continue if we're missing the helper application
	if ( !$helperPath ) {

		# Windows should just work - except if the MSVC 2015 runtime was missing
		if (main::ISWINDOWS) {
			$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER_WINDOWS');
		}
		else {
			my $knownIncompatible = $osDetails->{osName} =~ /Mac.?OS .*10\.(?:1|2|3|4|5|6)\./i
				|| ($osDetails->{osArch} && $osDetails->{osArch} =~ /\b(?:powerpc)\b/i);

			if ($knownIncompatible) {
				$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_SYSTEM_INCOMPATIBLE');
			}
			elsif (Slim::Utils::OSDetect::isLinux() && ($osDetails->{'osArch'} || '') =~ /armv8|aarch64/i) {
				$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER_AARCH64');
			}
			elsif (Slim::Utils::OSDetect::isLinux() && ($osDetails->{'osArch'} || '') =~ /arm/i) {
				$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER_ARM_LEGACY');
			}
			else {
				$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER');
			}

			$paramRef->{helperMissing} .= sprintf('<br><br>%s %s / %s<br><br>%s<br>%s<br>%s',
					string('INFORMATION_OPERATINGSYSTEM') . string('COLON'),
					$osDetails->{'osName'},
					($osDetails->{'osArch'} ? $osDetails->{'osArch'} : 'unknown'),
					string('PLUGIN_SPOTTY_INFORMATION_BINDIRS') . string('COLON'),
					eval{ join("<br>", Slim::Utils::Misc::getBinPaths()) } || string('PLUGIN_SPOTTY_PLEASE_UPDATE'),
					Slim::Utils::OSDetect::isLinux() ? `ldd --version 2>&1 | head -n1` : ''
				);
		}
	}

	if ( my ($deleteAccount) = map { /delete_(.*)/; $1 } grep /^delete_/, keys %$paramRef ) {
		Plugins::Spotty::AccountHelper->deleteCacheFolder($deleteAccount);
	}

	if ($paramRef->{saveSettings}) {
		$paramRef->{pref_iconCode} ||= Plugins::Spotty::Plugin->_initIcon();

		foreach my $client ( Slim::Player::Client::clients() ) {
			$prefs->client($client)->set('enableSpotifyConnect', $paramRef->{'connect_' . $client->id} ? 1 : 0);
		}

		if ($paramRef->{clearPlaylistFolderCache}) {
			Plugins::Spotty::PlaylistFolders->purgeCache(1);
		}

		if ($paramRef->{clearSearchHistory}) {
			$prefs->set('spotify_recent_search', []);
		}
	}

	if ( !$paramRef->{helperMissing} && ($paramRef->{addAccount} || !Plugins::Spotty::AccountHelper->hasCredentials()) ) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'authentication.html?ajaxUpdate=' . $paramRef->{ajaxUpdate});
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::Settings::Auth->shutdownHelper();

	$paramRef->{credentials}  = Plugins::Spotty::AccountHelper->getSortedCredentialTupels();
	$paramRef->{canDiscovery} = Plugins::Spotty::Plugin->canDiscovery();
	$paramRef->{error429}     = Plugins::Spotty::API->hasError429();
	$paramRef->{isLowCaloriesPi} = Plugins::Spotty::Helper->isLowCaloriesPi();

	$paramRef->{players}      = [ sort {
		lc($a->{name}) cmp lc($b->{name})
	} map {
		{
			name => $_->name,
			id => $_->id,
			enabled => $prefs->client($_)->get('enableSpotifyConnect')
		}
	} Slim::Player::Client::clients() ];

	return $class->SUPER::handler($client, $paramRef);
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	my $helpers = Plugins::Spotty::Helper->getAll();

	if ($helpers && scalar keys %$helpers > 1) {
		$paramRef->{helpers} = $helpers;
	}

	my ($helperPath, $helperVersion) = Plugins::Spotty::Helper->get();

	$paramRef->{helperPath}     = $helperPath;
	$paramRef->{helperVersion}  = $helperVersion ? "v$helperVersion" : string('PLUGIN_SPOTTY_HELPER_ERROR');
	$paramRef->{canConnect}     = Plugins::Spotty::Connect->canSpotifyConnect();

	$paramRef->{hasDefaultIcon} = Plugins::Spotty::Plugin->hasDefaultIcon();

	$paramRef->{warning} && $paramRef->{warning} =~ s/iconCode/Client ID/i;
}


1;
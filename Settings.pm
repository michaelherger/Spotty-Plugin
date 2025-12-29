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
	my @prefs = qw(myAlbumsOnly cleanupTags bitrate iconCode accountSwitcherMenu helper sortAlbumsAlphabetically sortArtistsAlphabetically sortPlaylisttracksByAddition);
	push @prefs, 'sortSongsAlphabetically' if !Plugins::Spotty::Plugin->hasDefaultIcon();
	push @prefs, 'forceFallbackAP' if !Plugins::Spotty::Helper->getCapability('no-ap-port');
	return ($prefs, @prefs);
}

sub handler {
	my ($class, $client, $paramRef, $callback, $httpClient, $response) = @_;

	my ($helperPath, $helperVersion) = Plugins::Spotty::Helper->get();

	# rename temporary authentication cache folder (if existing)
	Plugins::Spotty::Settings::Auth->cleanup();

	# don't even continue if we're missing the helper application
	$paramRef->{helperMissing} = _getHelperMissingMessage() unless $helperPath;

	if ( my ($deleteAccount) = map { /delete_(.*)/; $1 } grep /^delete_/, keys %$paramRef ) {
		Plugins::Spotty::AccountHelper->deleteCacheFolder($deleteAccount);
	}

	if ($paramRef->{saveSettings}) {
		$paramRef->{pref_iconCode} ||= Plugins::Spotty::Plugin->initIcon();

		if ($paramRef->{clearPlaylistFolderCache}) {
			Plugins::Spotty::PlaylistFolders->purgeCache(1);
		}

		# need to handle the icon before checking for a redirect below
		$prefs->set('iconCode', $paramRef->{'pref_iconCode'});

		if ($paramRef->{clearSearchHistory}) {
			$prefs->set('spotify_recent_search', []);
		}

		my $dontImportAccounts = $prefs->get('dontImportAccounts') || {};
		foreach my $prefName (keys %$paramRef) {
			if ($prefName =~ /^pref_dontimport_(.*)/) {
				$dontImportAccounts->{$1} = $paramRef->{$prefName};
			}
		}
		$prefs->set('dontImportAccounts', $dontImportAccounts);

		# make sure value is not undefined, or it might get re-initialized
		$paramRef->{pref_cleanupTags} ||= 0;
	}

	if ( !$paramRef->{helperMissing} && !$paramRef->{forceBasicSettings} && ($paramRef->{addAccount} || !Plugins::Spotty::AccountHelper->hasCredentials()) ) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'authentication.html?ajaxUpdate=' . $paramRef->{ajaxUpdate});
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	$paramRef->{credentials}  = Plugins::Spotty::AccountHelper->getSortedCredentialTupels();
	$paramRef->{displayNames} = { map {
		my ($id) = each %$_;
		$id => Plugins::Spotty::AccountHelper->getDisplayName($id);
	} @{$paramRef->{credentials}} };
	$paramRef->{products}     = $prefs->get('products') || {};

	$paramRef->{canDiscovery} = Plugins::Spotty::Plugin->canDiscovery();
	$paramRef->{error429}     = Plugins::Spotty::API->hasError429();
	$paramRef->{isLowCaloriesPi} = Plugins::Spotty::Helper->isLowCaloriesPi();

	$paramRef->{players}      = [ sort {
		lc($a->{name}) cmp lc($b->{name})
	} map {
		{
			name => $_->name,
			id => $_->id,
		}
	} Slim::Player::Client::clients() ];

	return $class->SUPER::handler($client, $paramRef);
}

sub _getHelperMissingMessage {
	my $osDetails = Slim::Utils::OSDetect::details();

	# Windows should just work - except if the MSVC 2015 runtime was missing
	return string('PLUGIN_SPOTTY_MISSING_HELPER_WINDOWS') if main::ISWINDOWS;

	my $helperMissingMessage = string('PLUGIN_SPOTTY_MISSING_HELPER');

	my $knownIncompatible = $osDetails->{osName} =~ /Mac.?OS .*10\.(?:1|2|3|4|5|6)\./i
		|| ($osDetails->{osArch} && $osDetails->{osArch} =~ /\b(?:powerpc)\b/i);

	if ($knownIncompatible) {
		$helperMissingMessage = string('PLUGIN_SPOTTY_SYSTEM_INCOMPATIBLE');
	}

	return $helperMissingMessage . sprintf('<br><br>%s %s / %s<br><br>%s<br>%s<br>%s',
		string('INFORMATION_OPERATINGSYSTEM') . string('COLON'),
		$osDetails->{'osName'},
		($osDetails->{'osArch'} ? $osDetails->{'osArch'} : 'unknown'),
		string('PLUGIN_SPOTTY_INFORMATION_BINDIRS') . string('COLON'),
		eval{ join("<br>", Slim::Utils::Misc::getBinPaths()) } || string('PLUGIN_SPOTTY_PLEASE_UPDATE'),
		Slim::Utils::OSDetect::isLinux() ? `ldd --version 2>&1 | head -n1` : ''
	);
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
	$paramRef->{canApPort}      = !Plugins::Spotty::Helper->getCapability('no-ap-port');

	$paramRef->{hasDefaultIcon} = Plugins::Spotty::Plugin->hasDefaultIcon();

	$paramRef->{dontImportAccounts} = $prefs->get('dontImportAccounts') || {};

	$paramRef->{warning} && $paramRef->{warning} =~ s/iconCode/Client ID/i;
}


1;
package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

use File::Spec::Functions qw(catdir);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::Spotty::Plugin;
use Plugins::Spotty::SettingsAuth;

my $prefs = preferences('plugin.spotty');

sub new {
	my $class = shift;

	Plugins::Spotty::SettingsAuth->new();
	
	return $class->SUPER::new(@_);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI(
		Slim::Networking::Async::HTTP->hasSSL()
		? 'plugins/Spotty/settings/basic.html'
		: 'plugins/Spotty/settings/noSSL.html'
	);
}

sub prefs {
	my @prefs = qw(myAlbumsOnly bitrate iconCode accountSwitcherMenu);
	push @prefs, 'disableDiscovery' if Plugins::Spotty::Plugin->canDiscovery();
	return ($prefs, @prefs);
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;
	
	my ($helperPath, $helperVersion) = Plugins::Spotty::Plugin->getHelper();

	# rename temporary authentication cache folder (if existing)
	Plugins::Spotty::SettingsAuth->cleanup();

	my $osDetails = Slim::Utils::OSDetect::details();
	
	my $knownIncompatible = $osDetails->{osName} =~ /Mac.?OS .*10\.(?:1|2|3|4|5|6)\./i
		|| ($osDetails->{osArch} && $osDetails->{osArch} =~ /\b(?:powerpc)\b/i);
		
	# don't even continue if we're missing the helper application
	if ( !$helperPath ) {
		
		# Windows should just work - except if the MSVC 2015 runtime was missing
		if (main::ISWINDOWS) {
			$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER_WINDOWS');
		}
		else {
			$paramRef->{helperMissing} = string($knownIncompatible ? 'PLUGIN_SPOTTY_SYSTEM_INCOMPATIBLE' : 'PLUGIN_SPOTTY_MISSING_HELPER') . 
				sprintf('<br><br>%s %s / %s<br><br>%s<br>%s<br>%s',
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
		Plugins::Spotty::Plugin->deleteCacheFolder($deleteAccount);
	}

	if ($paramRef->{saveSettings}) {
		$paramRef->{pref_iconCode} ||= Plugins::Spotty::Plugin->_initIcon();

		foreach my $client ( Slim::Player::Client::clients() ) {
			$prefs->client($client)->set('enableSpotifyConnect', $paramRef->{'connect_' . $client->id} ? 1 : 0);
		}
	}
	
	if ( !$paramRef->{helperMissing} && ($paramRef->{addAccount} || !Plugins::Spotty::Plugin->hasCredentials()) ) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'authentication.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::SettingsAuth->shutdownHelper();
	
	$paramRef->{credentials}   = Plugins::Spotty::Plugin->getSortedCredentialTupels();
	$paramRef->{helperPath}    = $helperPath;
	$paramRef->{helperVersion} = "v$helperVersion" || string('PLUGIN_SPOTTY_HELPER_ERROR');
	$paramRef->{canDiscovery}  = Plugins::Spotty::Plugin->canDiscovery();
	$paramRef->{error429}      = Plugins::Spotty::API->hasError429();
	
	$paramRef->{players}       = [ sort {
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
	$paramRef->{hasDefaultIcon} = Plugins::Spotty::Plugin->hasDefaultIcon();
}


1;
package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

use File::Spec::Functions qw(catdir);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::Spotty::Plugin;
use Plugins::Spotty::SettingsAuth;

use constant AUTHENTICATE => '__AUTHENTICATE__';

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
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/basic.html');
}

sub prefs {
	return ($prefs, qw(myAlbumsOnly audioCacheSize iconCode));
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;
	
	my ($helperPath, $helperVersion) = Plugins::Spotty::Plugin->getHelper();

	# rename temporary authentication cache folder (if existing)
	Plugins::Spotty::Plugin->renameCacheFolder(AUTHENTICATE);
	Plugins::Spotty::Plugin->deleteCacheFolder(AUTHENTICATE);
	
	# don't even continue if we're missing the helper application
	if ( !$helperPath ) {
		my $osDetails = Slim::Utils::OSDetect::details();
		
		# Windows should just work - except if the MSVC 2015 runtime was missing
		if (main::ISWINDOWS) {
			$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER_WINDOWS');
		}
		else {
			$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER') . 
				sprintf('<br><br>%s %s / %s<br><br>%s<br>%s<br>%s',
					string('INFORMATION_OPERATINGSYSTEM') . string('COLON'), 
					$osDetails->{'osName'},
					($osDetails->{'osArch'} ? $osDetails->{'osArch'} : 'unknown'),
					string('INFORMATION_BINDIRS') . string('COLON'),
					join("<br>", Slim::Utils::Misc::getBinPaths()),
					Slim::Utils::OSDetect::isLinux() ? `ldd --version 2>&1 | head -n1` : ''
				);
		}
	}

	if ( my ($deleteAccount) = map { /delete_(.*)/; $1 } grep /^delete_/, keys %$paramRef ) {
		Plugins::Spotty::Plugin->deleteCacheFolder($deleteAccount);
	}
	elsif ( my ($makeDefault) = map { /default_(.*)/; $1 } grep /^default_/, keys %$paramRef ) {
		Plugins::Spotty::Plugin->renameCacheFolder('default');
		Plugins::Spotty::Plugin->renameCacheFolder($makeDefault, 'default');
	}

	if ($paramRef->{saveSettings}) {
		$paramRef->{pref_iconCode} ||= Plugins::Spotty::Plugin->_initIcon();
	}
	
	if ( !$paramRef->{helperMissing} && ($paramRef->{addAccount} || !Plugins::Spotty::Plugin->hasCredentials()) ) {
		my $addAccount = '';
		if ($paramRef->{addAccount}) {
			$addAccount = '?accountId=' . AUTHENTICATE;
		}
		
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'authentication.html' . $addAccount);
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::SettingsAuth->shutdownHelper();
	
	$paramRef->{credentials} = Plugins::Spotty::Plugin->getSortedCredentialTupels();
	$paramRef->{helperPath} = $helperPath;
	$paramRef->{helperVersion} = $helperVersion || string('PLUGIN_SPOTTY_HELPER_ERROR');
	$paramRef->{error429} = Plugins::Spotty::API->hasError429();

	return $class->SUPER::handler($client, $paramRef);
}

sub beforeRender {
	my ($class, $paramRef) = @_;
	$paramRef->{hasDefaultIcon} = Plugins::Spotty::Plugin->hasDefaultIcon();
}


1;
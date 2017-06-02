package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::Spotty::Plugin;
use Plugins::Spotty::SettingsAuth;

my $prefs = preferences('plugin.spotty');

my $needsRestart;

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
	return ($prefs, qw(enableBrowseMode myAlbumsOnly));
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;
	
	my $helperPath = Plugins::Spotty::Plugin->getHelper();
	
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
		
	if ($paramRef->{'resetAuthorization'}) {
		my $credentialsFile = Plugins::Spotty::Plugin->hasCredentials();
		unlink $credentialsFile;
	}

	if ($paramRef->{'saveSettings'}) {
		if ( $paramRef->{'username'} && $paramRef->{'password'} && $helperPath ) {
			my $command = sprintf(
				'%s -c "%s" -n "%s (%s)" -u "%s" -p "%s" -a --disable-discovery', 
				$helperPath, 
				Plugins::Spotty::Plugin->cacheFolder(), 
				string('PLUGIN_SPOTTY_AUTH_NAME'),
				Slim::Utils::Misc::getLibraryName(),
				$paramRef->{'username'},
				$paramRef->{'password'},
			);
			
			my $response = `$command`;
			
			if ( !($response && $response =~ /authorized/) ) {
				$paramRef->{'warning'} = string('PLUGIN_SPOTTY_AUTH_FAILED');
			}
		}
		
		if ( !$needsRestart && $paramRef->{pref_enableBrowseMode} . '' ne $prefs->get('enableBrowseMode') . '' ) {
			$needsRestart = 1;
		}
	}
	
	if ( !$paramRef->{helperMissing} && !Plugins::Spotty::Plugin->hasCredentials() ) {
		if ( !main::ISWINDOWS && !$paramRef->{basicAuth} ) {
			$response->code(RC_MOVED_TEMPORARILY);
			$response->header('Location' => 'authentication.html');
			return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
		}
		else {
			$paramRef->{basicAuth} = 1;
		}
	}
	else {
		delete $paramRef->{basicAuth};
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::SettingsAuth->shutdown();
	
	$paramRef->{credentials} = Plugins::Spotty::Plugin->getCredentials();

	if ($needsRestart) {
		$paramRef = Slim::Web::Settings::Server::Plugins->getRestartMessage($paramRef, Slim::Utils::Strings::string("PLUGIN_EXTENSIONS_RESTART_MSG"));
		$paramRef = Slim::Web::Settings::Server::Plugins->restartServer($paramRef, $needsRestart);
	}
	
	return $class->SUPER::handler($client, $paramRef);
}


1;
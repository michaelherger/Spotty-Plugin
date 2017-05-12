package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

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
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/basic.html');
}

sub prefs {
	return ($prefs);
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;
	
	my $helperPath = $class->getHelper();
	
	# don't even continue if we're missing the helper application
	if ( !$helperPath ) {
		my $osDetails = Slim::Utils::OSDetect::details();
		
		# Windows should just work - except if the MSVC 2015 runtime was missing
		if (main::ISWINDOWS) {
			$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER_WINDOWS');
		}
		else {
			$paramRef->{helperMissing} = string('PLUGIN_SPOTTY_MISSING_HELPER', $osDetails->{'osName'} . ' / ' . ($osDetails->{'osArch'} ? $osDetails->{'osArch'} : 'unknown'));
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
	
	return $class->SUPER::handler($client, $paramRef);
}

# check whether the helper is available and executable
# it requires MSVC 2015 libraries
sub getHelper {
	my $helper = sprintf('%s -n "%s (%s)" --check', 
		Plugins::Spotty::Plugin->getHelper(),
		string('PLUGIN_SPOTTY_AUTH_NAME'),
		Slim::Utils::Misc::getLibraryName()
	);
	
	my $check = `$helper`;
	
	if ( $check && $check =~ /ok/i ) {
		return Plugins::Spotty::Plugin->getHelper();
	}
}


1;
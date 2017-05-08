package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

use File::Path qw(rmtree);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Plugins::Spotty::Plugin;
use Plugins::Spotty::SettingsAuth;

my $prefs = preferences('plugin.spotty');

sub new {
	my $class = shift;

	Plugins::Spotty::SettingsAuth->new();
	rmtree($class->cacheFolder(1));
	
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
				$class->cacheFolder($paramRef->{addAuthorization}), 
				string('PLUGIN_SPOTTY_AUTH_NAME'),
				preferences('server')->get('libraryname'),
				$paramRef->{'username'},
				$paramRef->{'password'},
			);
			
			my $response = `$command`;
			
			if ( !($response && $response =~ /authorized/) ) {
				$paramRef->{'warning'} = string('PLUGIN_SPOTTY_AUTH_FAILED');
			}
		}
	}
	
	# read new credentials if available
	if ( my $credentials = $class->getCredentials(1) ) {
		Plugins::Spotty::Plugin->addCredentials($credentials);
	}
	rmtree($class->cacheFolder(1));

	if ( !$paramRef->{helperMissing} && !$class->hasCredentials($paramRef->{addAuthorization}) ) {
		if ( !main::ISWINDOWS && !$paramRef->{basicAuth} ) {
			$response->code(RC_MOVED_TEMPORARILY);
			$response->header('Location' => 'authentication.html' . ($paramRef->{addAuthorization} ? '?addAuthorization=1' : ''));
			return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
		}
	}
	else {
		delete $paramRef->{basicAuth};
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::SettingsAuth->shutdown();
	
	$paramRef->{credentials} = $prefs->get('credentials');
	$paramRef->{canMultipleAccounts} = Slim::Utils::Versions->compareVersions($::VERSION, '7.9') >= 0 ? 1 : 0; 
	
	return $class->SUPER::handler($client, $paramRef);
}

# check whether the helper is available and executable
# it requires MSVC 2015 libraries
sub getHelper {
	my $helper = sprintf('%s -n "%s (%s)" --check', 
		Plugins::Spotty::Plugin->getHelper(),
		string('PLUGIN_SPOTTY_AUTH_NAME'),
		preferences('server')->get('libraryname')
	);
	
	my $check = `$helper`;
	
	if ( $check && $check =~ /ok/i ) {
		return Plugins::Spotty::Plugin->getHelper();
	}
}

sub cacheFolder {
	my ($class, $addAuthorization) = @_;
	return Plugins::Spotty::Plugin->cacheFolder($addAuthorization ? '_add_' : undef);
}

sub hasCredentials {
	my ($class, $addAuthorization) = @_;
	return Plugins::Spotty::Plugin->hasCredentials($addAuthorization ? '_add_' : undef);
}

sub getCredentials {
	my ($class, $addAuthorization) = @_;
	return Plugins::Spotty::Plugin->getCredentials($addAuthorization ? '_add_' : undef);
}

1;
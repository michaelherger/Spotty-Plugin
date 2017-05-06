package Plugins::Spotty::Settings;

use strict;
use base qw(Slim::Web::Settings);

use File::Spec::Functions qw(catfile);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);

use Slim::Utils::Prefs;
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
	
=pod
	my $helperPath = Slim::Utils::Misc::findbin(HELPER);
	
	# don't even continue if we're missing the helper application
	if ( !$helperPath ) {
		$paramRef->{helperMissing} = 1;
		return $class->SUPER::handler($client, $paramRef);
	}
=cut
		
	if ($paramRef->{'pref_resetAuthorization'}) {
		my $credentialsFile = Plugins::Spotty::Plugin->hasCredentials();
		unlink $credentialsFile;
	}

	if ($paramRef->{'saveSettings'}) {
		if ( $paramRef->{'username'} && $paramRef->{'password'} ) {
			if ( my $helperPath = Plugins::Spotty::Plugin->getHelperPath() ) {
				my $command = sprintf(
					'%s -c "%s" -n "%s" -u "%s" -p "%s" -a --disable-discovery', 
					$helperPath, 
					Plugins::Spotty::Plugin->cacheFolder, 
					Slim::Utils::Strings::string('PLUGIN_SPOTTY_AUTH_NAME'),
					$paramRef->{'username'},
					$paramRef->{'password'},
				);
				
				my $response = `$command`;
				
				if ( !($response && $response =~ /authorized/) ) {
					$paramRef->{'warning'} = Slim::Utils::Strings::string('PLUGIN_SPOTTY_AUTH_FAILED');
				}
			}
		}
	}

	if ( !Plugins::Spotty::Plugin->hasCredentials() ) {
		if ( !main::ISWINDOWS && !$paramRef->{basicAuth} ) {
			$response->code(RC_MOVED_TEMPORARILY);
			$response->header('Location' => 'authentication.html');
			return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
		}
	}
	else {
		delete $paramRef->{basicAuth};
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::SettingsAuth->shutdown();
	
	my $credentials = Plugins::Spotty::Plugin->getCredentials();
	$paramRef->{credentials} = $credentials;
	
	return $class->SUPER::handler($client, $paramRef);
}


1;
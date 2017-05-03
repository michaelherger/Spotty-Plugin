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
	return ($prefs, 'maxfilesize');
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;
	
	if ($paramRef->{'pref_resetAuthorization'}) {
		my $credentialsFile = Plugins::Spotty::Plugin->hasCredentials();
		unlink $credentialsFile;
	}

	if ( !Plugins::Spotty::Plugin->hasCredentials() ) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'authentication.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	# make sure our authentication helper isn't running
	Plugins::Spotty::SettingsAuth->shutdown();
	
	my $credentials = Plugins::Spotty::Plugin->getCredentials();
	$paramRef->{credentials} = $credentials;
	
	return $class->SUPER::handler($client, $paramRef);
}


1;
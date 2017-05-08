package Plugins::Spotty::SettingsAuth;

use strict;
use base qw(Slim::Web::Settings);

use File::Spec::Functions qw(catfile);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);
use JSON::XS::VersionOneAndTwo;
use Proc::Background;

use Slim::Utils::Prefs;
use Slim::Utils::Log;

use Plugins::Spotty::Plugin;

my $prefs = preferences('plugin.spotty');
my $log   = logger('plugin.spotty');
my $helper;

sub new {
	my $class = shift;

	Slim::Web::Pages->addPageFunction($class->page, $class);
	Slim::Web::Pages->addRawFunction("plugins/Spotty/settings/hasCredentials", \&checkCredentials);
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/authentication.html');
}

sub prefs {
	return ($prefs, 'maxfilesize');
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;

	if ( !$paramRef->{addAuthorization} && Plugins::Spotty::Plugin->hasCredentials() ) {
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'basic.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	if ( !$class->startHelper($paramRef->{addAuthorization}) ) {
		$paramRef->{helperMissing} = 1;
	}
	
	return $class->SUPER::handler($client, $paramRef);
}

# Some custom page handlers for advanced stuff

sub checkCredentials {
	my ($httpClient, $response, $func) = @_;

	my $addAuthorization = $response->request->uri->query_param('addAuthorization');
	my $result = {
		hasCredentials => Plugins::Spotty::Settings->hasCredentials($addAuthorization)
	};
	
	# make sure our authentication helper is running
	__PACKAGE__->startHelper($addAuthorization);
	
	my $content = to_json($result);
	$response->header( 'Content-Length' => length($content) );
	$response->code(200);
	$response->header('Connection' => 'close');
	$response->content_type('application/json');
	
	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$content	);
}

sub startHelper {
	my ($class, $addAuthorization) = @_;
	
	if ( my $helperPath = Plugins::Spotty::Plugin->getHelper() ) {
		if ( !($helper && $helper->alive) ) {
			my $command = sprintf('%s -c "%s" -n "%s (%s)" -a', 
				$helperPath, 
				Plugins::Spotty::Settings->cacheFolder($addAuthorization), 
				Slim::Utils::Strings::string('PLUGIN_SPOTTY_AUTH_NAME'),
				preferences('server')->get('libraryname'),
			);
			main::INFOLOG && $log->is_info && $log->info("Starting authentication deamon: $command");
			
			eval { 
				$helper = Proc::Background->new(
					{ 'die_upon_destroy' => 1 },
					$command 
				);
			};
	
			if ($@) {
				$log->warn($@);
			}
		}
	}

	return $helper && $helper->alive;
}

sub shutdown {
	my $class = shift;

	if ($helper && $helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("killing helper application");
		$helper->die;
	}
}


1;
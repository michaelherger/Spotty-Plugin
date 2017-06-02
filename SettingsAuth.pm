package Plugins::Spotty::SettingsAuth;

use strict;
use base qw(Slim::Web::Settings);

use File::Spec::Functions qw(catfile);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);
use JSON::XS::VersionOneAndTwo;
use Proc::Background;

use Slim::Utils::Prefs;
use Slim::Utils::Log;
use Slim::Utils::Strings qw(string);

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
	return ($prefs);
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;
	
	if ($paramRef->{'saveSettings'}) {
		if ( $paramRef->{'username'} && $paramRef->{'password'} && (my $helperPath = Plugins::Spotty::Plugin->getHelper()) ) {
			my $command = sprintf(
				'%s -c "%s" -n "%s (%s)" -u "%s" -p "%s" -a --disable-discovery', 
				$helperPath, 
				Plugins::Spotty::Plugin->cacheFolder($paramRef->{accountId}),
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

	if ( Plugins::Spotty::Plugin->hasCredentials($paramRef->{accountId}, 'no-fallback') ) {
		$class->shutdownHelper;

		Plugins::Spotty::Plugin->renameCacheFolder($paramRef->{accountId});
		
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'basic.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	if ( !$class->startHelper($paramRef->{accountId}) ) {
		$paramRef->{helperMissing} = Plugins::Spotty::Plugin->getHelper() || 1;
	}
	
	# discovery doesn't work on Windows
	$paramRef->{canDiscover} = main::ISWINDOWS ? 0 : 1;
	
	return $class->SUPER::handler($client, $paramRef);
}

# Some custom page handlers for advanced stuff

sub checkCredentials {
	my ($httpClient, $response, $func) = @_;

	my $request = $response->request;
	my $accountId = $request->uri->query_param('accountId');
	
	my $result = {
		hasCredentials => Plugins::Spotty::Plugin->hasCredentials($accountId, 'no-fallback')
	};
	
	# make sure our authentication helper is running
	__PACKAGE__->startHelper($accountId);
	
	my $content = to_json($result);
	$response->header( 'Content-Length' => length($content) );
	$response->code(200);
	$response->header('Connection' => 'close');
	$response->content_type('application/json');
	
	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$content	);
}

sub startHelper {
	my ($class, $accountId) = @_;
	
	# no need to restart if it's already there
	return $helper->alive if $helper && $helper->alive;

	if ( my $helperPath = Plugins::Spotty::Plugin->getHelper() ) {
		my $cacheFolder = Plugins::Spotty::Plugin->cacheFolder();
		$cacheFolder =~ s/default$/$accountId/; 
		
		if ( !($helper && $helper->alive) ) {
			my $command = sprintf('%s -c "%s" -n "%s (%s)" -a', 
				$helperPath, 
				$cacheFolder, 
				Slim::Utils::Strings::string('PLUGIN_SPOTTY_AUTH_NAME'),
				Slim::Utils::Misc::getLibraryName(),
			);
			main::INFOLOG && $log->is_info && $log->info("Starting authentication deamon: $command");
			
			eval { 
				$helper = Proc::Background->new(
					{ 'die_upon_destroy' => 1 },
					$command 
				);
			};
	
			if ($@) {
				$log->warn("Failed to launch the authentication deamon: $@");
			}
		}
	}

	return $helper && $helper->alive;
}

sub shutdownHelper {
	my $class = shift;

	if ($helper && $helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting authentication daemon");
		$helper->die;
	}
}


1;
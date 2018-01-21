package Plugins::Spotty::SettingsAuth;

use strict;
use base qw(Slim::Web::Settings);

use File::Path qw(mkpath);
use File::Spec::Functions qw(catdir);
use HTTP::Status qw(RC_MOVED_TEMPORARILY);
use JSON::XS::VersionOneAndTwo;
use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);
use Slim::Utils::Timers;

use Plugins::Spotty::Plugin;

use constant AUTHENTICATE => '__AUTHENTICATE__';
use constant HELPER_TIMEOUT => 60*15;		# kill the helper application after 15 minutes

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
				$class->_cacheFolder(),
				string('PLUGIN_SPOTTY_AUTH_NAME'),
				Slim::Utils::Misc::getLibraryName(),
				$paramRef->{'username'},
				$paramRef->{'password'},
			);
			
			if (main::INFOLOG && $log->is_info) {
				my $logCmd = $command;
				$logCmd =~ s/$paramRef->{password}/\*\*\*\*\*\*\*\*/g;
				$log->info("Trying to authenticate using: $logCmd");	
			}
			
			my $response = `$command`;
			
			if ( !($response && $response =~ /authorized/) ) {
				$paramRef->{'warning'} = string('PLUGIN_SPOTTY_AUTH_FAILED');
				$log->warn($paramRef->{'warning'} . string('COLON') . " $response");
			}
		}
	}

	if ( Plugins::Spotty::Plugin->hasCredentials(AUTHENTICATE) ) {
		$class->shutdownHelper;

		$class->cleanup();
		Plugins::Spotty::Plugin->getName($client, $paramRef->{username});
		
		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'basic.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	if ( !$class->startHelper() ) {
		$paramRef->{helperMissing} = Plugins::Spotty::Plugin->getHelper() || 1;
	}
	
	# discovery doesn't work on Windows
	$paramRef->{canDiscovery} = Plugins::Spotty::Plugin->canDiscovery();
	
	return $class->SUPER::handler($client, $paramRef);
}

# Some custom page handlers for advanced stuff

# check whether we have credentials - called by the web page to decide if it can return
sub checkCredentials {
	my ($httpClient, $response, $func) = @_;

	my $request = $response->request;
	
	my $result = {
		hasCredentials => Plugins::Spotty::Plugin->hasCredentials(AUTHENTICATE)
	};
	
	# make sure our authentication helper is running
	__PACKAGE__->startHelper();
	
	my $content = to_json($result);
	$response->header( 'Content-Length' => length($content) );
	$response->code(200);
	$response->header('Connection' => 'close');
	$response->content_type('application/json');
	
	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$content	);
}

sub startHelper {
	my ($class) = @_;
	
	# no need to restart if it's already there
	return $helper->alive if $helper && $helper->alive;

	if ( my $helperPath = Plugins::Spotty::Plugin->getHelper() ) {
		if ( !($helper && $helper->alive) ) {
			my $command = sprintf('%s -c "%s" -n "%s (%s)" -a', 
				$helperPath, 
				$class->_cacheFolder(), 
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

			Slim::Utils::Timers::killTimers(undef, \&shutdownHelper);
			Slim::Utils::Timers::setTimer(undef, Time::HiRes::time() + HELPER_TIMEOUT, \&shutdownHelper);
	
			if ($@) {
				$log->warn("Failed to launch the authentication deamon: $@");
			}
		}
	}

	return $helper && $helper->alive;
}

sub cleanup {
	Plugins::Spotty::Plugin->renameCacheFolder(AUTHENTICATE);
	Plugins::Spotty::Plugin->deleteCacheFolder(AUTHENTICATE);
}

sub shutdownHelper {
	if ($helper && $helper->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting authentication daemon");
		$helper->die;
	}
	
	cleanup();
}

sub _cacheFolder {
	my $cacheFolder = catdir(preferences('server')->get('cachedir'), 'spotty', AUTHENTICATE);
	mkpath $cacheFolder unless -f $cacheFolder;
	return $cacheFolder;
}

1;
package Plugins::Spotty::Settings::Auth;

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
use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::Settings::Callback;

use constant AUTHENTICATE => '__AUTHENTICATE__';
use constant HELPER_TIMEOUT => 60*15;		# kill the helper application after 15 minutes

my $prefs = preferences('plugin.spotty');
my $log   = logger('plugin.spotty');

sub new {
	my $class = shift;

	Slim::Web::Pages->addPageFunction($class->page, $class);
	Slim::Web::Pages->addRawFunction("plugins/Spotty/settings/hasCredentials", \&checkCredentials);
	Plugins::Spotty::Settings::Callback->init();
}

sub name {
	return Slim::Web::HTTP::CSRF->protectName('PLUGIN_SPOTTY');
}

sub page {
	return Slim::Web::HTTP::CSRF->protectURI('plugins/Spotty/settings/authentication.html');
}

sub prefs {
	return ($prefs, 'helper');
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;

	my ($helperPath, $helperVersion) = Plugins::Spotty::Helper->get();

	# TODO - is this legacy from when we entered username/password?
	# if ( Plugins::Spotty::AccountHelper->hasCredentials(AUTHENTICATE) ) {
	# 	$class->cleanup();
	# 	Plugins::Spotty::AccountHelper->getName($client, $paramRef->{username});

	# 	$response->code(RC_MOVED_TEMPORARILY);
	# 	$response->header('Location' => 'basic.html');
	# 	return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	# }

	$paramRef->{authUrl} = Plugins::Spotty::Settings::Callback->getAuthURL();
	$paramRef->{callbackUrl} = Plugins::Spotty::Settings::Callback->getCallbackUrl();

	my $osDetails = Slim::Utils::OSDetect::details();
	$paramRef->{isDocker} = $osDetails->{osName} && $osDetails->{osName} =~ /Docker/;

	return $class->SUPER::handler($client, $paramRef);
}

# Some custom page handlers for advanced stuff

# check whether we have credentials - called by the web page to decide if it can return
sub checkCredentials {
	my ($httpClient, $response, $func) = @_;

	my $request = $response->request;

	my $result = {
		hasCredentials => Plugins::Spotty::AccountHelper->hasCredentials(AUTHENTICATE)
	};

	my $content = to_json($result);
	$response->header( 'Content-Length' => length($content) );
	$response->code(200);
	$response->header('Connection' => 'close');
	$response->content_type('application/json');

	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$content );
}

sub cleanup {
	Plugins::Spotty::AccountHelper->renameCacheFolder(AUTHENTICATE);
	Plugins::Spotty::AccountHelper->deleteCacheFolder(AUTHENTICATE);
}

sub _cacheFolder {
	my $cacheFolder = catdir(preferences('server')->get('cachedir'), 'spotty', AUTHENTICATE);
	mkpath $cacheFolder unless -f $cacheFolder;
	return $cacheFolder;
}

1;
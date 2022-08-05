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
	return ($prefs, 'helper');
}

sub handler {
	my ($class, $client, $paramRef, $pageSetup, $httpClient, $response) = @_;

	my ($helperPath, $helperVersion) = Plugins::Spotty::Helper->get();

	if ($paramRef->{'saveSettings'}) {
		if ( $paramRef->{'username'} && $paramRef->{'password'} && $helperPath ) {
			my $command = sprintf(
				'"%s" -c "%s" -n "%s (%s)" -u "%s" -p "%s" -a --disable-discovery %s',
				$helperPath,
				$class->_cacheFolder(),
				string('PLUGIN_SPOTTY_AUTH_NAME'),
				Slim::Utils::Misc::getLibraryName(),
				$paramRef->{'username'},
				$paramRef->{'password'},
				# always use fallback (if possible), as the user has no way to force this at this point yet if needed
				Plugins::Spotty::Helper->getCapability('no-ap-port') ? '' : '--ap-port 12321',
			);

			if (main::INFOLOG && $log->is_info) {
				$command .= ' --verbose';
				my $logCmd = $command;
				$logCmd =~ s/-p ".*?"/-p "\*\*\*\*\*\*\*\*"/g;
				$log->info("Trying to authenticate using: $logCmd");
			}

			my $response = `$command`;

			main::INFOLOG && $log->is_info && $log->info("Got response: $response");

			if ( !($response && $response =~ /authorized/s) ) {
				$paramRef->{'warning'} = string('PLUGIN_SPOTTY_AUTH_FAILED');

				if ($response =~ /panicked at '(.*?)'/i) {
					$paramRef->{'warning'} .= string('COLON') . " $1";
				}

				$log->warn($paramRef->{'warning'} . string('COLON') . " $response");
			}
		}
	}

	if ( Plugins::Spotty::AccountHelper->hasCredentials(AUTHENTICATE) ) {
		$class->shutdownHelper;

		$class->cleanup();
		Plugins::Spotty::AccountHelper->getName($client, $paramRef->{username});

		$response->code(RC_MOVED_TEMPORARILY);
		$response->header('Location' => 'basic.html');
		return Slim::Web::HTTP::filltemplatefile($class->page, $paramRef);
	}

	if ( !$class->startHelper() ) {
		$paramRef->{helperMissing} = $helperPath || 1;
	}

	my $helpers = Plugins::Spotty::Helper->getAll();

	if ($helpers && scalar keys %$helpers > 1) {
		$paramRef->{helpers} = $helpers;
	}

	$paramRef->{helperPath}     = $helperPath;
	$paramRef->{helperVersion}  = $helperVersion ? "v$helperVersion" : string('PLUGIN_SPOTTY_HELPER_ERROR');

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
		hasCredentials => Plugins::Spotty::AccountHelper->hasCredentials(AUTHENTICATE)
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

	if ( my $helperPath = Plugins::Spotty::Helper->get() ) {
		if ( !($helper && $helper->alive) ) {
			my @helperArgs = (
				'-c', $class->_cacheFolder(),
				'-n', sprintf("%s (%s)", Slim::Utils::Strings::string('PLUGIN_SPOTTY_AUTH_NAME'), Slim::Utils::Misc::getLibraryName()),
				'-a'
			);

			# always use fallback (if possible), as the user has no way to force this at this point yet if needed
			if (!Plugins::Spotty::Helper->getCapability('no-ap-port')) {
				push @helperArgs, '--ap-port=12321';
			}

			if (main::INFOLOG && $log->is_info) {
				push @helperArgs, '--verbose' if Plugins::Spotty::Helper->getCapability('debug');
				$log->info("Starting Spotty Connect deamon: \n$helperPath " . join(' ', @helperArgs));
			}

			eval {
				$helper = Proc::Background->new(
					{ 'die_upon_destroy' => 1 },
					$helperPath,
					@helperArgs
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
	Plugins::Spotty::AccountHelper->renameCacheFolder(AUTHENTICATE);
	Plugins::Spotty::AccountHelper->deleteCacheFolder(AUTHENTICATE);
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
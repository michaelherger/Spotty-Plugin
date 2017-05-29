package Plugins::Spotty::Plugin;

use strict;

#use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);
use File::Basename;
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Spotty::ProtocolHandler;
use Plugins::Spotty::API;

use constant HELPER => 'spotty';

# TODO - add init call to disable spt-flc transcoding by default (see S::W::S::S::FileTypes)
my $prefs = preferences('plugin.spotty');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.spotty',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_SPOTTY',
} );

my $helper;

sub initPlugin {
	my $class = shift;
	
	$prefs->init({
		country => 'US',
		ohmy => '93aac68fb06348598c1e67734dfaceee'
	});

	$VERSION = $class->_pluginDataFor('version');
	Slim::Player::ProtocolHandlers->registerHandler('spotty', 'Plugins::Spotty::ProtocolHandler');

# TODO - needs to be renamed, as "spotty" is being used by OPMLBased
#                                                                |requires Client
#                                                                |  |is a Query
#                                                                |  |  |has Tags
#                                                                |  |  |  |Function to call
#                                                                C  Q  T  F
	Slim::Control::Request::addDispatch(['spotty'],
	                                                            [1, 0, 0, sub {
																	my $request = shift;
																	my $client = $request->client();
																	
																	# check buffer usage - no need to skip if buffer is empty
																	my $usage = $client->usage;
													
																	if ( $usage && $client->can('skipAhead') ) {
																		Slim::Utils::Timers::killTimers($client, \&_skipAhead);
																		Slim::Utils::Timers::setHighTimer($client, Time::HiRes::time() + 1, \&_skipAhead, $usage);
																	}

																	$request->setStatusDone();
	                                                            }]);

	if (main::WEBUI) {
		require Plugins::Spotty::Settings;
		require Plugins::Spotty::SettingsAuth;
		Plugins::Spotty::Settings->new();
	}
	
	if ( $class->isa('Slim::Plugin::OPMLBased') ) {
		require Plugins::Spotty::OPML;
		$class->SUPER::initPlugin(
			feed   => \&Plugins::Spotty::OPML::handleFeed,
			tag    => 'spotty',
			menu   => 'radios',
			is_app => 1,
			weight => 1,
		);
	}

	if ( Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') < 0 ) {
		$log->error('Please update to Logitech Media Server 7.9.1 if you want to use seeking in Spotify tracks.');
	}
}

sub getDisplayName { 'PLUGIN_SPOTTY_NAME' }

# don't add this plugin to the Extras menu
sub playerMenu {}

sub _skipAhead {
	my ($client, $usage) = @_;
	$client->execute(["mixer", "muting", 1]);
	my $bitrate = $client->streamingSong()->streambitrate();
	#my $bufferSize = $client->bufferSize;		# bytes?
	my $delta = $client->bufferSize * 8 / $bitrate * $usage * 2;
																		
#	warn Data::Dump::dump($bitrate, $client->bufferSize, $usage, $delta);
	$client->skipAhead($delta);
	$client->execute(["mixer", "muting", 0]);
}

sub postinitPlugin {
	my $class = shift;

	# we're going to hijack the Spotify URI schema
	Slim::Player::ProtocolHandlers->registerHandler('spotify', 'Plugins::Spotty::ProtocolHandler');

	# modify the transcoding helper table to inject our cache folder
	my $cacheDir = $class->cacheFolder();
	my $flushBuffer = Slim::Utils::Misc::findbin('flushbuffers') || '';
	my $serverPort = preferences('server')->get('httpport');
	
	my $helper = $class->getHelper();
	$helper = basename($helper) if $helper;
	$helper = '' if $helper eq 'spotty';

	foreach ( keys %Slim::Player::TranscodingHelper::commandTable ) {
		if ( $_ =~ /^spt-/ && $Slim::Player::TranscodingHelper::commandTable{$_} =~ /single-track/ ) {
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$CACHE\$/$cacheDir/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\[spotty\]/\[$helper\]/g if $helper;
		}

		if ( $flushBuffer && $_ =~ /^sptc-/ ) {
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$FLUSHBUFFERS\$/$flushBuffer/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$SERVERPORT\$/$serverPort/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\[spotty\]/\[$helper\]/g if $helper;
		}
	}
}

sub _pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		return $pluginData->{$key};
	}

	return undef;
}

sub getAPIHandler {
	my ($class, $client) = @_;
	
	my $api = $client->pluginData('api');
		
	if ( !$api ) {
		$api = $client->pluginData( api => Plugins::Spotty::API->new({
			client => $client,
			username => $prefs->client($client)->get('username'),
		}) );
	}
	
	return $api;
}

sub cacheFolder {
	my ($class, $client) = @_;
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty');
	
	if ( $client && (my $username = $prefs->client($client)->get('username')) ) {
		$cacheDir = catdir($cacheDir, $username);
	}

	mkdir $cacheDir unless -d $cacheDir;

	return $cacheDir;
}

sub hasCredentials {
	my $credentialsFile = catfile($_[0]->cacheFolder(), 'credentials.json');
	return -f $credentialsFile ? $credentialsFile : '';
}

sub getCredentials {
	if ( my $credentialsFile = $_[0]->hasCredentials() ) {
		my $credentials = eval {
			from_json(read_file($credentialsFile));
		};
		
		return $credentials || {};
	}
}

sub getHelper {
	my ($class) = @_;

	if (!$helper) {
		my @candidates = (HELPER);
		
		# trying to find the correct binary can be tricky... some ARM platforms behave oddly.
		# do some trial-and-error testing to see what we can use
		if (Slim::Utils::OSDetect::OS() eq 'unix') {
			# on 64 bit try 64 bit builds first
			if ( $Config::Config{'archname'} =~ /x86_64/ ) {
				unshift @candidates, HELPER . '-x86_64';
			}

			# on armhf use hf binaries instead of default arm5te binaries
			elsif ( $Config::Config{'archname'} =~ /arm.*linux/ ) {
				unshift @candidates, HELPER . '-muslhf', HELPER . '-hf';
			}
		}

		# try spotty-custom first, allowing users to drop their own build anywhere
		unshift @candidates, HELPER . '-custom';
		
		foreach my $binary (@candidates) {
			my $candidate = Slim::Utils::Misc::findbin($binary) || next;
			
			$candidate = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($candidate);

			next unless -f $candidate && -x $candidate;

			main::INFOLOG && $log->is_info && $log->info("Trying helper applicaton: $candidate");
			
			my $checkCmd = sprintf('%s -n "%s (%s)" --check', 
				$candidate,
				string('PLUGIN_SPOTTY_AUTH_NAME'),
				Slim::Utils::Misc::getLibraryName()
			);
			
			my $check = `$checkCmd`;
			
			if ( $check && $check =~ /ok/i ) {
				$helper = $candidate;
				last;
			}
		}

		main::INFOLOG && $log->is_info && $helper && $log->info("Found Spotty helper application: $helper");
		$log->warn("Didn't find Spotty helper application!") unless $helper;	
	}	

	return $helper;
}


sub shutdownPlugin {
	# make sure we don't leave our helper app running
	if (main::WEBUI) {
		Plugins::Spotty::SettingsAuth->shutdown();
	}
}

1;

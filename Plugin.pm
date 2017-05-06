package Plugins::Spotty::Plugin;

use strict;

use vars qw($VERSION);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use Plugins::Spotty::ProtocolHandler;

use constant HELPER => 'spotty';

# TODO - add init call to disable spt-flc transcoding by default (see S::W::S::S::FileTypes)
my $prefs = preferences('plugin.spotty');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.spotty',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_SPOTTY',
} );

my $helperPath;

sub initPlugin {
	my $class = shift;

	$VERSION = $class->pluginDataFor('version');
	Slim::Player::ProtocolHandlers->registerHandler('spotty', 'Plugins::Spotty::ProtocolHandler');

	if (main::WEBUI) {
		require Plugins::Spotty::Settings;
		require Plugins::Spotty::SettingsAuth;
		Plugins::Spotty::Settings->new();
	}
}

sub postinitPlugin {
	my $class = shift;

	# we're going to hijack the Spotify URI schema
	Slim::Player::ProtocolHandlers->registerHandler('spotify', 'Plugins::Spotty::ProtocolHandler');

	# modify the transcoding helper table to inject our cache folder
	my $cacheDir = $class->cacheFolder();
	my $namePlaceholder = string('PLUGIN_SPOTTY_TRANSCODING_NAME');

	# LMS older than 7.9 can't use the player name in the transcoding
	if ( Slim::Utils::Versions::compareVersions($::VERSION, '7.9') < 0 ) {
		$namePlaceholder =~ s/\$(?:NAME|CLIENTID)\$/\$FILE\$/g;
	}

	foreach ( keys %Slim::Player::TranscodingHelper::commandTable ) {
		if ($_ =~ /^spt-/ && $Slim::Player::TranscodingHelper::commandTable{$_} =~ /single-track/) {
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$CACHE\$/$cacheDir/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$NAME\$/$namePlaceholder/g;
		}
	}
}

sub pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		return $pluginData->{$key};
	}

	return undef;
}

sub cacheFolder {
	my ($class, $client) = @_;
	
	my $id;
	
	if ($client) {
		$id = lc($client->id());
		$id =~ s/://g;
	}
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty');
	mkdir $cacheDir unless -d $cacheDir;

	return $cacheDir;
}

sub hasCredentials {
	my $credentialsFile = catfile($_[0]->cacheFolder(), 'credentials.json');
	return -f $credentialsFile ? $credentialsFile : '';
}

sub getCredentials {
	my ($class, $client) = @_;
	if ( my $credentialsFile = $class->hasCredentials() ) {
		my $credentials = eval {
			from_json(read_file($credentialsFile));
		};
		
		return $credentials || {};
	}
}

sub getHelperPath {
	my ($class) = @_;

	if (!$helperPath) {
		$helperPath = Slim::Utils::Misc::findbin(HELPER);
		$helperPath &&= Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($helperPath);
	}	
	
	return $helperPath;
}


sub shutdownPlugin {
	# make sure we don't leave our helper app running
	if (main::WEBUI) {
		Plugins::Spotty::SettingsAuth->shutdown();
	}
}

1;
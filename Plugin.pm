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
	
	$prefs->init({
		credentials => $class->parseCredentialFiles()
	});

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
	my $namePlaceholder = '$CLIENTID$';

	# LMS older than 7.9 can't use the player name in the transcoding
	if ( Slim::Utils::Versions->compareVersions($::VERSION, '7.9') < 0 ) {
		$namePlaceholder = '$FILE$';
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
	my ($class, $subfolder) = @_;
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty', $subfolder);
	mkdir $cacheDir unless -d $cacheDir;

	return $cacheDir;
}

sub addCredentials {
	my ($class, $credentials) = @_;
	
	my @credentials = @{$prefs->get('credentials')};
	
	push @credentials, $credentials;
	
	my %seen;
	@credentials = grep {
		!$seen{$_->{username}}++
	} @credentials;
	
	$prefs->set('credentials', \@credentials);
}

sub hasCredentials {
	my ($class, $subfolder) = @_;
	
	my $credentialsFile = catfile($class->cacheFolder($subfolder), 'credentials.json');
	return -f $credentialsFile ? $credentialsFile : '';
}

sub getCredentials {
	my ($class, $subfolder) = @_;
	if ( my $credentialsFile = $class->hasCredentials($subfolder) ) {
		my $credentials = eval {
			from_json(read_file($credentialsFile));
		};
		
		return $credentials || {};
	}
}

sub getHelper {
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

sub parseCredentialFiles {
	my $class = shift;
	
	require File::Next;
	
	# update list of stored credentials
	my $credentialFiles = File::Next::files( { file_filter => sub { /credentials.json$/ } }, $class->cacheFolder() );
	$prefs->set('credentials', []) unless $prefs->get('credentials');

	while ( defined ( my $file = $credentialFiles->() ) ) {
		eval {
			$class->addCredentials( from_json(read_file($file)) );
		};
	}
}

1;
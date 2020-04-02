package Plugins::Spotty::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use File::Basename;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::API;
use Plugins::Spotty::Connect;
use Plugins::Spotty::Helper;
use Plugins::Spotty::OPML;
use Plugins::Spotty::ProtocolHandler;

use constant CAN_IMPORTER => (Slim::Utils::Versions->compareVersions($::VERSION, '8.0.0') >= 0);

my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.spotty',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_SPOTTY',
} );


sub initPlugin {
	my $class = shift;

	if ( !main::TRANSCODING ) {
		$log->error('You need to enable transcoding in order for Spotty to work');
		return;
	}

	if ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		$log->error(string('PLUGIN_SPOTTY_MISSING_SSL'));
	}

	# some debug code, dumping all locally stored files for further analysis
	# my $files = Plugins::Spotty::PlaylistFolders->findAllCachedFiles();
	# warn Data::Dump::dump($files);
	# foreach my $candidate ( @$files ) {
	# 	next unless $candidate =~ /51d3f5cfc935f7a059410f7b2ba206498815075a.file/;
	# 	my $data = Plugins::Spotty::PlaylistFolders::parse($candidate);
	# 	warn Data::Dump::dump($data, $candidate);
	# }

	$prefs->init({
		country => 'US',
		bitrate => 320,
		iconCode => \&_initIcon,
		tracksSincePurge => 0,
		accountSwitcherMenu => 0,
		disableDiscovery => 0,
		checkDaemonConnected => 0,
		displayNames => {},
		helper => '',
	});

	$prefs->setValidate({ 'validator' => sub { $_[1] =~ /^[a-f0-9]{32}$/i } }, 'iconCode');

	# disable spt-flc transcoding on non-x86 platforms - don't transcode unless needed
	# this might be premature optimization, as ARM CPUs are getting more and more powerful...
	if ( !main::ISWINDOWS && !main::ISMAC
		&& Slim::Utils::OSDetect::details()->{osArch} !~ /(?:i[3-6]|x)86/i
	) {
		$prefs->migrate(1, sub {
			my $disabledFormats = $serverPrefs->get('disabledformats');

			if (!grep /^spt/, @$disabledFormats) {
				# ugly... but there's no API to disable formats
				push @$disabledFormats, "spt-flc-*-*";
				$serverPrefs->set('disabledformats', $disabledFormats);
			}

			return 1;
		});
	}

	# we probably turned this on for too many users - let's start over
	$prefs->migrate(2, sub {
		$prefs->set('checkDaemonConnected', 0);
		return 1;
	});

	Plugins::Spotty::Helper->init();

	$VERSION = $class->_pluginDataFor('version');
	Slim::Player::ProtocolHandlers->registerHandler('spotify', 'Plugins::Spotty::ProtocolHandler');

	if (main::WEBUI) {
		require Plugins::Spotty::Settings;
		Plugins::Spotty::Settings->new();
	}

	$class->SUPER::initPlugin(
		feed   => \&Plugins::Spotty::OPML::handleFeed,
		tag    => 'spotty',
		menu   => 'radios',
		is_app => 1,
		weight => 1,
	);

	if ( Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') < 0 ) {
		$log->error('Please update to Logitech Media Server 7.9.1 if you want to use seeking in Spotify tracks.');
	}

	if (CAN_IMPORTER) {
		# tell LMS that we need to run the external scanner
		Slim::Music::Import->addImporter('Plugins::Spotty::Importer', { use => 1 });
	}

	Plugins::Spotty::AccountHelper->purgeCache('init');
	Plugins::Spotty::AccountHelper->purgeAudioCache(1);
	Plugins::Spotty::AccountHelper->getAllCredentials();
}

sub postinitPlugin { if (main::TRANSCODING) {
	my $class = shift;

	Plugins::Spotty::OPML->init();

	# we're going to hijack the Spotify URI schema
	Slim::Player::ProtocolHandlers->registerHandler('spotify', 'Plugins::Spotty::ProtocolHandler');

	Plugins::Spotty::Connect->init();

	# if user has the Don't Stop The Music plugin enabled, register ourselves
	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::DontStopTheMusic::Plugin')
		&& Slim::Utils::Versions->compareVersions($::VERSION, '7.9.0') >= 0 )
	{
		require Plugins::Spotty::DontStopTheMusic;
		Plugins::Spotty::DontStopTheMusic->init();
	}

	# add support for LastMix - if it's installed
	if ( Slim::Utils::PluginManager->isEnabled('Plugins::LastMix::Plugin') ) {
		eval {
			require Plugins::LastMix::Services;
		};

		if (!$@) {
			main::INFOLOG && $log->info("LastMix plugin is available - let's use it!");
			require Plugins::Spotty::LastMix;
			Plugins::LastMix::Services->registerHandler('Plugins::Spotty::LastMix');
		}
	}

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		Slim::Plugin::OnlineLibrary::Plugin->addLibraryIconProvider('spotify', '/plugins/Spotty/html/images/icon.png');
	}

	if ( main::WEBUI && Plugins::Spotty::AccountHelper->getTmpDir() ) {
		# LMS Settings/File Types is expecting the conversion table entry to start with "[..]".
		# If we've added a TMPDIR=... prefix, we'll need to remove it for the settings to work.
		my $handler = Slim::Web::Pages->getPageFunction(Slim::Web::Settings::Server::FileTypes->page);

		if ( $handler && !ref $handler && $handler eq 'Slim::Web::Settings::Server::FileTypes' ) {

			# override the default page handler to remove the TMPDIR prefix
			Slim::Web::Pages->addPageFunction(Slim::Web::Settings::Server::FileTypes->page, sub {
				my $commandTable = Slim::Player::TranscodingHelper::Conversions();
				foreach ( keys %$commandTable ) {
					if ( $_ =~ /^spt-/ && $commandTable->{$_} =~ /single-track/ ) {
						$commandTable->{$_} =~ s/^[^\[]+//;
					}
				}

				return $handler->handler(@_);
			});
		}
	}

	$class->updateTranscodingTable();
} }

sub onlineLibraryNeedsUpdate {
	if (CAN_IMPORTER) {
		my $class = shift;
		require Plugins::Spotty::Importer;
		return Plugins::Spotty::Importer->needsUpdate(@_);
	}
	else {
		$log->warn('The library importer feature requires at least Logitech Media Server 8');
	}

	my $cb = $_[1];
	$cb->() if $cb && ref $cb && ref $cb eq 'CODE';
}

sub updateTranscodingTable {
	my $class = shift || __PACKAGE__;
	my $client = shift;

	# see whether we want to have a specific player's account
	my $id = Plugins::Spotty::AccountHelper->getAccount($client);

	# modify the transcoding helper table to inject our cache folder
	my $cacheDir = Plugins::Spotty::AccountHelper->cacheFolder($id);

	my $bitrate = '';
	my ($helper, $helperVersion) = Plugins::Spotty::Helper->get();
	if ( Slim::Utils::Versions->checkVersion($helperVersion, '0.8.0', 10) ) {
		$bitrate = sprintf('--bitrate %s', $prefs->get('bitrate') || 320);
	}

	$helper = basename($helper) if $helper;

	my $tmpDir = Plugins::Spotty::AccountHelper->getTmpDir();
	if ($tmpDir) {
		$tmpDir = "TMPDIR=$tmpDir";
	}

	# default volume normalization to whatever the user chose for his player in LMS
	if ($client && !defined $prefs->client($client)->get('replaygain')) {
		$prefs->client($client)->set('replaygain', $serverPrefs->client($client)->get('replayGainMode'));
	}

	my $commandTable = Slim::Player::TranscodingHelper::Conversions();
	foreach ( keys %$commandTable ) {
		if ( $_ =~ /^spt-/ && $commandTable->{$_} =~ /single-track/ ) {
			$commandTable->{$_} =~ s/-c ".*?"/-c "$cacheDir"/g;
			$commandTable->{$_} =~ s/(\[spotty\])/$tmpDir $1/g if $tmpDir;
			$commandTable->{$_} =~ s/^[^\[]+// if !$tmpDir;
			$commandTable->{$_} =~ s/--bitrate \d{2,3}/$bitrate/;
			$commandTable->{$_} =~ s/\[spotty\]/\[$helper\]/g if $helper;
			$commandTable->{$_} =~ s/\[spotty-ogg\]/\[$helper\]/g if $helper && Plugins::Spotty::Helper->getCapability('ogg-direct');
			$commandTable->{$_} =~ s/enable-audio-cache/disable-audio-cache/g;
			$commandTable->{$_} =~ s/ --enable-volume-normalisation //;
			$commandTable->{$_} =~ s/( -n )/ --enable-volume-normalisation $1/ if Plugins::Spotty::Helper->getCapability('volume-normalisation') && $client && $prefs->client($client)->get('replaygain');
		}
	}
}

sub getDisplayName { 'PLUGIN_SPOTTY_NAME' }

# don't add this plugin to the Extras menu
sub playerMenu {}

sub _pluginDataFor {
	my $class = shift;
	my $key   = shift;

	my $pluginData = Slim::Utils::PluginManager->dataForPlugin($class);

	if ($pluginData && ref($pluginData) && $pluginData->{$key}) {
		return $pluginData->{$key};
	}

	return undef;
}

sub _initIcon {
	__PACKAGE__->_pluginDataFor('icon') =~ m|.*/(.*?)\.| && return $1;
}

sub hasDefaultIcon {
	$prefs->get('iconCode') eq _initIcon() ? 1 : 0;
}

sub getAPIHandler {
	my ($class, $client) = @_;

	return unless $client;

	my $api = $client->pluginData('api');

	if ( !$api ) {
		$api = $client->pluginData( api => Plugins::Spotty::API->new({
			client => $client,
		}) ) if Plugins::Spotty::AccountHelper->getAccount($client);
	}

	return $api;
}

sub canDiscovery { 1 }

# we only run when transcoding is enabled, but shutdown would be called no matter what
sub shutdownPlugin { if (main::TRANSCODING) {
	# make sure we don't leave our helper app running
	if (main::WEBUI) {
		Plugins::Spotty::Settings::Auth->shutdownHelper();
	}

	Plugins::Spotty::Connect->shutdown();
} }

1;

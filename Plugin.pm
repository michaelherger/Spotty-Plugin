package Plugins::Spotty::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Path qw(rmtree);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile tmpdir);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Spotty::API;
use Plugins::Spotty::Connect;
use Plugins::Spotty::Helper;
use Plugins::Spotty::OPML;
use Plugins::Spotty::ProtocolHandler;

use constant CACHE_PURGE_INTERVAL => 86400;
use constant CACHE_PURGE_MAX_AGE => 60 * 60;
use constant CACHE_PURGE_INTERVAL_COUNT => 15;

my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');
my $credsCache;

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

	Plugins::Spotty::OPML->init();

	if ( Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') < 0 ) {
		$log->error('Please update to Logitech Media Server 7.9.1 if you want to use seeking in Spotify tracks.');
	}

	$class->purgeCache('init');
	$class->purgeAudioCache(1);
}

sub postinitPlugin { if (main::TRANSCODING) {
	my $class = shift;

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

	if ( main::WEBUI && $class->getTmpDir() ) {
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

sub updateTranscodingTable {
	my $class = shift || __PACKAGE__;
	my $client = shift;

	# see whether we want to have a specific player's account
	my $id = $class->getAccount($client);

	# modify the transcoding helper table to inject our cache folder
	my $cacheDir = $class->cacheFolder($id);

	my $bitrate = '';
	my ($helper, $helperVersion) = Plugins::Spotty::Helper->get();
	if ( Slim::Utils::Versions->checkVersion($helperVersion, '0.8.0', 10) ) {
		$bitrate = sprintf('--bitrate %s', $prefs->get('bitrate') || 320);
	}

	$helper = basename($helper) if $helper;

	my $tmpDir = $class->getTmpDir();
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

sub getTmpDir {
	if ( !main::ISWINDOWS && !main::ISMAC ) {
		return catdir($serverPrefs->get('cachedir'), 'spotty');
	}
	return '';
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
		}) ) if $class->getAccount($client);
	}

	return $api;
}

sub canDiscovery { 1 }

sub setAccount {
	my ($class, $client, $id) = @_;

	return unless $client;

	if ( $id && $class->cacheFolder($id) ) {
		$prefs->client($client)->set('account', $id);
	}
	else {
		$prefs->client($client)->remove('account');
	}

	$client->pluginData( api => '' );
}

sub getAccount {
	my ($class, $client) = @_;

	return unless $client;

	if (!blessed $client) {
		$client = Slim::Player::Client::getClient($client);
	}

	my $id = $prefs->client($client)->get('account');

	if ( !$id || !$class->hasCredentials($id) ) {
		if ( ($id) = values %{$class->getAllCredentials()} ) {
			$prefs->client($client)->set('account', $id);
		}
		# this should hopefully never happen...
		else {
			$prefs->client($client)->remove('account');
			$id = undef;
		}

		$client->pluginData( api => '' );
	}

	return $id;
}

sub cacheFolder {
	my ($class, $id) = @_;

	$id ||= '';
	my $cacheDir = catdir($serverPrefs->get('cachedir'), 'spotty', $id);

	# if no $id was given, let's pick the first one
	if (!$id) {
		foreach ( @{$class->cacheFolders} ) {
			if ( $class->hasCredentials($_) ) {
				$cacheDir = catdir($serverPrefs->get('cachedir'), 'spotty', $_);
				last;
			}
		}
	}

	return $cacheDir;
}

sub cacheFolders {
	my ($class) = @_;

	my $cacheDir = catdir($serverPrefs->get('cachedir'), 'spotty');

	my @folders;

	if (opendir(DIR, $cacheDir)) {
		while ( defined( my $subDir = readdir(DIR) ) ) {
			my $subCacheDir = catdir($cacheDir, $subDir);

			# we only bother about sub-folders with a 8 character hash name (+ special folder names...)
			next if !-d $subCacheDir || $subDir !~ /^(?:[0-9a-f]{8}|__AUTHENTICATE__)$/i;

			if (-e catfile($subCacheDir, 'credentials.json')) {
				push @folders, $subDir;
			}
		}
	}

	return \@folders;
}

sub renameCacheFolder {
	my ($class, $oldId, $newId) = @_;

	if ( !$newId && (my $credentials = $class->getCredentials($oldId)) ) {
		$newId = substr( md5_hex(Slim::Utils::Unicode::utf8toLatin1Transliterate($credentials->{username})), 0, 8 );
	}

	main::INFOLOG && $log->info("Trying to rename $oldId to $newId");

	if (main::DEBUGLOG && $log->is_debug && !$newId) {
		Slim::Utils::Log::logBacktrace("No newId found in '$oldId'");
	}

	if ($oldId && $newId) {
		my $from = $class->cacheFolder($oldId);

		if (!-e $from) {
			$log->warn("Source file does not exist: $from");
			return;
		}

		my ($baseFolder) = $from =~ /(.*)$oldId/;
		my $to = catdir($baseFolder, $newId);

		if (-e $to) {
			if ($oldId eq '__AUTHENTICATE__') {
				rmtree($to);
			}
			else {
				$log->warn("Target folder already exists: $to");
				return;
			}
		}

		if ($from && $to) {
			require File::Copy;
			File::Copy::move($from, $to);
			$credsCache = undef;
		}
		else {
			$log->warn("either '$from' or '$to' did not exist!");
		}
	}
}

# delete the cache folder for the given ID
sub deleteCacheFolder {
	my ($class, $id) = @_;

	if ( my $credentialsFile = $class->hasCredentials($id) ) {
		unlink $credentialsFile;
		$credsCache = undef;
	}

	$class->purgeCache();
}

sub purgeCache {
	my ($class, $init) = @_;

	my $cacheDir = catdir($serverPrefs->get('cachedir'), 'spotty');

	if (opendir(DIR, $cacheDir)) {
		while ( defined( my $subDir = readdir(DIR) ) ) {
			next if $subDir =~ /^\.\.?$/;

			my $subCacheDir = catdir($cacheDir, $subDir);

			next if !-d $subCacheDir;

			# ignore real account folders with credentials
			next if $subDir =~ /^[0-9a-f]{8}$/i && -e catfile($subCacheDir, 'credentials.json');

			# ignore player specific folders unless during initialization - name is MAC address less the colons
			next if !$init && $subDir =~ /^[0-9a-f]{12}$/i;

			next if $subDir eq 'playlistFolders';

			rmtree($subCacheDir);
			$credsCache = undef;
		}
	}
}

sub purgeAudioCacheAfterXTracks {
	my ($class) = @_;

	my $tracksSincePurge = $prefs->get('tracksSincePurge');
	$prefs->set('tracksSincePurge', ++$tracksSincePurge);

	main::INFOLOG && $log->is_info && $log->info("Played $tracksSincePurge song(s) since last audio cache purge.");

	if ( $tracksSincePurge >= CACHE_PURGE_INTERVAL_COUNT ) {
		# delay the purging until the track has buffered etc.
		Slim::Utils::Timers::killTimers($class, \&purgeAudioCache);
		Slim::Utils::Timers::setTimer($class, time() + 15, \&purgeAudioCache);
	}
}

sub purgeAudioCache {
	my ($class, $ignoreTimeStamp) = @_;

	Slim::Utils::Timers::killTimers($class, \&purgeAudioCache);

	# clean up temporary files the spotty helper (librespot) is leaving behind on skips
	my $tmpFolder = __PACKAGE__->getTmpDir() || tmpdir();

	if ( $tmpFolder && -d $tmpFolder && opendir(DIR, $tmpFolder) ) {
		main::INFOLOG && $log->is_info && $log->info("Starting temporary file cleanup... ($tmpFolder)");

		foreach my $tmp ( grep { /^\.tmp[a-z0-9]{6}$/i && -f catfile($tmpFolder, $_) } readdir(DIR) ) {
			my $tmpFile = catfile($tmpFolder, $tmp);
			my (undef, undef, undef, undef, $uid, undef, undef, undef, undef, $mtime) = stat($tmpFile);

			# delete file if it matches our name, user ID, and is of a certain age
			if ( $uid == $> ) {
				unlink $tmpFile if $ignoreTimeStamp || (time() - $mtime > CACHE_PURGE_MAX_AGE);
			}

			main::idleStreams();
		}

		main::INFOLOG && $log->is_info && $log->info("Audio cache cleanup done!");
	}

	# only purge the audio cache if it's enabled
	Slim::Utils::Timers::setTimer($class, time() + CACHE_PURGE_INTERVAL, \&purgeAudioCache);

	$prefs->set('tracksSincePurge', 0);
}

sub hasCredentials {
	my ($class, $id) = @_;

	# if an ID is defined, check whether we have credentials for this ID
	if ($id) {
		my $credentialsFile = catfile($class->cacheFolder($id), 'credentials.json');
		return -f $credentialsFile ? $credentialsFile : '';
	}

	# otherwise check whether we have some credentials
	return scalar keys %{$class->getAllCredentials()};
}

sub getCredentials {
	my ($class, $id) = @_;

	if ( blessed $id && (my $account = $prefs->client($id)->get('account')) ) {
		$id = $account;
	}

	if ( my $credentialsFile = $class->hasCredentials($id) ) {
		my $credentials = eval {
			from_json(read_file($credentialsFile));
		};

		if ( $@ && !$credentials || !ref $credentials ) {
			$log->warn("Corrupted credentials file discovered. Removing configuration.");
			$class->deleteCacheFolder($id);
		}

		return $credentials || {};
	}
}

sub getAllCredentials {
	my ($class) = @_;

	return $credsCache if $credsCache && ref $credsCache;

	my $credentials = {};
	foreach ( @{$class->cacheFolders() || []} ) {
		my $creds = $class->getCredentials($_);

		# ignore credentials without username
		if ( $creds && ref $creds && (my $username = $creds->{username}) ) {
			$credentials->{$username} = $_;
		}
	}

	$credsCache = $credentials if scalar keys %$credentials;
	return $credentials;
}

sub getSortedCredentialTupels {
	my ($class) = @_;

	my $credentials = $class->getAllCredentials();

	return [ sort {
		my ($va) = values %$a;
		my ($vb) = values %$b;
		$va cmp $vb;
	} map {
		{ $_ => $credentials->{$_} }
	} keys %$credentials ];
}

sub hasMultipleAccounts {
	return scalar keys %{$_[0]->getAllCredentials()} > 1 ? 1 : 0;
}

sub getName {
	my ($class, $client, $userId) = @_;

	return unless $client;

	$class->getAPIHandler($client)->user(sub {
		$class->setName($userId, shift);
	}, $userId);
}

sub setName {
	my ($class, $userId, $result) = @_;

	if ($result && $result->{display_name}) {
		my $names = $prefs->get('displayNames');
		$names->{$userId} = $result->{display_name};
		$prefs->set('displayNames', $names);
	}
}

# we only run when transcoding is enabled, but shutdown would be called no matter what
sub shutdownPlugin { if (main::TRANSCODING) {
	# make sure we don't leave our helper app running
	if (main::WEBUI) {
		Plugins::Spotty::Settings::Auth->shutdownHelper();
	}

	Plugins::Spotty::Connect->shutdown();
} }

1;

package Plugins::Spotty::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Next;
use File::Path qw(mkpath rmtree);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile tmpdir);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Spotty::API;
use Plugins::Spotty::Connect;
use Plugins::Spotty::OPML;
use Plugins::Spotty::ProtocolHandler;

use constant HELPER => 'spotty';

use constant ENABLE_AUDIO_CACHE => 0;
use constant CACHE_PURGE_INTERVAL => 86400;
use constant CACHE_PURGE_INTERVAL_COUNT => 5;
use constant CACHE_PURGE_MAX_AGE => 60 * 60;

my $prefs = preferences('plugin.spotty');
my $credsCache;

my $log = Slim::Utils::Log->addLogCategory( {
	category     => 'plugin.spotty',
	defaultLevel => 'WARN',
	description  => 'PLUGIN_SPOTTY',
} );

my ($helper, $helperVersion);

sub initPlugin {
	my $class = shift;

	if ( !main::TRANSCODING ) {
		$log->error('You need to enable transcoding in order for Spotty to work');
		return;
	}
	
	if ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		$log->error(string('PLUGIN_SPOTTY_MISSING_SSL'));
	}
	
	$prefs->init({
		country => 'US',
		bitrate => 320,
		iconCode => \&_initIcon,
		audioCacheSize => 0,		# number of MB to cache
		tracksSincePurge => 0,
		accountSwitcherMenu => 0,
		disableDiscovery => main::ISWINDOWS ? 1 : 0,
		displayNames => {},
	});

	
	if (ENABLE_AUDIO_CACHE) {
		$prefs->setChange( sub {
			__PACKAGE__->purgeAudioCache();
			__PACKAGE__->updateTranscodingTable();
		}, 'audioCacheSize') ;
	}
	else {
		$prefs->set('audioCacheSize', 0);
	}
	
	$prefs->setChange( sub {
		__PACKAGE__->updateTranscodingTable();
	}, 'bitrate') ;

	# disable spt-flc transcoding on non-x86 platforms - don't transcode unless needed
	# this might be premature optimization, as ARM CPUs are getting more and more powerful...
	if ( !main::ISWINDOWS && !main::ISMAC 
		&& Slim::Utils::OSDetect::details()->{osArch} !~ /(?:i[3-6]|x)86/i 
	) {
		$prefs->migrate(1, sub {
			my $serverPrefs = preferences('server');
			my $disabledFormats = $serverPrefs->get('disabledformats');
	
			if (!grep /^spt/, @$disabledFormats) {
				# XXX - ugly... but there's no API to disable formats
				push @$disabledFormats, "spt-flc-*-*";
				$serverPrefs->set('disabledformats', $disabledFormats);
			}	
		});
	}

	# aarch64 can potentially use helper binaries from armhf
	if ( !main::ISWINDOWS && !main::ISMAC && Slim::Utils::OSDetect::details()->{osArch} =~ /^aarch64/i ) {
		Slim::Utils::Misc::addFindBinPaths(catdir($class->_pluginDataFor('basedir'), 'Bin', 'arm-linux'));
	}
		
	$VERSION = $class->_pluginDataFor('version');
	Slim::Player::ProtocolHandlers->registerHandler('spotify', 'Plugins::Spotty::ProtocolHandler');

	if (main::WEBUI) {
		require Plugins::Spotty::Settings;
		require Plugins::Spotty::SettingsAuth;
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

	$class->updateTranscodingTable();
	Plugins::Spotty::Connect->init($helper);

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
} }

sub updateTranscodingTable {
	my $class = shift || __PACKAGE__;
	my $client = shift;
	
	# see whether we want to have a specific player's account
	my $id = $class->getAccount($client);
	
	# modify the transcoding helper table to inject our cache folder
	my $cacheDir = $class->cacheFolder($id);

	my $bitrate = '';
	if ( Slim::Utils::Versions->checkVersion($class->getHelperVersion(), '0.8.0', 10) ) {
		$bitrate = sprintf('--bitrate %s', $prefs->get('bitrate') || 320);
	}
	
	my $helper = $class->getHelper();
	$helper = basename($helper) if $helper;
	$helper = '' if $helper eq 'spotty';
	
	my $tmpDir = $class->getTmpDir();
	if ($tmpDir) {
		$tmpDir = "TMPDIR=$tmpDir";
	}

	my $commandTable = Slim::Player::TranscodingHelper::Conversions();
	foreach ( keys %$commandTable ) {
		if ( $_ =~ /^spt-/ && $commandTable->{$_} =~ /single-track/ ) {
			$commandTable->{$_} =~ s/-c ".*?"/-c "$cacheDir"/g;
			$commandTable->{$_} =~ s/(\[spotty\])/$tmpDir $1/g if $tmpDir;
			$commandTable->{$_} =~ s/^[^\[]+// if !$tmpDir;
			$commandTable->{$_} =~ s/--bitrate \d{2,3}/$bitrate/; 
			$commandTable->{$_} =~ s/\[spotty\]/\[$helper\]/g if $helper;
			$commandTable->{$_} =~ s/disable-audio-cache/enable-audio-cache/g if ENABLE_AUDIO_CACHE && $prefs->get('audioCacheSize');
			$commandTable->{$_} =~ s/enable-audio-cache/disable-audio-cache/g if !(ENABLE_AUDIO_CACHE && $prefs->get('audioCacheSize'));
		}
	}
}

sub getTmpDir {
	if ( !main::ISWINDOWS && !main::ISMAC ) {
		return catdir(preferences('server')->get('cachedir'), 'spotty');
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

sub canDiscovery { !main::ISWINDOWS }

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
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty', $id);
	
	# if no $id was given, let's pick the first one
	if (!$id) {
		foreach ( @{$class->cacheFolders} ) {
			if ( $class->hasCredentials($_) ) {
				$cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty', $_);
				last;
			}
		}
	}

	return $cacheDir;
}

sub cacheFolders {
	my ($class) = @_;
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty');
	
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
		$newId = substr( md5_hex($credentials->{username}), 0, 8 );
	}

	if ($oldId && $newId) {
		my $from = $class->cacheFolder($oldId);
		
		return if !-e $from;
		
		my ($baseFolder) = $from =~ /(.*)$oldId/;
		my $to = catdir($baseFolder, $newId); 

		if (-e $to) {
			if ($oldId eq '__AUTHENTICATE__') {
				rmtree($to);
			}
			else {
				return;
			}
		}
	
		if ($from && $to) {
			require File::Copy;
			File::Copy::move($from, $to);
			$credsCache = undef;
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
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty');
	
	if (opendir(DIR, $cacheDir)) {
		while ( defined( my $subDir = readdir(DIR) ) ) {
			next if $subDir =~ /^\.\.?$/;
			
			my $subCacheDir = catdir($cacheDir, $subDir);
			
			next if !-d $subCacheDir;
			
			# ignore real account folders with credentials
			next if $subDir =~ /^[0-9a-f]{8}$/i && -e catfile($subCacheDir, 'credentials.json');

			# ignore player specific folders unless during initialization - name is MAC address less the colons
			next if !$init && $subDir =~ /^[0-9a-f]{12}$/i;
			
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

	main::INFOLOG && $log->is_info && $log->info("Starting audio cache cleanup...");
	
	# purge our local file cache
	if (ENABLE_AUDIO_CACHE || $ignoreTimeStamp) {
		my $files = File::Next::files( catdir(__PACKAGE__->cacheFolder(), 'files') );
		my @files;
		my $totalSize = 0;
		
		while ( defined ( my $file = $files->() ) ) {
			# give the server some room to breath...
			main::idleStreams();
	
			my @stat = stat($file);
			
			# keep track of file path, size and last access/modification date
			push @files, [$file, $stat[7], $stat[8] || $stat[9]];
			$totalSize += $stat[7];
		}
	
		@files = sort { $a->[2] <=> $b->[2] } @files;
	
		my $maxCacheSize = $prefs->get('audioCacheSize') * 1024 * 1024;
		
		main::INFOLOG && $log->is_info && $log->info(sprintf("Max. cache size is: %iMB, current cache size is %iMB", $prefs->get('audioCacheSize'), $totalSize / (1024*1024)));
		
		# we're going to reduce the cache size to get some slack before exceeding the cache size
		$maxCacheSize *= 0.8;
		
		foreach my $file ( @files ) {
			main::idleStreams();
	
			last if $totalSize < $maxCacheSize;
			
			unlink $file->[0];
			$totalSize -= $file->[1];
			
			my $dir = dirname($file->[0]);
			
			opendir DIR, $dir or next;
			
			if ( !scalar File::Spec->no_upwards(readdir DIR) ) {
				close DIR;
				rmdir $dir;
			}
			else {
				close DIR;
			}
		}
	}
	
	# clean up temporary files the spotty helper (librespot) is leaving behind on skips
	my $tmpFolder = __PACKAGE__->getTmpDir() || tmpdir();

	if ( $tmpFolder && -d $tmpFolder && opendir(DIR, $tmpFolder) ) {
		main::INFOLOG && $log->is_info && $log->info("Starting temporary file cleanup... ($tmpFolder)");
		
		foreach my $tmp ( grep { /^\.tmp[a-z0-9]{6}$/i && -f catfile($tmpFolder, $_) } readdir(DIR) ) {
			my $tmpFile = catfile($tmpFolder, $tmp);
			my (undef, undef, undef, undef, $uid, $gid, undef, $size, undef, $mtime, $ctime) = stat($tmpFile);
			
			# delete file if it matches our name, user ID, and is of a certain age
			if ( $uid == $> ) {
				unlink $tmpFile if $ignoreTimeStamp || (time() - $mtime > CACHE_PURGE_MAX_AGE);
			}

			main::idleStreams();
		}
	}

	# only purge the audio cache if it's enabled
	Slim::Utils::Timers::setTimer($class, time() + CACHE_PURGE_INTERVAL, \&purgeAudioCache);

	$prefs->set('tracksSincePurge', 0);

	main::INFOLOG && $log->is_info && $log->info("Audio cache cleanup done!");
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
		my ($result) = @_;

		if ($result && $result->{display_name}) {
			my $names = $prefs->get('displayNames');
			$names->{$userId} = $result->{display_name};
			$prefs->set('displayNames', $names);
		}
	}, $userId);
}

sub getHelper {
	my ($class) = @_;

	if (!$helper) {
		my $check;

		$helper = $class->findBin(HELPER, sub {
			my $candidate = $_[0];
			
			my $checkCmd = sprintf('%s -n "%s (%s)" --check', 
				$candidate,
				string('PLUGIN_SPOTTY_AUTH_NAME'),
				Slim::Utils::Misc::getLibraryName()
			);
			
			$check = `$checkCmd 2>&1`;

			if ( $check && $check =~ /^ok spotty v([\d\.]+)/i ) {
				$helper = $candidate;
				$helperVersion = $1;
				return 1;
			}
		}, 'custom-first');
		
		if (!$helper) {
			$log->warn("Didn't find Spotty helper application!");
			$log->warn("Last error: \n" . $check) if $check;	
		}
	}	

	return wantarray ? ($helper, $helperVersion) : $helper;
}

sub getHelperVersion {
	my ($class) = @_;
	
	if (!$helperVersion) {
		$class->getHelper();
	}
	
	return $helperVersion;
}

# custom file finder around Slim::Utils::Misc::findbin: check for multiple versions per platform etc.
sub findBin {
	my ($class, $name, $checkerCb, $customFirst) = @_;
	
	my @candidates = ($name);
	my $binary;
	
	# trying to find the correct binary can be tricky... some ARM platforms behave oddly.
	# do some trial-and-error testing to see what we can use
	if (Slim::Utils::OSDetect::OS() eq 'unix') {
		# on 64 bit try 64 bit builds first
		if ( $Config::Config{'archname'} =~ /x86_64/ ) {
			if ($customFirst) {
				unshift @candidates, $name . '-x86_64';
			}
			else {
				push @candidates, $name . '-x86_64';
			}
		}
		elsif ( $Config::Config{'archname'} =~ /[3-6]86/ ) {
			if ($customFirst) {
				unshift @candidates, $name . '-i386';
			}
			else {
				push @candidates, $name . '-i386';
			}
		}

		# on armhf use hf binaries instead of default arm5te binaries
		# muslhf would not run on Pi1... have another gnueabi-hf for it
		elsif ( $Config::Config{'archname'} =~ /(aarch64|arm).*linux/ ) {
			if ($customFirst && $1 ne 'aarch64') {
				unshift @candidates, $name . '-muslhf', $name . '-hf';
			}
			else {
				push @candidates, $name . '-muslhf', $name . '-hf';
			}
		}
	}

	# try spotty-custom first, allowing users to drop their own build anywhere
	unshift @candidates, $name . '-custom';
	my $check;
	
	foreach (@candidates) {
		my $candidate = Slim::Utils::Misc::findbin($_) || next;
		
		$candidate = Slim::Utils::OSDetect::getOS->decodeExternalHelperPath($candidate);

		next unless -f $candidate && -x $candidate;
		
		main::INFOLOG && $log->is_info && $log->info("Trying helper applicaton: $candidate");

		if ( !$checkerCb || $checkerCb->($candidate) ) {
			$binary = $candidate;
			main::INFOLOG && $log->is_info && $log->info("Found helper applicaton: $candidate");
			last;
		}
	}
	
	return $binary;
}


# we only run when transcoding is enabled, but shutdown would be called no matter what
sub shutdownPlugin { if (main::TRANSCODING) {
	# make sure we don't leave our helper app running
	if (main::WEBUI) {
		Plugins::Spotty::SettingsAuth->shutdownHelper();
	}
	
	Plugins::Spotty::Connect->shutdown();

	# XXX - ugly attempt at killing all hanging helper applications...
	if ( !main::ISWINDOWS && $_[0]->getHelper() ) {
		my $helper = File::Basename::basename(scalar $_[0]->getHelper());
		`killall $helper > /dev/null 2>&1`;
	}
} }

1;

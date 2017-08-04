package Plugins::Spotty::Plugin;

use strict;

use base qw(Slim::Plugin::OPMLBased);

use vars qw($VERSION);

use Digest::MD5 qw(md5_hex);
use File::Basename;
use File::Next;
use File::Path qw(mkpath rmtree);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use Plugins::Spotty::API;
use Plugins::Spotty::OPML;
use Plugins::Spotty::ProtocolHandler;

use constant HELPER => 'spotty';
use constant CONNECT_ENABLED => 0;
use constant CACHE_PURGE_INTERVAL => 86400;
use constant CACHE_PURGE_INTERVAL_COUNT => 20;

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
	
	if ( !Slim::Networking::Async::HTTP->hasSSL() ) {
		$log->error(string('PLUGIN_SPOTTY_MISSING_SSL'));
	}
	
	$prefs->init({
		country => 'US',
		iconCode => \&_initIcon,
		audioCacheSize => 0,		# number of MB to cache
		tracksSincePurge => 0,
		accountSwitcherMenu => 0,
	});
	
	$prefs->setChange( sub {
		__PACKAGE__->purgeAudioCache();
		__PACKAGE__->updateTranscodingTable();
	}, 'audioCacheSize');
	
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
	
	$VERSION = $class->_pluginDataFor('version');
	Slim::Player::ProtocolHandlers->registerHandler('spotty', 'Plugins::Spotty::ProtocolHandler');

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

	$class->purgeCache();
	$class->purgeAudioCache();
}

sub postinitPlugin {
	my $class = shift;

	# we're going to hijack the Spotify URI schema
	Slim::Player::ProtocolHandlers->registerHandler('spotify', 'Plugins::Spotty::ProtocolHandler');

	$class->updateTranscodingTable();
	
	if (CONNECT_ENABLED) {
		require Plugins::Spotty::Connect;
		Plugins::Spotty::Connect->init($helper);
	}

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
}

sub updateTranscodingTable {
	my $class = shift || __PACKAGE__;
	
	# modify the transcoding helper table to inject our cache folder
	my $cacheDir = $class->cacheFolder();
	
	my $helper = $class->getHelper();
	$helper = basename($helper) if $helper;
	$helper = '' if $helper eq 'spotty';

	foreach ( keys %Slim::Player::TranscodingHelper::commandTable ) {
		if ( $_ =~ /^spt-/ && $Slim::Player::TranscodingHelper::commandTable{$_} =~ /single-track/ ) {
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\$CACHE\$/$cacheDir/g;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/\[spotty\]/\[$helper\]/g if $helper;
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/disable-audio-cache/enable-audio-cache/g if $prefs->get('audioCacheSize');
			$Slim::Player::TranscodingHelper::commandTable{$_} =~ s/enable-audio-cache/disable-audio-cache/g if !$prefs->get('audioCacheSize');
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
	my ($class, $id, $noFallback) = @_;
	
	$id ||= 'default';
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty', $id);

	# if we don't hava a default, but alternatives, promote one of them
	if (!-e $cacheDir && $id eq 'default') {
		foreach ( @{$class->cacheFolders} ) {
			next if $_ eq $id;
			
			if ( $class->hasCredentials($_) ) {
				# don't call renameCacheFolder, as it's looping back here...
				require File::Copy;
				File::Copy::move($class->cacheFolder($_), $cacheDir);
				last;
			}
		}
		
		# otherwise just create the folder
		mkpath($cacheDir) unless -e $cacheDir;

		$credsCache = undef;
	}
	# if we wanted specific account, but it's not available - fall back to default
	elsif (!$noFallback && !-e _) {
		$cacheDir = $class->cacheFolder();
	}

	return $cacheDir;
}

sub cacheFolders {
	my ($class, $purge) = @_;
	
	my $cacheDir = catdir(preferences('server')->get('cachedir'), 'spotty');
	
	# if we're coming from an old installation, migrate the credentials to the new path
	if ( -f catfile($cacheDir, 'credentials.json') && -e catdir($cacheDir, 'files') && !-e (my $defaultDir = catdir($cacheDir, 'default')) ) {
		$log->warn("Trying to migrate old credentials data.");
		# we don't migrate the file cache
		rmtree catdir($cacheDir, 'files');
		mkpath catdir($defaultDir, 'files');
		
		require File::Copy;
		File::Copy::move(catfile($cacheDir, 'credentials.json'), $defaultDir);
	}
	
	my @folders;

	if (opendir(DIR, $cacheDir)) {
		while ( defined( my $subDir = readdir(DIR) ) ) {
			my $subCacheDir = catdir($cacheDir, $subDir);
			
			# we only bother about sub-folders with a 8 character hash name
			next if !-d $subCacheDir || $subDir !~ /^(?:default|[0-9a-f]{8}|__AUTHENTICATE__)$/i;
			
			if (-e catfile($subCacheDir, 'credentials.json')) {
				push @folders, $subDir;
			}
			# remove cache folders without credentials
			elsif ($purge && -e catdir($subCacheDir, 'files')) {
				rmtree($subCacheDir);
				$credsCache = undef;
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
		my $from = Plugins::Spotty::Plugin->cacheFolder($oldId, 'no-fallback');
		
		return if !-e $from;
		
		my ($baseFolder) = $from =~ /(.*)$oldId/;
		my $to = catdir($baseFolder, $newId); 
		
		return if -e $to;
	
		if ($from && $to) {
			require File::Copy;
			File::Copy::move($from, $to);
			$credsCache = undef;
		}
	}
}

# delete the cache forlder for the given ID, make sure we still have a "default"
sub deleteCacheFolder {
	my ($class, $id) = @_;

	if ( my $credentialsFile = $class->hasCredentials($id, 'no-fallback') ) {
		unlink $credentialsFile;
		$credsCache = undef;
	}
	
	$class->purgeCache();
	$class->cacheFolder();
}

sub purgeCache {
	$_[0]->cacheFolders('purge');
}

sub purgeAudioCacheAfterXTracks {
	my ($class) = @_;
	
	my $tracksSincePurge = $prefs->get('tracksSincePurge');
	$prefs->set('tracksSincePurge', ++$tracksSincePurge);

	main::INFOLOG && $log->is_info && $log->info("Played $tracksSincePurge song(s) since last audio cache purge.");

	if ( $tracksSincePurge >= CACHE_PURGE_INTERVAL_COUNT ) {
		# delay the purging until the track has buffered etc.
		Slim::Utils::Timers::killTimers(0, \&purgeAudioCache);
		Slim::Utils::Timers::setTimer(0, time() + 15, \&purgeAudioCache);
	}		
}

sub purgeAudioCache {
	Slim::Utils::Timers::killTimers(0, \&purgeAudioCache);

	main::INFOLOG && $log->is_info && $log->info("Starting audio cache cleanup...");
	
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

	# only purge the audio cache if it's enabled
	if ($maxCacheSize) {
		Slim::Utils::Timers::setTimer(0, time() + CACHE_PURGE_INTERVAL, \&purgeAudioCache);
	}

	$prefs->set('tracksSincePurge', 0);

	main::INFOLOG && $log->is_info && $log->info("Audio cache cleanup done!");
}

sub hasCredentials {
	my ($class, $id, $noFallback) = @_;
	my $credentialsFile = catfile($class->cacheFolder($id, $noFallback), 'credentials.json');
	return -f $credentialsFile ? $credentialsFile : '';
}

sub getCredentials {
	my ($class, $id, $noFallback) = @_;
	
	if ( blessed $id && (my $account = $prefs->client($id)->get('account')) ) {
		$id = $account;
	}
	
	if ( my $credentialsFile = $class->hasCredentials($id, $noFallback) ) {
		my $credentials = eval {
			from_json(read_file($credentialsFile));
		};
		
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
			# but don't override the default account
			if ( ($credentials->{$username} || '') ne 'default') {
				$credentials->{$username} = $_;
			}
		}
	}
	
	$credsCache = $credentials if scalar keys %$credentials;
	return $credentials;
}

sub getSortedCredentialTupels {
	my ($class) = @_;

	my $credentials = Plugins::Spotty::Plugin->getAllCredentials();
	
	return [ sort {
		my ($va) = values %$a;
		my ($vb) = values %$b;
		if    ($va eq 'default') { -1 }
		elsif ($vb eq 'default') { 1 }
		else                     { $va cmp $vb }
	} map {
		{ $_ => $credentials->{$_} }
	} keys %$credentials ];
}

sub hasMultipleAccounts {
	return scalar keys %{$_[0]->getAllCredentials()} > 1 ? 1 : 0;
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
		my $check;
		
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
			
			$check = `$checkCmd 2>&1`;

			if ( $check && $check =~ /^ok spotty (v[\d\.]+)/i ) {
				$helper = $candidate;
				$helperVersion = $1;
				last;
			}
		}
		
		if (!$helper) {
			$log->warn("Didn't find Spotty helper application!");
			$log->warn("Last error: \n" . $check) if $check;	
		}
		elsif (main::INFOLOG && $log->is_info && $helper) {
			$log->info("Found Spotty helper application: $helper");
		}
	}	

	return wantarray ? ($helper, $helperVersion) : $helper;
}


sub shutdownPlugin {
	# make sure we don't leave our helper app running
	if (main::WEBUI) {
		Plugins::Spotty::SettingsAuth->shutdownHelper();
	}
}

1;

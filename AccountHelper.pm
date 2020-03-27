package Plugins::Spotty::AccountHelper;

use strict;

use Digest::MD5 qw(md5_hex);
use File::Path qw(rmtree);
use File::Slurp;
use File::Spec::Functions qw(catdir catfile tmpdir);
use JSON::XS::VersionOneAndTwo;
use Scalar::Util qw(blessed);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use constant CACHE_PURGE_INTERVAL => 86400;
use constant CACHE_PURGE_MAX_AGE => 60 * 60;
use constant CACHE_PURGE_INTERVAL_COUNT => 15;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');
my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');

my $credsCache;

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

sub getSomeAccount {
	my ($class) = @_;

	if (my $accounts = $class->getAllCredentials()) {
		my ($account) = keys %$accounts;
		return $accounts->{$account} if $account;
	}
}

sub getTmpDir {
	if ( !main::ISWINDOWS && !main::ISMAC ) {
		return catdir($serverPrefs->get('cachedir'), 'spotty');
	}
	return '';
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

		if ( ($@ && !$credentials) || !ref $credentials ) {
			$log->error("Corrupted credentials file discovered. Removing configuration. " . ($@ || ''));
			$log->error(read_file($credentialsFile, err_mode => 'carp'));
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

	if (!main::SCANNER && Slim::Utils::Versions->compareVersions($::VERSION, '7.9.1') >= 0 && scalar keys %$credentials > 1) {
		require Slim::Music::VirtualLibraries;

		# this is just a stub to make LMS include the library - but it's all created in the importer
		# while (my ($account, $accountId) = each %$accounts) {
		foreach my $account (keys %$credentials) {
			my $accountId = $credentials->{$account};
			Slim::Music::VirtualLibraries->unregisterLibrary($accountId);
			Slim::Music::VirtualLibraries->registerLibrary({
				id => $accountId,
				name => $class->getDisplayName($account) . ' (Spotty)',
				scannerCB => sub {}
			});

			Slim::Music::VirtualLibraries->unregisterLibrary($accountId . 'AndLocal');
			Slim::Music::VirtualLibraries->registerLibrary({
				id => $accountId . 'AndLocal',
				name => Slim::Utils::Strings::string('PLUGIN_SPOTTY_USERS_AND_LOCAL_LIBRARY', $class->getDisplayName($account)),
				scannerCB => sub {}
			});
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

	Plugins::Spotty::Plugin->getAPIHandler($client)->user(sub {
		$class->setName($userId, shift);
	}, $userId);
}

sub getDisplayName {
	my ($class, $userId) = @_;
	return $prefs->get('displayNames')->{$userId} || $userId;
}

sub setName {
	my ($class, $userId, $result) = @_;

	if ($result && $result->{display_name}) {
		my $names = $prefs->get('displayNames');
		$names->{$userId} = $result->{display_name};
		$prefs->set('displayNames', $names);
	}
}

1;
package Plugins::Spotty::Connect::Daemon;

use strict;

use base qw(Slim::Utils::Accessor);

use Fcntl qw(O_RDONLY O_NONBLOCK);
use File::Path qw(rmtree);
use File::Spec::Functions qw(catdir);
use MIME::Base64 qw(encode_base64);
use POSIX qw(mkfifo);
use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# disable discovery mode if we have to restart more than x times in y minutes
use constant MAX_FAILURES_BEFORE_DISABLE_DISCOVERY => 3;
use constant MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY => 5 * 60;

# disable stream mode if the streaming daemon crashes too many times in a short window
use constant MAX_STREAM_FAILURES => 5;
use constant MAX_STREAM_INTERVAL => 2 * 60;

use constant SPOTIFY_ID_TTL => 600;

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	name
	cache
	_lastSeen
	_spotifyId
	_proc
	_startTimes
	_streamStartTimes
	_streamMode
	_fifoPath
	_keepaliveFh
) );

my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');
my $log = logger('plugin.spotty');

sub new {
	my ($class, $id) = @_;

	my $self = $class->SUPER::new();

	$self->mac($id);
	$id =~ s/://g;
	$self->id($id);
	$self->_startTimes([]);
	$self->_streamStartTimes([]);
	$self->start();

	return $self;
}

sub start {
	my $self = shift;

	my $helperPath = Plugins::Spotty::Helper->get();
	my $client = Slim::Player::Client::getClient($self->mac);

	# Spotify can't handle long player names
	$self->name(substr(
		($client->isSynced() && $client->model ne 'group')
			? Slim::Player::Sync::syncname($client)
			: $client->name,
	0, 60));

	$self->cache(Plugins::Spotty::Connect->cacheFolder($self->mac));

	$self->_checkStartTimes();
	my $streamBackoff = Plugins::Spotty::Helper->getCapability('connect-stream')
		? $self->_checkStreamStartTimes()
		: 0;

	my @helperArgs = (
		'-c', $self->cache,
		'-n', $self->name,
		'--disable-audio-cache',
		'--player-mac', $self->mac,
		'--lms', '127.0.0.1:' . preferences('server')->get('httpport'),
	);

	# Discovery is enabled by default; disable only when canDiscovery() returns false or the user opted out
	if ( !Plugins::Spotty::Plugin->canDiscovery() || $prefs->get('disableDiscovery') ) {
		push @helperArgs, '--disable-discovery';
	}

	# TODO - review no AP port behaviour
	if ( $prefs->get('forceFallbackAP') && !Plugins::Spotty::Helper->getCapability('no-ap-port') ) {
		push @helperArgs, '--ap-port=12321';
	}

	if ( !$streamBackoff && Plugins::Spotty::Helper->getCapability('connect-stream') ) {
		# Stream mode: binary writes continuous PCM to FIFO; LMS reads via cat
		$self->_streamMode(1);
		# Reuse existing FIFO and keep-alive FD if they are still valid (prevents FD leak on restart)
		my $fifo = ($self->_fifoPath && -p $self->_fifoPath)
			? $self->_fifoPath
			: $self->_createFifo();
		push @helperArgs, '--connect-stream';

		# Log the command BEFORE adding --lms-auth (security: no password in log, per T-08-03)
		if (main::INFOLOG && $log->is_info) {
			$log->info("Starting Spotty Connect daemon (stream mode): \n$helperPath " . join(' ', @helperArgs));
			push @helperArgs, '--verbose' if Plugins::Spotty::Helper->getCapability('debug');
		}

		# add authentication data (after the log statement, so credentials never appear in logs)
		if ( $serverPrefs->get('authorize') ) {
			if ( Plugins::Spotty::Helper->getCapability('lms-auth') ) {
				main::INFOLOG && $log->is_info && $log->info("Adding authentication data to Spotty Connect daemon configuration.");
				push @helperArgs, '--lms-auth', encode_base64(sprintf("%s:%s", $serverPrefs->get('username'), $serverPrefs->get('password')));
			}
			else {
				$log->error("Your Lyrion Music Server is password protected, but your spotty helper can't deal with it! Spotty will NOT work. Please update.");
			}
		}

		eval {
			$self->_proc( Proc::Background->new(
				{ 'die_upon_destroy' => 1 },
				'/bin/sh', '-c',
				"$helperPath " . join(' ', @helperArgs) . " > $fifo"
			) );
		};
	}
	else {
		# Non-stream mode: legacy single-track invocation
		$self->_streamMode(0);

		# Log the command BEFORE adding --lms-auth (security: no password in log, per T-08-03)
		if (main::INFOLOG && $log->is_info) {
			$log->info("Starting Spotty Connect daemon: \n$helperPath " . join(' ', @helperArgs));
			push @helperArgs, '--verbose' if Plugins::Spotty::Helper->getCapability('debug');
		}

		# add authentication data (after the log statement, so credentials never appear in logs)
		if ( $serverPrefs->get('authorize') ) {
			if ( Plugins::Spotty::Helper->getCapability('lms-auth') ) {
				main::INFOLOG && $log->is_info && $log->info("Adding authentication data to Spotty Connect daemon configuration.");
				push @helperArgs, '--lms-auth', encode_base64(sprintf("%s:%s", $serverPrefs->get('username'), $serverPrefs->get('password')));
			}
			else {
				$log->error("Your Lyrion Music Server is password protected, but your spotty helper can't deal with it! Spotty will NOT work. Please update.");
			}
		}

		eval {
			$self->_proc( Proc::Background->new(
				{ 'die_upon_destroy' => 1 },
				$helperPath,
				@helperArgs
			) );
		};
	}

	if ($@) {
		$log->warn("Failed to launch the Spotty Connect daemon: $@");
	}
}

sub _checkStartTimes {
	my $self = shift;

	# Crash-backoff (T-08-04): if more than MAX_FAILURES starts recorded within
	# MAX_INTERVAL seconds, disable discovery to prevent infinite crash loops
	if ( scalar @{$self->_startTimes} > MAX_FAILURES_BEFORE_DISABLE_DISCOVERY ) {
		splice @{$self->_startTimes}, 0, @{$self->_startTimes} - MAX_FAILURES_BEFORE_DISABLE_DISCOVERY;

		if ( time() - $self->_startTimes->[0] < MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY
			&& !$prefs->get('disableDiscovery')
		) {
			$log->warn(sprintf(
				'The spotty helper has crashed %s times within less than %s minutes - disable local announcement of the Connect daemon.',
				MAX_FAILURES_BEFORE_DISABLE_DISCOVERY,
				MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY / 60
			));

			$prefs->set('disableDiscovery', 1);
		}
	}

	push @{$self->_startTimes}, time();
}

sub _checkStreamStartTimes {
	my $self = shift;

	# Stream-specific crash-backoff: if the streaming daemon crashes more than
	# MAX_STREAM_FAILURES times within MAX_STREAM_INTERVAL seconds, disable stream
	# mode to prevent an infinite restart loop. Unlike _checkStartTimes, this does
	# NOT disable discovery — it only disables the stream-mode code path.
	if ( scalar @{$self->_streamStartTimes} >= MAX_STREAM_FAILURES ) {
		splice @{$self->_streamStartTimes}, 0, @{$self->_streamStartTimes} - MAX_STREAM_FAILURES;

		if ( time() - $self->_streamStartTimes->[0] < MAX_STREAM_INTERVAL ) {
			$log->warn(sprintf(
				'Spotty stream daemon crashed %s times within less than %s minutes - disabling stream mode.',
				MAX_STREAM_FAILURES,
				MAX_STREAM_INTERVAL / 60
			));

			$self->_streamMode(0);
			return 1;
		}
	}

	push @{$self->_streamStartTimes}, time();
	return 0;
}

sub stop {
	my $self = shift;

	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting Spotty Connect daemon for " . $self->mac);
		$self->_proc->die;
		$self->_cleanupFifo();

		rmtree catdir(preferences('server')->get('cachedir'), 'spotty', $self->id);
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This daemon is dead already... no need to stop it!");
	}
}

sub stopForSync {
	my $self = shift;

	# Stop the daemon process for a sync-group change, but preserve the FIFO and
	# cache directory so LMS's cat process does not get EOF and the next start()
	# call can reuse them immediately (FIX-01, FIX-02).
	#
	# Unlike stop(), this method deliberately does NOT call _cleanupFifo() or
	# rmtree the cache directory. The FIFO keep-alive FD stays open so the pipe
	# remains intact during the brief restart window.
	#
	# The _streamStartTimes counter is reset so the planned restart is not counted
	# as a crash by _checkStreamStartTimes, which would otherwise trigger the
	# stream-mode backoff after repeated sync/unsync cycles.
	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info("Stopping Spotty Connect daemon for sync (preserving FIFO): " . $self->mac);
		$self->_proc->die;
		$self->_streamStartTimes([]);
		$self->_startTimes([]);
	}
	elsif (main::INFOLOG && $log->is_info) {
		$log->info("This daemon is dead already (stopForSync called on dead daemon for " . $self->mac . ")");
	}
}

sub _createFifo {
	my ($self) = @_;
	my $path = "/tmp/spotty-stream-" . $self->id . ".pcm";
	POSIX::mkfifo($path, 0600) unless -p $path;
	sysopen(my $fh, $path, O_RDONLY | O_NONBLOCK)
		or $log->warn("spotty FIFO keep-alive open failed: $!");
	$self->_fifoPath($path);
	$self->_keepaliveFh($fh);
	main::INFOLOG && $log->is_info && $log->info("Created spotty stream FIFO: $path");
	return $path;
}

sub _cleanupFifo {
	my ($self) = @_;
	close($self->_keepaliveFh) if $self->_keepaliveFh;
	unlink $self->_fifoPath if $self->_fifoPath && -p $self->_fifoPath;
	$self->_fifoPath(undef);
	$self->_keepaliveFh(undef);
}

sub spotifyId {
	my ($self, $value) = @_;

	if (defined $value) {
		$self->_spotifyId($value);
		$self->_lastSeen(time);
	}

	return $self->_spotifyId;
}

sub spotifyIdIsRecent {
	my $self = shift;
	return (time() - ($self->_lastSeen || 0)) <= SPOTIFY_ID_TTL ? $self->_spotifyId : undef;
}

sub pid {
	my $self = shift;
	return $self->_proc && $self->_proc->pid;
}

sub alive {
	my $self = shift;
	return 1 if $self->_proc && $self->_proc->alive;
}

sub uptime {
	my $self = shift;
	return Time::HiRes::time() - ($self->_startTimes->[-1] || time());
}

1;

package Plugins::Spotty::Connect::Daemon;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Path qw(rmtree);
use File::Spec::Functions qw(catdir);
use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

# disable discovery mode if we have to restart more than x times in y minutes
use constant MAX_FAILURES_BEFORE_DISABLE_DISCOVERY => 3;
use constant MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY => 5 * 60;

__PACKAGE__->mk_accessor( rw => qw(
	id
	mac
	_proc
	_startTimes
) );

my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

sub new {
	my ($class, $id) = @_;
	
	my $self = $class->SUPER::new();

	$self->mac($id);
	$id =~ s/://g;
	$self->id($id);
	$self->_startTimes([]);
	$self->start();
	
	return $self;
}

sub start {
	my $self = shift;
	
	my $helperPath = Plugins::Spotty::Plugin->getHelper();
	my $client = Slim::Player::Client::getClient($self->mac);
	
	$self->_checkStartTimes();

	my @helperArgs = (
		'-c', Plugins::Spotty::Connect->cacheFolder($self->mac),
		'-n', $client->name,
		'--disable-audio-cache',
		'--bitrate', 96,
		'--player-mac', $self->mac,
		'--lms', Slim::Utils::Network::serverAddr() . ':' . preferences('server')->get('httpport'),
	);
	
	if ( !Plugins::Spotty::Plugin->canDiscovery() || $prefs->get('disableDiscovery') ) {
		push @helperArgs, '--disable-discovery';
	}

	if (main::INFOLOG && $log->is_info) {
		$log->info("Starting Spotty Connect deamon: \n$helperPath " . join(' ', @helperArgs));
		push @helperArgs, '--verbose' if $helperPath =~ /spotty-custom$/;
	}

	eval { 
		$self->_proc( Proc::Background->new(
			{ 'die_upon_destroy' => 1 },
			$helperPath,
			@helperArgs
		) );
	};

	if ($@) {
		$log->warn("Failed to launch the Spotty Connect deamon: $@");
	}
}

sub _checkStartTimes {
	my $self = shift;
	
	if ( !$prefs->get('disableDiscovery') ) {
		if ( scalar @{$self->_startTimes} > MAX_FAILURES_BEFORE_DISABLE_DISCOVERY ) {
			splice @{$self->_startTimes}, 0, @{$self->_startTimes} - MAX_FAILURES_BEFORE_DISABLE_DISCOVERY;
			
			if ( time() - $self->_startTimes->[0] < MAX_INTERVAL_BEFORE_DISABLE_DISCOVERY ) {
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
}

sub stop {
	my $self = shift;
	
	if ($self->alive) {
		main::INFOLOG && $log->is_info && $log->info("Quitting Spotty Connect daemon for " . $self->mac);
		$self->_proc->die;
		
		rmtree catdir(preferences('server')->get('cachedir'), 'spotty', $self->id);
	}
}

sub alive {
	my $self = shift;
	return 1 if $self->_proc && $self->_proc->alive;
}


1;
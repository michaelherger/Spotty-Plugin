package Plugins::Spotty::Connect::Daemon;

use strict;

use base qw(Slim::Utils::Accessor);

use File::Path qw(rmtree);
use File::Spec::Functions qw(catdir);
use Proc::Background;

use Slim::Utils::Log;
use Slim::Utils::Prefs;

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

	main::INFOLOG && $log->is_info && $log->info("Starting Spotty Connect deamon: \n$helperPath " . join(' ', @helperArgs));

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
	
	push @{$self->_startTimes}, time();
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
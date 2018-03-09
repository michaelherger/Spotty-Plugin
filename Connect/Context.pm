package Plugins::Spotty::Connect::Context;

use strict;

use base qw(Slim::Utils::Accessor);

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
# use Slim::Utils::Timers;

use constant HISTORY_KEY => 'spotty-connect-history';

__PACKAGE__->mk_accessor( rw => qw(
	time
	_id
	_cache
) );

#my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my $memoryCache;

sub new {
	my ($class) = @_;
	
	my $self = $class->SUPER::new();

	$self->time(time());
	$self->_id('SpottyContext' . int(rand 999999999999));
	$self->_cache(
		preferences('server')->get('dbhighmem') > 1 
		? Plugins::Spotty::Connect::MemoryCache->new()
		: Slim::Utils::Cache->new()
	);

	return $self;
}

sub set {
	my ($self, $context) = @_;
	
	# TODO - do something smart with the context...
	
	$self->_cache->remove($self->_id);
}

sub reset {
	$_[0]->_cache->remove($_[0]->_id);
}

sub addPlay {
	my ($self, $url) = @_;

	my $history = $self->_cache->get($self->_id) || {};
	$history->{$url}++;
	$self->_cache->set($self->_id, $history);
}

sub getPlay {
	my ($self, $url) = @_;
	my $history = $self->_cache->get($self->_id) || {};
	return $history->{$url} ? 1 : 0;
}

sub hasPlay {
	return $_[0]->getPlay($_[1]) ? 1 : 0;
}

1;


# a simple memory cache module, providing the same set/get interface to a hash
package Plugins::Spotty::Connect::MemoryCache;

use strict;

use Tie::Cache::LRU::Expires;

tie my %memCache, 'Tie::Cache::LRU::Expires', EXPIRES => 86400 * 7, ENTRIES => 10;

sub new {
	my ($class) = @_;
	return bless {}, $class;
}

sub get {
	return $memCache{$_[1]};
}

sub set {
	$memCache{$_[1]} = $_[2];
}

sub remove {
	delete $memCache{$_[1]};
}

1;

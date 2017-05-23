package Plugins::Spotty::API::Pipeline;

# do parallel, asynchronous calls to the Spotify API, re-ordering results in expected order

use strict;

use base qw(Slim::Utils::Accessor);
use List::Util qw(min);

use Plugins::Spotty::API;
use Slim::Utils::Log;

use constant DEFAULT_LIMIT => 200;
use constant SPOTIFY_LIMIT => 50;

__PACKAGE__->mk_accessor( rw => qw(
	method limit params
	extractorCb	cb
	_data _chunks
) );

my $log = logger('plugin.spotty');

sub new {
	my $class = shift;
	
	my $self = $class->SUPER::new();

	$self->method(shift);
	$self->extractorCb(shift);
	$self->cb(shift);
	$self->params(Storable::dclone(shift));
	
	$self->limit($self->params->{limit} || DEFAULT_LIMIT);
	$self->params->{limit} = SPOTIFY_LIMIT;
	
	$self->_data({});
	$self->_chunks({});
	
	return $self;
}

# get the first chunk of data, then run async calls if more results are available
sub get {
	my ($self, $method) = @_;

	$method ||= $self->method;

	Plugins::Spotty::API->_call($method, sub {
		my ($count, $next) = $self->_extract(0, shift);
		
#		warn Data::Dump::dump($count, $self->limit, SPOTIFY_LIMIT, $next);
		# no need to run more requests if there's no more than the received results
		if ( $count <= SPOTIFY_LIMIT || $self->limit <= SPOTIFY_LIMIT ) {
			$self->_getDone();
			return;
		}
		# some calls are paging by ID ("after=abc123") - we have to run them serially
		elsif ( $next && $next !~ /\boffset=/ && $next =~ /\bafter=([a-zA-Z0-9]{22})\b/ ) {
			$self->_followAfter($method, $count, $1);
		}
		# most calls fortunately can page by using an offset - we can run them in parallel
		else {
			$self->_followOffset($method, $count);
		}
	}, GET => $self->params);
}

sub _followAfter {
	my ($self, $method, $count, $id) = @_;
	
	Plugins::Spotty::API->_call($method, sub {
		my ($count, $next) = $self->_extract($id, shift);
		
		if ( $next && $next !~ /\boffset=/ && $next =~ /\bafter=([a-zA-Z0-9]{22})\b/ ) {
			$self->_followAfter($method, $count, $1);
		}
		else {
			$self->_getDone();
		}
	}, GET => {
		%{$self->params},
		after => $id,
	})
}

sub _followOffset {
	my ($self, $method, $count) = @_;

	for (my $offset = SPOTIFY_LIMIT; $offset < min($count, $self->limit); $offset += SPOTIFY_LIMIT) {
		my $params = Storable::dclone($self->params);
 		$params->{offset} = $offset;
 		
 		$self->_chunks->{$offset} = $params;
	}

	main::INFOLOG && $log->is_info && $log->info("There's more data to grab, queue them up: " . Data::Dump::dump($self->_chunks));
			
	# run requests in parallel
	while (my ($offset, $params) = each %{$self->_chunks}) {
		Plugins::Spotty::API->_call($method, sub {
			$self->_extract($offset, shift);
			delete $self->_chunks->{$offset};

			if (!scalar keys %{$self->_chunks}) {
				$self->_getDone();
			}
		}, GET => $params) 
	}
}
# sort data by offset number to get the original sort order back
sub _getDone {
	my ($self) = @_;
	
	$self->cb->([
		map { 
			@{$self->_data->{$_}} 
		} sort {
			$a <=> $b
		} keys %{$self->_data}
	]);
}

sub _extract {
	my ($self, $offset, $results) = @_;

	my ($chunk, $count, $next) = $self->extractorCb->($results);

	if ($chunk && ref $chunk) {
		$self->_data->{$offset} = $chunk;
	}
	
	return ($count, $next);
}

1;
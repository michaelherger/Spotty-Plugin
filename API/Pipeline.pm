package Plugins::Spotty::API::Pipeline;

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

sub get {
	my ($self, $method) = @_;

	$method ||= $self->method;

	Plugins::Spotty::API->_call($method, sub {
		my ($count, $next) = $self->_extract(0, shift);
		
		# no need to run more requests if there's no more than the received results
		if ($count <= $self->limit || $self->limit == SPOTIFY_LIMIT) {
			$self->_getDone();
			return;
		}

		for (my $offset = SPOTIFY_LIMIT; $offset < min($count, $self->limit); $offset += SPOTIFY_LIMIT) {
			my $params = Storable::dclone($self->params);
	 		$params->{offset} = $offset;
	 		
	 		$self->_chunks->{$offset} = $params;
		}
		
		while (my ($offset, $params) = each %{$self->_chunks}) {
			Plugins::Spotty::API->_call($method, sub {
				$self->_extract($offset, shift);
				delete $self->_chunks->{$offset};

				if (!scalar keys %{$self->_chunks}) {
					$self->_getDone();
				}
			}, GET => $params) 
		}
	}, GET => $self->params);
}

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
package Plugins::Spotty::API::Pipeline;

# do parallel, asynchronous calls to the Spotify API, re-ordering results in expected order

use strict;

use base qw(Slim::Utils::Accessor);
use List::Util qw(min);

use Plugins::Spotty::API qw( SPOTIFY_LIMIT DEFAULT_LIMIT );
use Slim::Utils::Log;

# make sure we don't iterate infinitely: maximum theoretical number of chunks plus some slack
sub MAX_ITERATIONS {
	10 + (Plugins::Spotty::API::_DEFAULT_LIMIT()/SPOTIFY_LIMIT);
}

__PACKAGE__->mk_accessor( rw => qw(
	spottyAPI
	method limit params
	extractorCb	cb
	_data _chunks
	_pipeId _inflight
) );

my $log = logger('plugin.spotty');

# Per-Pipeline correlation ID generator for debug request/response tracing.
# Renders as 8 hex chars; collision risk negligible within a single LMS session.
my $_pipeCounter = 0;
sub _genPipeId {
	my $self = shift;
	$_pipeCounter++;
	require Scalar::Util;
	my $mix = (Scalar::Util::refaddr($self) || 0) ^ ($_pipeCounter * 0x9E3779B1);
	return sprintf('%08x', $mix & 0xFFFFFFFF);
}

sub new {
	my $class = shift;
	
	my $self = $class->SUPER::new();

	$self->spottyAPI(shift);
	$self->method(shift);
	$self->extractorCb(shift);
	$self->cb(shift);
	$self->params(Storable::dclone(shift || {}));
	
	# default to conservative number
	$self->limit($self->params->{limit} || DEFAULT_LIMIT);
	$self->params->{limit} = delete $self->params->{_chunkSize} || SPOTIFY_LIMIT;
	$self->params->{limit} = min($self->limit, $self->params->{limit});
	
	$self->_data({});
	$self->_chunks(delete $self->params->{chunks} || {});

	$self->_pipeId( $self->_genPipeId() );
	$self->_inflight(0);

	return $self;
}

# get the first chunk of data, then run async calls if more results are available
sub get {
	my ($self) = @_;
	
	# if we already have a list of chunks we can run in parallel right away
	if ( scalar keys %{$self->_chunks} ) {
		$self->_iterateChunks();
	}
	# otherwise grabe the first chunk and decide whether to continue or not
	else {
		$self->_inflight(($self->_inflight || 0) + 1);

		# Forward Pipeline ref so API::_call can correlate REQ/RES trace lines by pipe ID.
		$self->spottyAPI->_call($self->method, sub {
			my ($result, $response) = @_;

			# tell follow-up queries to return cached data without re-validation, if we got a cached result back
			if ($response && ref $response && $response->headers && ref $response->headers && $response->headers->{'x-spotty-cached-response'}) {
				$self->params->{_no_revalidate} = 1;
			}

			my ($count, $next) = $self->_extract(0, $result);

#			warn Data::Dump::dump($count, $self->params->{limit}, $self->limit, SPOTIFY_LIMIT, $next);
			# no need to run more requests if there's no more than the received results
			if ( $count <= $self->params->{limit} || $self->limit <= $self->params->{limit} ) {
				$self->_getDone();
				return;
			}
			# some calls are paging by ID ("after=abc123") - we have to run them serially
			elsif ( $next && $next !~ /\boffset=/ && $next =~ /\bafter=([a-zA-Z0-9]{22})\b/ ) {
				$self->_followAfter($1);
			}
			# some calls are paging by timestamp ("before=1234567890123") - we have to run them serially
# XXX - used by recentlyPlayed only
#			elsif ( $next && $next !~ /\boffset=/ && $next =~ /\bbefore=([0-9]{13,})\b/ ) {
#				$self->_followBefore($1);
#			}
			# most calls fortunately can page by using an offset - we can run them in parallel
			else {
				$self->_followOffset($count);
			}
		}, GET => { %{$self->params}, _pipeline => $self });
	}
}

sub _iterateChunks {
	my ($self) = @_;
	
	my $i = 0;
	
	# query all chunks in parallel, waiting for them all to return before we call the callback
	# clone data, as it might get altered in the called methods
	my $chunks = Storable::dclone($self->_chunks);
	while (my ($id, $params) = each %$chunks) {
		# Increment per-Pipeline inflight counter; decremented by AsyncRequest's wrapped callbacks.
		$self->_inflight(($self->_inflight || 0) + 1);
		$self->_call($self->method, sub {
			$self->_extract($id, shift);
			delete $self->_chunks->{$id};

			if (!scalar keys %{$self->_chunks}) {
				$self->_getDone();
			}
		}, GET => $params);
		
		# just make sure we never loop infinitely...
		if ( ++$i > MAX_ITERATIONS() ) {
			last;
		}
	}
}

sub _followAfter {
	my ($self, $id) = @_;

	# Cursor pagination is serial (one chunk at a time), so inflight hovers at 1 per Pipeline.
	$self->_inflight(($self->_inflight || 0) + 1);

	$self->spottyAPI->_call($self->method, sub {
		my ($count, $next) = $self->_extract($id, shift);

		if ( $next && $next !~ /\boffset=/ && $next =~ /\bafter=([a-zA-Z0-9]{22})\b/ ) {
			$self->_followAfter($1);
		}
		else {
			$self->_getDone();
		}
	}, GET => {
		%{$self->params},
		after => $id,
		_pipeline => $self,    # forward Pipeline ref for REQ/RES trace correlation
	})
}

=pod
# used by recentlyPlayed only
sub _followBefore {
	my ($self, $id) = @_;
	
	$self->spottyAPI->_call($self->method, sub {
		my ($count, $next) = $self->_extract($id, shift);
		
		if ( $next && $next !~ /\boffset=/ && $next =~ /\bbefore=([0-9]{13,})\b/ ) {
			$self->_followBefore($1);
		}
		else {
			$self->_getDone();
		}
	}, GET => {
		%{$self->params},
		before => $id,
	});
}
=cut

sub _followOffset {
	my ($self, $count) = @_;

	for (my $offset = $self->params->{limit}; $offset < min($count, $self->limit); $offset += $self->params->{limit}) {
		my $params = Storable::dclone($self->params);
 		$params->{offset} = $offset;
 		
 		$self->_chunks->{$offset} = $params;
	}

	main::INFOLOG && $log->is_info && $log->info("There's more data to grab, queue them up: " . Data::Dump::dump($self->_chunks));
			
	# run requests in parallel
	$self->_iterateChunks();
}

sub _call {
	my $self = shift;
	# Tag params with this Pipeline's ref so API::_call can emit correlated REQ/RES trace lines.
	# Args shape: ($method, $cb, $type, $params).
	my ($method, $cb, $type, $params) = @_;
	$params ||= {};
	$params->{_pipeline} = $self;
	$self->spottyAPI->_call($method, $cb, $type, $params);
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

	my ($chunk, $count, $next) = $self->extractorCb->($results, $offset);

	if ($chunk && ref $chunk) {
		$self->_data->{$offset} = $chunk;
	}
	
	return ($count || 0, $next);
}

1;
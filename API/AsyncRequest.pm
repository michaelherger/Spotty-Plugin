package Plugins::Spotty::API::AsyncRequest;

=pod
	This class extends Slim::Networking::SimpleAsyncHTTP to deal with the 429 error (rate limiting).
	It requires LMS 8.5.1 or newer.
=cut

use strict;

use base qw(Slim::Networking::SimpleAsyncHTTP);

sub shouldNotRevalidate {
	my ($self, $data) = @_;
	return delete $self->_params->{no_revalidate};
}

# if we send a cached response, tell the callback about it
sub sendCachedResponse {
	my $self = shift;

	$self->cachedResponse->{headers}->{'x-spotty-cached-response'} = 1;

	$self->SUPER::sendCachedResponse();

	return;
}

1;
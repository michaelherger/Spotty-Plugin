package Plugins::Spotty::API::AsyncRequest;

=pod
	This class extends Slim::Networking::SimpleAsyncHTTP to add PUT support,
	and deal with the 429 error (rate limiting).

	Unfortunately the only method we'd need to override (onError) is not a class
	method. Therefore we have to duplicate _createHTTPRequest, too.
=cut

use strict;

use base qw(Slim::Networking::SimpleAsyncHTTP);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

use HTTP::Date ();
use HTTP::Request;

use constant API_URL => 'https://api.spotify.com/v1/%s';

my $prefs = preferences('server');

my $log = logger('network.asynchttp');

# SPOTTY
my $spottyLog = logger('plugin.spotty');
# /SPOTTY


sub put { shift->_createHTTPRequest( PUT => @_ ) }

# Parameters are passed to Net::HTTP::NB::formatRequest, meaning you
# can override default headers, and pass in content.
# Examples:
# $http->post("www.somewhere.net", 'conent goes here');
# $http->post("www.somewhere.net", 'Content-Type' => 'application/x-foo', 'Other-Header' => 'Other Value', 'conent goes here');
sub _createHTTPRequest {
	my $self = shift;
	my $type = shift;
	my $url  = sprintf(API_URL, shift);

	$self->type( $type );
	$self->url( $url );

	my $params = $self->_params;
	my $client = $params->{params}->{client};

	main::DEBUGLOG && $log->debug("${type}ing $url");

	# Check for cached response
	if ( $params->{cache} ) {

		my $cache = Slim::Utils::Cache->new();

		if ( my $data = $cache->get( Slim::Networking::SimpleAsyncHTTP::_cacheKey($url, $client) ) ) {
			$self->cachedResponse( $data );

# SPOTTY - specific change starts here
#			# If the data was cached within the past 5 minutes,
#			# return it immediately without revalidation, to improve
#			# UI experience
#			if ( $data->{_no_revalidate} || time - $data->{_time} < 300 ) {
#
#			if we got a 304 (data not change) on the first of a series of requests, return
#			cached follow up requests without re-validation
			if ( delete $params->{no_revalidate} ) {

				main::INFOLOG && $spottyLog->is_info && $spottyLog->info("Using cached response [$url]");
# /SPOTTY

				return $self->sendCachedResponse();
			}
		}
	}

	my $timeout
		=  $params->{Timeout}
		|| $params->{timeout}
		|| $prefs->get('remotestreamtimeout');

	my $request = HTTP::Request->new( $type => $url );

	if ( @_ % 2 ) {
		$request->content( pop @_ );
	}

	# If cached, add If-None-Match and If-Modified-Since headers
	my $data = $self->cachedResponse;
	if ( $data && ref $data && $data->{headers} ) {
		# gzip encoded results come with a -gzip postfix which needs to be removed, or the etag would not match
		my $etag = $data->{headers}->header('ETag') || undef;
		$etag =~ s/-gzip// if $etag;

		# if the last_modified value is a UNIX timestamp, convert it
		my $lastModified = $data->{headers}->last_modified || undef;
		$lastModified = HTTP::Date::time2str($lastModified) if $lastModified && $lastModified !~ /\D/;

		unshift @_, (
			'If-None-Match'     => $etag,
			'If-Modified-Since' => $lastModified
		);
	}

	# request compressed data if we have zlib
	if ( Slim::Networking::SimpleAsyncHTTP::hasZlib() && !$params->{saveAs} ) {
		unshift @_, (
			'Accept-Encoding' => 'deflate, gzip', # deflate is less overhead than gzip
		);
	}

	# Add Accept-Language header
	my $lang;
	if ( $client ) {
		$lang = $client->languageOverride(); # override from comet request
	}

	$lang ||= $prefs->get('language') || 'en';
	$lang =~ s/_/-/g;

	unshift @_, (
		'Accept-Language' => lc($lang),
	);

	if ( @_ ) {
		$request->header( @_ );
	}

	my $http = Slim::Networking::Async::HTTP->new;
	$http->send_request( {
		request     => $request,
		maxRedirect => $params->{maxRedirect},
		saveAs      => $params->{saveAs},
		Timeout     => $timeout,
		onError     => \&onError,
		onBody      => \&Slim::Networking::SimpleAsyncHTTP::onBody,
		passthrough => [ $self ],
	} );
}


sub onError {
	my ( $http, $error, $self ) = @_;

	my $uri = $http->request->uri;

	# If we have a cached copy of this request, we can use it
	if ( $self->cachedResponse ) {

		$log->warn("Failed to connect to $uri, using cached copy. ($error)");

		return $self->sendCachedResponse();
	}
	else {
		$log->warn("Failed to connect to $uri ($error)");
	}

	$self->error( $error );

	main::PERFMON && (my $now = AnyEvent->time);

	# return the response object in addition to the standard values from SimpleAsyncHTTP
	# SPOTTY
	$self->ecb->( $self, $error, $http->response );
	# /SPOTTY

	main::PERFMON && $now && Slim::Utils::PerfMon->check('async', AnyEvent->time - $now, undef, $self->ecb);

	return;
}

# if we send a cached response, tell the callback about it
# SPOTTY
sub sendCachedResponse {
	my $self = shift;

	$self->cachedResponse->{headers}->{'x-spotty-cached-response'} = 1;

	$self->SUPER::sendCachedResponse();

	return;
}
# /SPOTTY


1;
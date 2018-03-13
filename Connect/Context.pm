package Plugins::Spotty::Connect::Context;

=pod
	Unfortunately we don't always get the context in which a track is being played.
	Therefore we add some rough rules here:

	- if we have a context (album, playlist), get the list of tracks to be played.
	  Whenever a track is played, it's removed from that list. When the list is
	  empty, stop playback.

	- if we don't have any context, keep a list of tracks we played. When the next
	  track to be played has been played before, we're going to assume that we've
	  played them all. This would effectively not allow us to play the same track
	  in the same context twice. Or if you started on track 3, the playback would
	  wrap and play tracks 1 & 2 last.

	Fortunately albums and playlists are the most popular items to be played.
=cut

use strict;

use base qw(Slim::Utils::Accessor);

use Slim::Utils::Log;
use Slim::Utils::Cache;
use Slim::Utils::Prefs;
# use Slim::Utils::Timers;

use Plugins::Spotty::API qw(uri2url);

use constant HISTORY_KEY => 'spotty-connect-history';
use constant KNOWN_TRACKS_KEY => 'spotty-connect-known-tracks';

__PACKAGE__->mk_accessor( rw => qw(
	time
	shuffled
	_id
	_api
	_cache
	_context
	_contextId
	_lastURL
) );

#my $prefs = preferences('plugin.spotty');
my $log = logger('plugin.spotty');

my $memoryCache;

sub new {
	my ($class, $api) = @_;

	my $self = $class->SUPER::new();

	$log->info("Create new Connect context...");

	$self->time(time());
	$self->_api($api);
	$self->_id(Slim::Utils::Misc::createUUID());
	$self->_cache(
		preferences('server')->get('dbhighmem') > 1
		? Plugins::Spotty::Connect::MemoryCache->new()
		: Slim::Utils::Cache->new()
	);

	$self->reset();

	return $self;
}

sub update {
	my ($self, $context) = @_;

	if ( $context && ref $context && $context->{context} && ref $context->{context}
		&& ($context->{context}->{uri} || '') ne $self->_contextId
	) {
		$self->reset();
		$self->_context($context->{context});
		$self->_contextId($context->{context}->{uri});
		$self->shuffled($context->{context}->{shuffle_state});
		$self->_lastURL('');

		if ($self->_context->{type} =~ /album|playlist/) {
			$self->_api->trackURIsFromURI( sub {
				my ($tracks) = @_;

				if ($tracks && ref $tracks) {
					my $knownTracks;
					my $lastTrack = $tracks->[-1];
					my @lastTrackOccurrences;

					my $x = 0;
					map {
						push @lastTrackOccurrences, $x if $_ eq $lastTrack;
						$knownTracks->{uri2url($_)}++;
						$x++;
					} @{ $tracks || [] };

					# TODO - use @lastTrackOccurrences to define a smarter filter, respecting previous track(s) or similar

					$self->_lastURL(uri2url($lastTrack)) unless scalar @lastTrackOccurrences > 1;
					$self->_setCache(KNOWN_TRACKS_KEY, $knownTracks);
				}
			}, $self->_contextId );
		}

		# when we're called, we're already playing an item of our context
		$self->addPlay(uri2url($context->{item}->{uri}));
	}
}

sub reset {
	my $self = shift;

	$self->shuffled(0);
	$self->_context({});
	$self->_contextId('');
	$self->_cache->remove($self->_id . HISTORY_KEY);
	$self->_cache->remove($self->_id . KNOWN_TRACKS_KEY);
	$self->_lastURL('');
}

sub addPlay {
	my ($self, $url) = @_;

	main::INFOLOG && $log->info("Adding track to played list: $url");

	if ( my $knownTracks = $self->_getCache(KNOWN_TRACKS_KEY) ) {
		if ( $knownTracks->{$url} ) {
			$knownTracks->{$url}--;
			delete $knownTracks->{$url} if !$knownTracks->{$url};

			$self->_setCache(KNOWN_TRACKS_KEY, $knownTracks)
		}
	}

	my $history = $self->_getCache(HISTORY_KEY) || {};
	$history->{$url}++;
	$self->_setCache(HISTORY_KEY, $history);
}

sub getPlay {
	my ($self, $url) = @_;
	my $history = $self->_getCache(HISTORY_KEY) || {};

	main::INFOLOG && $log->info("Has $url been played? " . ($history->{$url} ? 'yes' : 'no'));

	return $history->{$url};
}

sub hasPlay {
	return $_[0]->getPlay($_[1]) ? 1 : 0;
}

sub isLastTrack {
	my ($self, $url) = @_;

	# if we have a known last track, and this $url is it, then we're at the end
	return 1 if $self->_lastURL && $self->_lastURL eq $url && !$self->shuffled;

	# if we had a list with known tracks, but it's empty now, then we've played it all
	if ( my $knownTracks = $self->_getCache(KNOWN_TRACKS_KEY) ) {
		return 1 if !keys %$knownTracks;
	}

	return 0;
}

sub _setCache {
	my ($self, $key, $value, $expiry) = @_;
	$self->_cache->set($self->_id . $key, $value);
}

sub _getCache {
	my ($self, $key) = @_;
	return $self->_cache->get($self->_id . $key);
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

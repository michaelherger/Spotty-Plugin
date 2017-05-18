package Plugins::Spotty::OPML;

use strict;

use Slim::Utils::Strings qw(string cstring);

sub handleFeed {
	my ($client, $cb, $args) = @_;

	# Build main menu structure
	my $items = [];

=pod	
	my $player = $c->forward( '/api/current_player', [] );
	
	if ( $player && $s->show_recent && $s->has_recent_searches($player->mac) ) {
		push @{$items}, {
			name  => cstring($client, 'SEARCH'),
			type  => 'link',
			image => 'plugins/Spotty/html/images/search.png',
			#url   => $c->forward( 'url', [ 'recent_searches' ] ),
		};
	}
	else {
=cut	
		push @{$items}, {
			name  => cstring($client, 'SEARCH'),
			type  => 'search',
			image => 'plugins/Spotty/html/images/search.png',
			#url   => $c->forward( 'url', [ 'search?q={QUERY}' ] ),
			setSelectedIndex => 1,
		};
#	}
	
	push @{$items}, {
		name  => cstring($client, 'PLUGIN_SPOTTY_WHATS_NEW'),
		type  => 'link',
		image => 'plugins/Spotty/html/images/whatsnew.png',
		#url   => $c->forward( 'url', [ 'whatsnew' ] ),
	},
	{
		name  => cstring($client, 'PLUGIN_SPOTTY_TOP_TRACKS'),
		type  => 'playlist',
		image => 'plugins/Spotty/html/images/toptracks.png',
		#url   => $c->forward( 'url', [ 'playlist?uri=' . ($topuri{ $s->country } || $topuri{XX}) ] ),
	},
	{
		name  => cstring($client, 'PLUGIN_SPOTTY_GENRES_MOODS'),
		type  => 'link',
		image => 'plugins/Spotty/html/images/inbox.png',
		#url   => $c->forward( 'url', [ 'categories' ] ),
	};
	
=pod
	if ( my ($message, $lists) = $s->featuredPlaylists($c->stash->{user}->timezone) ) {
		my $playlists = $c->forward( 'playlist_list', [ $lists ] );
		
		push @$items, {
			name    => $message,
			image   => 'plugins/Spotty/html/images/inbox.png',
			outline => $playlists
		};
	}
=cut
	
	push @$items, {
		name  => cstring($client, 'ALBUMS'),
		type  => 'link',
		image => 'plugins/Spotty/html/images/album.png',
		#url   => $c->forward( 'url', [ 'myAlbums' ] ),
	},{
		name  => cstring($client, 'ARTISTS'),
		type  => 'link',
		image => 'plugins/Spotty/html/images/account.png',
		#url   => $c->forward( 'url', [ 'myArtists' ] ),
	},{
		name  => cstring($client, 'PLAYLISTS'),
		type  => 'link',
		image => 'plugins/Spotty/html/images/playlist.png',
		#url   => $c->forward( 'url', [ 'playlists' ]),
	};
	
	$cb->({
		items => $items,
	});
}

1;

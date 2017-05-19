package Plugins::Spotty::OPML;

use strict;

use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::API;

use Slim::Utils::Strings qw(string cstring);
use Slim::Utils::Log;

use constant IMG_TRACK => '/html/images/cover.png';
use constant IMG_ALBUM => 'plugins/Spotty/html/images/album.png';
use constant IMG_SEARCH => 'plugins/Spotty/html/images/search.png';
use constant IMG_WHATSNEW => 'plugins/Spotty/html/images/whatsnew.png';
use constant IMG_ACCOUNT => 'plugins/Spotty/html/images/account.png';

Plugins::Spotty::API->init();

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
			image => IMG_SEARCH,
			url   => \&search,
#			setSelectedIndex => 1,
		};
#	}
	
	push @{$items}, {
		name  => cstring($client, 'PLUGIN_SPOTTY_WHATS_NEW'),
		type  => 'link',
		image => IMG_WHATSNEW,
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
		image => IMG_ALBUM,
		#url   => $c->forward( 'url', [ 'myAlbums' ] ),
	},{
		name  => cstring($client, 'ARTISTS'),
		type  => 'link',
		image => IMG_ACCOUNT,
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

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{query};
	$params->{type}   ||= $args->{type};

	my $type = $params->{type};

	Plugins::Spotty::API->search(sub {
		my ($results) = @_;
		
		my @items;
		
		if ( !$type ) {
			push @items, {
				name  => cstring($client, 'ARTISTS'),
				image => IMG_ACCOUNT,
				url   => \&search,
				passthrough => [{
					query => $params->{search},
					type  => 'artist'
				}]
			},{
				name  => cstring($client, 'ALBUMS'),
				image => IMG_ALBUM,
				url   => \&search,
				passthrough => [{
					query => $params->{search},
					type  => 'album'
				}]
			};
			push @items, @{trackList($client, $results)};
			
			splice(@items, $params->{quantity}) if !$params->{index} && $params->{quantity} < scalar @items;
		}
		elsif ($type eq 'album') {
			push @items, @{albumList($client, $results)};
		}
		elsif ($type eq 'artist') {
			push @items, @{artistList($client, $results)};
		}
		elsif ($type eq 'track') {
			push @items, @{trackList($client, $results)};
		}
		else {
			warn Data::Dump::dump($results);
		}

		$cb->({ items => \@items });
	}, {
		query => $params->{search},
		type  => $params->{type},
	});
}

sub album {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Spotty::API->album(sub {
		my ($album) = @_;

		my $items = trackList($client, $album->{tracks}, { show_numbers => 1 });
		$cb->({ items => $items });
	},{
		uri => $params->{uri} || $args->{uri}
	});
}

sub artist {
	my ($client, $cb, $params, $args) = @_;
	
	my $uri = $params->{uri} || $args->{uri};
	
	# get artist, tracks and albums asynchronously, only process once we have it all
	$client->pluginData(artistInfo => {});
	
	Plugins::Spotty::API->artist(sub {
		_gotArtistData($client, $cb, artist => $_[0]);
	},{
		uri => $uri
	}, );
	
	Plugins::Spotty::API->artistTracks(sub {
		_gotArtistData($client, $cb, tracks => $_[0]);
	}, {
		uri => $uri
	});
	
	Plugins::Spotty::API->artistAlbums(sub {
		_gotArtistData($client, $cb, albums => $_[0]);
	}, {
		uri => $uri
	});
}

sub _gotArtistData {
	my ($client, $cb, $type, $data) = @_;

	my $artistInfo = $client->pluginData('artistInfo') || {};
	$artistInfo->{$type} = $data;

	$client->pluginData(artistInfo => $artistInfo);
	
	return unless $artistInfo->{tracks} && $artistInfo->{albums} && $artistInfo->{artist};

	my $artist = $artistInfo->{artist};
	my $items = [];
	
	# Split albums into compilations (albums with a different primary artist name) and regular albums
	# XXX Need a better way to determine album type. Unfortunately album->{album_type} doesn't work
	my $albums = albumList($client, [ grep { $_->{artist} eq $artist->{name} } @{ $artistInfo->{albums} } ]);
	my $comps  = albumList($client, [ grep { $_->{artist} ne $artist->{name} } @{ $artistInfo->{albums} } ]);
	
	if ( scalar @$albums ) {		
		push @$items, {
			name  => cstring($client, 'ALBUMS'),
			items => $albums,
		};
	}
	
	if ( scalar @$comps ) {		
		push @$items, {
			name  => cstring($client, 'PLUGIN_SPOTTY_COMPILATIONS'),
			items => $comps,
		};
	}
	
	push @$items, {
		type  => 'playlist',
		name  => cstring($client, 'PLUGIN_SPOTTY_TOP_TRACKS'),
		items => trackList($client, $artistInfo->{tracks}),
	},{
		type => 'playlist',
		name => cstring($client, 'SONGS'),
		url => \&search,
		passthrough => [{
			query => 'artist:"' . $artist->{name} . '"',
			type  => 'track'
		}]
	} if @{$artistInfo->{tracks}};

	$cb->({ items => $items });
}

sub trackList {
	my ( $client, $tracks, $args ) = @_;
	
	my $show_numbers = $args->{show_numbers} || 0;
	my $image        = $args->{image};
	
	my $items = [];
	
	
	my $count = 0;
	for my $track ( @{$tracks} ) {
		# 2 different formats of track data, grr
		# First form is used for starred, album track lists
		# Second form is used for track search results
		if ( $track->{uri} ) {
			my $title  = $show_numbers ? $track->{track_number} . '. ' . $track->{name} : $track->{name};
			my $artist = join( ', ', map { $_->{name} } @{ $track->{artists} } );
			my $album  = $track->{album}->{name};
		
			my ($track_uri) = $track->{uri} =~ /^spotify:(track:.+)/;
			
			if ( my $i = $track->{album}->{image} ) {
				$image = $i;
			}

			my $trackinfo = [];
			push @$trackinfo, {
				name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . sprintf('%s:%02s', int($track->{duration_ms} / 60_000), $track->{duration_ms} % 60_000),
				type => 'text',
			} if $track->{duration_ms};
		
			push @{$items}, {
			#	type      => 'link',
				name      => sprintf('%s %s %s %s %s', $title, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $album),
				line1     => $title,
				line2     => "${artist} \x{2022} ${album}",
				play      => 'spotify://' . $track_uri,
#				URL       => $c->forward( 'url', [ 'track', { uri => $track->{uri} } ] ),
				image     => $image || IMG_TRACK,
				on_select => 'play',
#				items => [],
				playall   => 1,
				passthrough => [{
					uri => $track->{uri}
				}]
			};
		}
=pod
		else {
			my $title  = $show_numbers ? $track->{'track-number'} . '. ' . $track->{name} : $track->{name};
			my $artist = join( ', ', map { $_->{name} } @{ $track->{artists} } );
			my $album  = $track->{album}->{name};
		
			my ($track_uri) = $track->{href} =~ /^spotify:(track:.+)/;
			
			my $text = $title . ' ' . $c->string('BY') . ' ' . $artist;
			my $line2 = $artist;
			if ( $album ) {
				$text .= ' ' . $c->string('FROM') . ' ' . $album;
				$line2 .= " \x{2022} ${album}";
			}
			
			if ( my $i = $track->{image} ) {
				$image = $i;
			}
			
			push @{$items}, {
				type      => 'link',
				text      => $text,
				line1     => $title,
				line2     => $line2,
				play      => 'spotify://' . $track_uri,
				URL       => $c->forward( 'url', [ 'track', { uri => $track->{href} } ] ),
				image     => $image || $track_placeholder,
				on_select => 'play',
				duration  => int( $track->{length} + 0.5 ),
				playall   => 1,
			};
		}
=cut
	}
	
	return $items;
}

sub albumList {
	my ( $client, $albums ) = @_;
	
	my $items = [];
	
	for my $album ( @{$albums} ) {		
		my $artists = join( ', ', map { $_->{name} } @{ $album->{artists} } );
					
		push @{$items}, {
			type  => 'playlist',
			name  => $album->{name} . ($artists ? (' ' . cstring($client, 'BY') . ' ' . $artists) : ''),
			line1 => $album->{name},
			line2 => $artists,
			url   => \&album,
			image => $album->{image} || IMG_ALBUM,
			passthrough => [{
				uri => $album->{uri}
			}]
		};
	}
	
	return $items;
}

sub artistList {
	my ( $client, $artists, $myAlbumsOnly ) = @_;
	
	my $items = [];

	for my $artist ( @{$artists} ) {
		push @{$items}, {
			name => $artist->{name},
			image => $artist->{image} || IMG_ACCOUNT,
			url  => \&artist,
			passthrough => [{
				uri => $artist->{uri},
				myAlbumsOnly => $myAlbumsOnly ? 1 : 0,
			}]
		};
	}
	
	return $items;
}



1;

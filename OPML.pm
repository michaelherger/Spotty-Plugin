package Plugins::Spotty::OPML;

use strict;

use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::API;

use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use constant IMG_TRACK => '/html/images/cover.png';
use constant IMG_ALBUM => 'plugins/Spotty/html/images/album.png';
use constant IMG_PLAYLIST => 'plugins/Spotty/html/images/playlist.png';
use constant IMG_COLLABORATIVE => 'plugins/Spotty/html/images/playlist-collab.png';
use constant IMG_SEARCH => 'plugins/Spotty/html/images/search.png';
use constant IMG_WHATSNEW => 'plugins/Spotty/html/images/whatsnew.png';
use constant IMG_ACCOUNT => 'plugins/Spotty/html/images/account.png';

use constant MAX_RECENT => 50;

my $prefs = preferences('plugin.spotty');

my %topuri = (
	AT => 'spotify:user:spotify:playlist:1f9qd5qJzIpYWoQm7Ue2uV',
	AU => 'spotify:user:spotify:playlist:6lQMloCb0llJywSRoj3jAO',
	BE => 'spotify:user:spotify:playlist:13eazhZmMdf628WMqru34A',
	CH => 'spotify:user:spotify:playlist:1pDTi8rVKDQKGMb2NlJmDl',
	DE => 'spotify:user:spotify:playlist:4XEnSf75NmJPBX1lTmMiv0',
	DK => 'spotify:user:spotify:playlist:2nQqWLiGEXLybDLu15ZmVx',
	ES => 'spotify:user:spotify:playlist:4z0aU3aX74LH6uWHTygTfV',
	FI => 'spotify:user:spotify:playlist:6FZEbmeeb9aGiqSLAmLFJW',
	FR => 'spotify:user:spotify:playlist:6FNC5Kuzhyt35pXtyqF6xq',
	GB => 'spotify:user:spotify:playlist:7s8NU4MWP9GOSEXVwjcum4',
	NL => 'spotify:user:spotify:playlist:7Jus9jsdpexXTXh2RVv8bZ',
	NO => 'spotify:user:spotify:playlist:1BnqqOPMu8w08F1XpOzlwR',
	NZ => 'spotify:user:spotify:playlist:1TRzxr8LVu3OxdoMlabuNG',
	SE => 'spotify:user:spotify:playlist:0Ks7MCeAZeYlBOmSLHmZ2o',
	US => 'spotify:user:spotify:playlist:5nPXGgfCxfRpJHGRY4sovK',
	
	XX => 'spotify:user:spotify:playlist:4hOKQuZbraPDIfaGbM3lKI',	# fallback "Top 100 on Spotify"
);

sub handleFeed {
	my ($client, $cb, $args) = @_;

	if (!$client) {
		$cb->({
			items => [{
				name => string('PLUGIN_SPOTTY_NO_PLAYER_CONNECTED'),
				type => 'text'
			}]
		});
		
		return;
	}

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);

	$spotty->featuredPlaylists( sub {
		my ($lists, $message) = @_;
		
		# Build main menu structure
		my $items = [];
	
		if ( hasRecentSearches() ) {
			push @{$items}, {
				name  => cstring($client, 'SEARCH'),
				type  => 'link',
				image => IMG_SEARCH,
				url   => \&recentSearches,
			};
		}
		else {
			push @{$items}, {
				name  => cstring($client, 'SEARCH'),
				type  => 'search',
				image => IMG_SEARCH,
				url   => \&search,
			};
		}
		
		push @{$items}, {
			name  => cstring($client, 'PLUGIN_SPOTTY_WHATS_NEW'),
			type  => 'link',
			image => IMG_WHATSNEW,
			url   => \&whatsNew
		},
		{
			name  => cstring($client, 'PLUGIN_SPOTTY_TOP_TRACKS'),
			type  => 'playlist',
			image => 'plugins/Spotty/html/images/toptracks.png',
			url   => \&playlist,
			passthrough => [{
				uri => $topuri{$spotty->country()} || $topuri{XX}
			}]
		},
		{
			name  => cstring($client, 'PLUGIN_SPOTTY_GENRES_MOODS'),
			type  => 'link',
			image => 'plugins/Spotty/html/images/inbox.png',
			url   => \&categories
		};
		
		if ( $message && $lists && ref $lists && scalar @$lists ) {
			push @$items, {
				name  => $message,
				image => 'plugins/Spotty/html/images/inbox.png',
				items => playlistList($client, $lists)
			};
		}
		
		push @$items, {
			name  => cstring($client, 'ALBUMS'),
			type  => 'link',
			image => IMG_ALBUM,
			url   => \&myAlbums,
		},{
			name  => cstring($client, 'ARTISTS'),
			type  => 'link',
			image => IMG_ACCOUNT,
			url   => \&myArtists
		},{
			name  => cstring($client, 'PLAYLISTS'),
			type  => 'link',
			image => IMG_PLAYLIST,
			url   => \&playlists
		};
		
		$cb->({
			items => $items,
		});
	} );
}

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{query};
	$params->{type}   ||= $args->{type};

	my $type = $params->{type};
	
	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);
	
	# search for users is different...
	if ($type eq 'user') {
		$spotty->user(sub {
			my ($result) = @_;
			
			my $items = [];
			if ($result && $result->{id}) {
				my $title = $result->{id};

				push @$items, {
					type => 'text',
					name => $result->{display_name} ? ($result->{display_name} . " ($title)") : $title,
					image => $result->{image} || IMG_ACCOUNT,
				},{
					type  => 'link',
					name  => cstring($client, 'PLAYLISTS'),
					image => IMG_PLAYLIST,
					url   => \&playlists,
					passthrough => [{
						user => $result->{id}
					}],
				};
			}
			
			$cb->({ items => $items });
		}, $params->{search});
		return;
	}

	$spotty->search(sub {
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
			},{
				name  => cstring($client, 'PLAYLISTS'),
				image => IMG_PLAYLIST,
				url   => \&search,
				passthrough => [{
					query => $params->{search},
					type  => 'playlist'
				}]
			},{
				name  => cstring($client, 'PLUGIN_SPOTTY_USERS'),
				url   => \&search,
				image => IMG_ACCOUNT,
				passthrough => [{
					query => $params->{search},
					type  => 'user'
				}]
			};
			push @items, @{trackList($client, $results)};
			
			addRecentSearch($params->{search}) unless $args->{recent};

			splice(@items, $params->{quantity}) if defined $params->{index} && !$params->{index} && $params->{quantity} < scalar @items;
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
		elsif ($type eq 'playlist') {
			push @items, @{playlistList($client, $results)};
		}
		else {
			warn Data::Dump::dump($results);
		}

		$cb->({ items => \@items });
	}, {
		query => $params->{search},
		type  => $type || 'track',
	});
}

sub whatsNew {
	my ($client, $cb, $params) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->newReleases(sub {
		my ($albums) = @_;
	
		my $items = albumList($client, $albums);
		
		$cb->({ items => $items });
	});
}

sub topTracks {
	my ($client, $cb, $params) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->topTracks(sub {
		my ($tracks) = @_;
	
		my $items = tracksList($client, $tracks);
		
		$cb->({ items => $items });
	});
}

sub categories {
	my ($client, $cb, $params) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->categories(sub {
		my ($result) = @_;
		
		my $items = [];
		for my $item ( @{$result} ) {
			push @{$items}, {
				type  => 'link',
				name  => $item->{name},
				url   => \&category,
				passthrough => [{ 
					id => $item->{id},
					title => $item->{name},
				}],
				image => $item->{image},
			};
		}

		$cb->({ items => $items })
	});
}

sub myAlbums {
	my ($client, $cb, $params) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->myAlbums(sub {
		my ($result) = @_;

		my $items = albumList($client, $result);
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_STUFF'),
			type => 'text',
		} unless scalar @$items;
		
		$cb->({ items => $items });
	});
}

sub myArtists {
	my ($client, $cb, $params) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->myArtists(sub {
		my ($result) = @_;

		my $items = artistList($client, $result, $prefs->get('myAlbumsOnly'));
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_STUFF'),
			type => 'text',
		} unless scalar @$items;
		
		$cb->({ items => $items });
	});
}

sub playlists {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->playlists(sub {
		my ($result) = @_;

		my $items = playlistList($client, $result);
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_STUFF'),
			type => 'text',
		} unless scalar @$items;
		
		$cb->({ items => $items });
	},{
		user => $params->{user} || $args->{user}
	});
}

sub album {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->album(sub {
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
	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);
	
	# get artist, tracks and albums asynchronously, only process once we have it all
	$client->pluginData(artistInfo => {});
	
	$spotty->artist(sub {
		_gotArtistData($client, $cb, artist => $_[0]);
	},{
		uri => $uri
	}, );
	
	$spotty->artistTracks(sub {
		_gotArtistData($client, $cb, tracks => $_[0]);
	}, {
		uri => $uri
	});
	
	$spotty->artistAlbums(sub {
		my $albums = shift;
		
		# Sort albums by release date
		$albums = [ sort { $b->{released} <=> $a->{released} } @$albums ];

		# some users only want to see the albums they have added to their library when browsing library artists
		if ( $args->{myAlbumsOnly} ) {
			$spotty->isInMyAlbums(sub {
				my $inMyAlbums = shift || {};
				_gotArtistData($client, $cb, albums => [ grep { $inMyAlbums->{$_->{id}} } @$albums ]);
			}, [ map { $_->{id} } @$albums ]);
		}
		else {
			_gotArtistData($client, $cb, albums => $albums);
		}
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

	my $artist = $artistInfo->{artist} || {};
	my $artistURI = $artist->{uri};
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

	push @$items, {
		type => 'playlist',
		on_select => 'play',
		name => cstring($client, 'PLUGIN_SPOTTY_ARTIST_RADIO'),
		url  => \&artistRadio,
		passthrough => [{ uri => $artistURI }],
	},{
		name => cstring($client, 'PLUGIN_SPOTTY_RELATED_ARTISTS'),
		url  => \&relatedArtists,
		passthrough => [{ uri => $artistURI }],
	},{
		name => cstring($client, 'PLUGIN_SPOTTY_FOLLOW_ARTIST'),
		url  => \&followArtist,
		passthrough => [{
			name => $artist->{name}, 
			uri => $artistURI
		}],
		nextWindow => 'refresh'
	};

	$cb->({ items => $items });

	# free some memory
	$client->pluginData(artistInfo => {});
}

sub relatedArtists {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->relatedArtists(sub {
		$cb->({ items => artistList($client, shift) });
	}, $params->{uri} || $args->{uri});
}

sub followArtist {
	my ($client, $cb, $params, $args) = @_;

	my $id = $params->{uri} || $args->{uri};
	$id =~ s/.*artist://;

	Plugins::Spotty::Plugin->getAPIHandler($client)->followArtist(sub {
		# response is empty on success, otherwise error object we can show
		$cb->({ items => [ shift || {
			name => cstring($client, 'PLUGIN_SPOTTY_FOLLOWING_ARTIST') . ' ' . ($params->{name} || $args->{name}),
			showBriefly => 1
		} ] });
	}, $id);
}

sub playlist {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->playlist(sub {
		my ($playlist) = @_;

		my $items = trackList($client, $playlist);
		$cb->({ items => $items });
	},{
		uri => $params->{uri} || $args->{uri}
	});
}

sub category {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->categoryPlaylists(sub {
		my ($playlists) = @_;

		my $items = playlistList($client, $playlists);
		$cb->({ items => $items });
	}, $params->{id} || $args->{id} );
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
				image     => $image || IMG_TRACK,
				on_select => 'play',
				duration  => $track->{duration_ms} / 1000,
				playall   => 1,
				passthrough => [{
					uri => $track->{uri}
				}]
			};
		}
		else {
			logError("unsupported track data structure?\n" . Data::Dump::dump($track));
		}
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

sub playlistList {
	my ( $client, $lists ) = @_;
	
	$lists ||= [];

	my $items = [];
	my $username = Plugins::Spotty::Plugin->getAPIHandler($client)->username;
	
	for my $list ( @{$lists} ) {
		my $item = {
			name  => $list->{name} || $list->{title},
			type  => 'playlist',
			image => $list->{image} || ($list->{collaborative} ? IMG_COLLABORATIVE : IMG_PLAYLIST),
			url   => \&playlist,
			passthrough => [{
				uri => $list->{uri}
			}]
		};
		
		my $creator = $list->{creator};
		$creator ||= $list->{owner}->{id} if $list->{owner};
		
		if ( $creator && $creator ne $username ) {
			$item->{line2} = cstring($client, 'BY') . ' ' . $creator;
		}
		
		push @{$items}, $item;
	}

	return $items;
}


sub trackInfoMenu {
	my ( $client, $url, $track, $remoteMeta ) = @_;
	
	return unless $client && $url =~ /^spotify:/;
	
	my $uri = $url;
	$uri =~ s/\///g;

	# Hmm... can't do an async lookup, as trackInfoMenu is run synchronously
	my $track = Plugins::Spotty::Plugin->getAPIHandler($client)->trackCached(undef, $uri) || {};
	
	my $items = [];
	
	push @$items, {
		type => 'playlist',
		on_select => 'play',
		name => cstring($client, 'PLUGIN_SPOTTY_TITLE_RADIO'),
		url  => \&trackRadio,
		passthrough => [{ uri => $uri }],
	},{
		name => cstring($client, 'PLUGIN_SPOTTY_ADD_TRACK_TO_PLAYLIST'),
		type => 'link',
		url  => \&addTrackToPlaylist,
		passthrough => [{ uri => $uri }],
	};
	
	my $prefix = cstring($client, 'PLUGIN_SPOTTY_ON_SPOTIFY') . cstring($client, 'COLON') . ' ';

	for my $artist ( @{ $track->{artists} || [] } ) {
		push @$items, {
			name => $prefix . $artist->{name},
			type => $artist->{uri} ? 'link' : 'text',
			url  => \&artist,
			passthrough => [{
				uri => $artist->{uri},
			}]
		};
	}
	
	push @$items, {
		name => $prefix . $track->{album}->{name},
		type => 'link',
		url   => \&album,
		passthrough => [{
			uri => $track->{album}->{uri}
		}]
	} if $track->{album} && ref $track->{album} && $track->{album}->{uri};

	return $items;
}

sub addTrackToPlaylist {
	my ($client, $cb, $params, $args) = @_;
	
	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);
	my $username = $spotty->username;
	
	$spotty->playlists(sub {
		my ($playlists) = @_;
		
		my $items = [];

		for my $list ( @{$playlists} ) {
			my $creator = $list->{creator};
			$creator ||= $list->{owner}->{id} if $list->{owner};
			
			# ignore other user's playlists we're following
			if ( $creator && $creator ne $username ) {
				next;
			}

			push @{$items}, {
				name  => $list->{name} || $list->{title},
				type  => 'link',
				image => $list->{image} || ($list->{collaborative} ? IMG_COLLABORATIVE : IMG_PLAYLIST),
				url   => \&_addTrackToPlaylist,
				nextWindow => 'parent',
				passthrough => [{
					track => $params->{uri} || $args->{uri},
					playlist => $list->{uri}
				}]
			};
		}

		$cb->({ 
			items => $items,
			isContextMenu => 1,
		});
	},{
		user => $username
	});
}

sub _addTrackToPlaylist {
	my ($client, $cb, $params, $args) = @_;
	
	$args ||= {};
	$args->{track} ||= $params->{track};
	$args->{playlist} ||= $params->{playlist};
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->addTracksToPlaylist(sub {
		$cb->({ items => [{
			name => cstring($client, 'PLUGIN_SPOTTY_MUSIC_ADDED'),
			showBriefly => 1
		}] });
	}, $args->{playlist}, $args->{track});
}

sub trackRadio {
	my ($client, $cb, $params, $args) = @_;
	$args->{type} = 'seed_tracks';
	_radio($client, $cb, $params, $args);
}

sub artistRadio {
	my ($client, $cb, $params, $args) = @_;
	$args->{type} = 'seed_artists';
	_radio($client, $cb, $params, $args);
}

sub _radio {
	my ($client, $cb, $params, $args) = @_;
	
	my $type = delete $args->{type};
	
	my $id = $params->{uri} || $args->{uri};
	$id =~ s/.*://;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->recommendations(sub {
		$cb->({ items => trackList($client, shift) });
	},{
		$type => $id
	});
}

sub hasRecentSearches {
	return scalar @{ $prefs->get('spotify_recent_search') || [] };
}

sub addRecentSearch {
	my ( $search ) = @_;
	
	my $list = $prefs->get('spotify_recent_search') || [];
	
	# remove potential duplicates
	$list = [ grep { $_ ne $search } @$list ];
	
	push @$list, $search;
	
	# we only want MAX_RECENT items
	$list = [ @$list[(-1 * MAX_RECENT)..-1] ] if scalar @$list > MAX_RECENT;
	
	$prefs->set( 'spotify_recent_search', $list );
}

sub recentSearches {
	my ($client, $cb, $params) = @_;
	
	my $items = [];
	
	push @{$items}, {
		name  => cstring($client, 'PLUGIN_SPOTTY_NEW_SEARCH'),
		type  => 'search',
		url   => \&search,
	};
	
	for my $recent ( reverse @{ $prefs->get('spotify_recent_search') || [] } ) {
		push @{$items}, {
			name  => $recent,
			type  => 'link',
			url   => \&search,
			passthrough => [{ 
				query => $recent,
				recent => 1
			}],
		};
	}
	
	$cb->({ items => $items });
}

1;
package Plugins::Spotty::OPML;

use strict;

use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::API;

use Slim::Menu::GlobalSearch;
use Slim::Utils::Cache;
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
use constant IMG_TOPTRACKS => 'plugins/Spotty/html/images/toptracks.png';
use constant IMG_INBOX => 'plugins/Spotty/html/images/inbox.png';

use constant MAX_RECENT => 50;

my $prefs = preferences('plugin.spotty');
my $log = logger('network.asynchttp');
my $cache = Slim::Utils::Cache->new();

my %topuri = (
	AT => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbKNHh6NIXu36',
	AU => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbJPcfkRz0wJ0',
	BE => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbJNSeeHswcKB',
	CA => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbKj23U1GF4IR',
	CH => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbJiyhoAPEfMK',
	DE => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbJiZcmkrIHGU',
	DK => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbL3J0k32lWnN',
	ES => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbNFJfN1Vw8d9',
	FI => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbMxcczTSoGwZ',
	FR => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbIPWwFssbupI',
	GB => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbLnolsZ8PSNw',
	IT => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbIQnj7RRhdSX',
	NL => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbKCF6dqVpDkS',
	NO => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbJvfa0Yxg7E7',
	NZ => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbM8SIrkERIYl',
	SE => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbLoATJ81JYXz',
	US => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbLRQDuF5jeBp',
	
	XX => 'spotify:user:spotifycharts:playlist:37i9dQZEVXbMDoHDwVN2tF',	# fallback "Top 100 on Spotify"
);

my $nextNameCheck = 0;

sub init {
	Slim::Menu::TrackInfo->registerInfoProvider( spotty => (
		after => 'top',
		func  => \&trackInfoMenu,
	) );

	Slim::Menu::ArtistInfo->registerInfoProvider( spotty => (
		after => 'top',
		func  => \&artistInfoMenu,
	) );

	Slim::Menu::AlbumInfo->registerInfoProvider( spotty => (
		after => 'top',
		func  => \&albumInfoMenu,
	) );

	Slim::Menu::GlobalSearch->registerInfoProvider( spotty => (
		func => sub {
			my ( $client, $tags ) = @_;
			
			return {
				name  => cstring($client, Plugins::Spotty::Plugin::getDisplayName()),
				items => [ map { delete $_->{image}; $_ } @{_searchItems($client, $tags->{search})} ],
			};
		},
	) );
	
	# enforce initial refresh of users' display names
	$cache->remove('spotty_got_names');
}

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
	elsif (!Slim::Networking::Async::HTTP->hasSSL()) {
		$cb->({
			items => [{
				name => cstring($client, 'PLUGIN_SPOTTY_MISSING_SSL'),
				type => 'textarea'
			}]
		});
		
		return;
	}
	elsif ( !Plugins::Spotty::Plugin->hasCredentials() || !Plugins::Spotty::Plugin->getAccount($client) ) {
		$cb->({
			items => [{
				name => cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED') . "\n" . cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT'),
				type => 'textarea'
			}]
		});
		
		return;
	}
	# if there's no account assigned to the player, just pick one - we should never get here...
	elsif ( !Plugins::Spotty::Plugin->getCredentials($client) ) {
		selectAccount($client, $cb, $args);
		return;
	}

	# update users' display names every now and then
	if ( Plugins::Spotty::Plugin->hasMultipleAccounts() && $nextNameCheck < time ) {
		foreach ( @{ Plugins::Spotty::Plugin->getSortedCredentialTupels() } ) {
			my ($name, $id) = each %{$_};
			Plugins::Spotty::Plugin->getName($client, $name);
		}
		
		$nextNameCheck = time() + 3600;
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
			image => IMG_TOPTRACKS,
			url   => \&playlist,
			passthrough => [{
				uri => $topuri{$spotty->country()} || $topuri{XX}
			}]
		},
		{
			name  => cstring($client, 'PLUGIN_SPOTTY_GENRES_MOODS'),
			type  => 'link',
			image => IMG_INBOX,
			url   => \&categories
		};
		
		if ( $message && $lists && ref $lists && scalar @$lists ) {
			push @$items, {
				name  => $message,
				image => IMG_INBOX,
				items => playlistList($client, $lists)
			};
		}
		
		my $personalItems = [{
			name  => cstring($client, 'ALBUMS'),
			type  => 'link',
			image => IMG_ALBUM,
			url  => \&myAlbums,
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
		}];
		
		# only give access to the tracks list if the user is using his own client ID
		if ( _enableAdvancedFeatures() ) {
			unshift @$personalItems, {
				name  => cstring($client, 'PLUGIN_SPOTTY_SONGS_LIST'),
				type  => 'playlist',
				image => IMG_PLAYLIST,
				url  => \&mySongs,
			}
		}

		if ( !$prefs->get('accountSwitcherMenu') && Plugins::Spotty::Plugin->hasMultipleAccounts() ) {
			my $credentials = Plugins::Spotty::Plugin->getAllCredentials();
			
			foreach my $name ( sort {
				lc($a) cmp lc($b)
			} keys %$credentials ) {
				push @$items, {
					name => cstring($client, 'PLUGIN_USERS_LIBRARY', _getDisplayName($name)),
					items => [ map {{
						name => $_->{name},
						type => $_->{type},
						image => $_->{image},
						url => \&_withAccount,
						passthrough => [{ 
							name => $name,
							cb => $_->{url} 
						}]
					}} @$personalItems ],
					image => IMG_ACCOUNT,
				};
			}
		}
		else {
			push @$items, @$personalItems;
		}
		
		push @$items, {
			name  => cstring($client, 'PLUGIN_SPOTTY_TRANSFER'),
			type  => 'link',
			image => IMG_PLAYLIST,
			url   => \&transferPlaylist
		};
		
		if ( $prefs->get('accountSwitcherMenu') && Plugins::Spotty::Plugin->hasMultipleAccounts() ) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_SPOTTY_ACCOUNT'),
				items => [{
					name => _getDisplayName($spotty->username),
					type => 'text'
				},{
					name => cstring($client, 'PLUGIN_SPOTTY_SELECT_ACCOUNT'),
					url   => \&selectAccount,
				}],
				image => IMG_ACCOUNT,
			};
		}
		
		$cb->({
# XXX - how to refresh the title when the account has changed?
#			name  => cstring($client, 'PLUGIN_SPOTTY_NAME') . (Plugins::Spotty::Plugin->hasMultipleAccounts() ? sprintf(' (%s)', _getDisplayName($spotty->username)) : ''),
			items => $items,
		});
	} );
}

sub _getDisplayName {
	my ($userId) = @_;
	return $prefs->get('displayNames')->{$userId} || $userId;
}

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{query};
	$params->{type}   ||= $args->{type};

	my $type = $params->{type} || '';
	$type = '' if $type eq 'context';
	
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
			push @items, grep { 
				$_->{passthrough}->[0]->{type} ne 'track'
			} @{
				_searchItems($client, $params->{search})
			};
			
			push @items, @{trackList($client, $results)};
			
			addRecentSearch($params->{search}) unless $args->{recent} || $params->{type} eq 'context';

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
			$log->error("Unkonwn search type: ") . Data::Dump::dump($results);
		}

		$cb->({ items => \@items });
	}, {
		query => $params->{search},
		type  => $type || 'track',
		limit => 50,
	});
}

sub _searchItems {
	my ($client, $query) = @_;
	
	my @items = map {
		{
			name  => cstring($client, $_->[0]),
			image => $_->[2],
			url   => \&search,
			passthrough => [{
				query => $query,
				type  => $_->[1]
			}]
		}
	} (
		[ 'ARTISTS', 'artist', IMG_ACCOUNT ],
		[ 'ALBUMS', 'album', IMG_ALBUM ],
		[ 'PLAYLISTS', 'playlist', IMG_PLAYLIST ],
		[ 'SONGS', 'track', IMG_TRACK ],
		[ 'PLUGIN_SPOTTY_USERS', 'user', IMG_ACCOUNT ]
	);

	return \@items	
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

sub mySongs {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->mySongs(sub {
		my ($result) = @_;


		my ($items, $indexList) = trackList($client, $result);
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_SONGS'),
			type => 'text',
		} unless scalar @$items;
		
		$cb->({
			items => $items,
			indexList => $indexList
		});
	});
}

sub myAlbums {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->myAlbums(sub {
		my ($result) = @_;

		my ($items, $indexList) = albumList($client, $result);
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_STUFF'),
			type => 'text',
		} unless scalar @$items;
		
		$cb->({
			items => $items,
			indexList => $indexList
		});
	});
}

sub myArtists {
	my ($client, $cb, $params) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->myArtists(sub {
		my ($result) = @_;

		my ($items, $indexList) = artistList($client, $result, $prefs->get('myAlbumsOnly'));
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_STUFF'),
			type => 'text',
		} unless scalar @$items;
		
		$cb->({
			items => $items,
			indexList => $indexList
		});
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
		
		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_ALBUM_TO_LIBRARY'),
			url  => \&addAlbumToLibrary,
			passthrough => [{ id => $album->{id}, name => $album->{name} }],
			nextWindow => 'refresh'
		};
		
		my %artists;
		for my $track ( @{ $album->{tracks} } ) {
			for my $artist ( @{ $track->{artists} } ) {
				next unless $artist->{uri};
				$artists{ $artist->{name} } = $artist->{uri};
			}
		}
	
		my $prefix = cstring($client, 'ARTIST') . cstring($client, 'COLON') . ' ';
		for my $artist ( sort keys %artists ) {
			push @$items, {
				name  => $prefix . $artist,
				url   => \&artist,
				passthrough => [{ uri => $artists{$artist} }],
				image => IMG_ACCOUNT,
			};
		}
	
		if ( $album->{release_date} && $album->{release_date} =~ /\b(\d{4})\b/ ) {
			push @{$items}, {
				name  => cstring($client, 'YEAR') . cstring($client, 'COLON') . " $1",
				type  => 'text',
			};
		}
		
		$cb->({ items => $items });
	},{
		uri => $params->{uri} || $args->{uri}
	});
}

sub addAlbumToLibrary {
	my ($client, $cb, $params, $args) = @_;
	
	$args ||= {};

	Plugins::Spotty::Plugin->getAPIHandler($client)->addAlbumToLibrary(sub {
		$cb->({ items => [{
			name => cstring($client, 'PLUGIN_SPOTTY_MUSIC_ADDED'),
			showBriefly => 1
		}] });
	}, $params->{ids} || $args->{ids} || $params->{id} || $args->{id});
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
	
	# Split albums into compilations (albums with a different primary artist name), singles, and regular albums
	# XXX Need a better way to determine album type. Unfortunately album->{album_type} doesn't work
	my $albums = albumList($client, [ grep { $_->{album_type} ne 'single' && $_->{artist} eq $artist->{name} } @{ $artistInfo->{albums} } ]);
	my $singles = albumList($client, [ grep { $_->{album_type} eq 'single' } @{ $artistInfo->{albums} } ]);
	my $comps  = albumList($client, [ grep { $_->{album_type} ne 'single' && $_->{artist} ne $artist->{name} } @{ $artistInfo->{albums} } ]);
	
	if ( scalar @$albums ) {		
		push @$items, {
			name  => cstring($client, 'ALBUMS'),
			items => $albums,
		};
	}
	
	if ( scalar @$singles ) {		
		push @$items, {
			name  => cstring($client, 'PLUGIN_SPOTTY_SINGLES'),
			items => $singles,
		};
	}
	
	if ( scalar @$comps ) {		
		push @$items, {
			name  => cstring($client, 'PLUGIN_SPOTTY_COMPILATIONS'),
			items => $comps,
		};
	}
	
	push @$items, {
		type  => 'outline',
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
		my ($items, $indexList) = artistList($client, shift);
		
		$cb->({
			items => $items,
			indexList => $indexList
		});
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

sub transferPlaylist {
	my ($client, $cb) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->player(sub {
		my ($info) = @_;
		
		my $items = [];
		
		# if Connect is enabled for the target player, switch playback
		if ( $info && $info->{device} && Plugins::Spotty::Connect->canSpotifyConnect() && $prefs->client($client)->get('enableSpotifyConnect') ) {
			push @$items, {
				name => cstring($client, 'PLUGIN_SPOTTY_TRANSFER_CONNECT_DESC'),
				type => 'textarea'
			},{
				name => $info->{device}->{name},
				url  => sub {
					Plugins::Spotty::Plugin->getAPIHandler($client)->playerTransfer(sub {
						$cb->({
							nextWindow => 'nowPlaying'
						});
					}, $client->id);
				},
				nextWindow => 'nowPlaying',
			}
		}
		
		# otherwise just try to play 
		elsif ( $info && $info->{track} ) {
			push @$items, {
				name => cstring($client, 'PLUGIN_SPOTTY_TRANSFER_DESC'),
				type => 'textarea'
			},{
				name => $info->{device}->{name},
				url  => \&_doTransferPlaylist,
				passthrough => [$info],
				nextWindow => 'nowPlaying',
			}
		}
		else {
			push @$items, {
				name => cstring($client, 'PLUGIN_SPOTTY_NO_PLAYER_FOUND'),
				type => 'textarea'
			};
		}

		$cb->({ items => $items });
	});
}

sub _doTransferPlaylist {
	my ($client, $cb, $params, $args) = @_;
	
	# TODO - check with latest context changes
	if ($args && ref $args && $args->{track}) {
		Plugins::Spotty::Plugin->getAPIHandler($client)->trackURIsFromURI(sub {
			my $idx; 
			my $i = 0;
			
			my $tracks = [ map {
				$idx = $i if !defined $idx && $_ eq $args->{track}->{uri};
				$i++; 
				/(track:.*)/; 
				"spotify://$1";
			} @{shift || []} ];
			
			if ( @$tracks ) {
				$client->execute(['playlist', 'clear']);
				$client->execute(['playlist', 'play', $tracks]);
				$client->execute(['playlist', 'jump', $idx]) if $idx;
				$client->execute(['time', $args->{progress}]) if $args->{progress};
			}
				
			$cb->({
				nextWindow => 'nowPlaying'
			});
		}, $args->{context}->{uri});

		return;
	}
	
	$log->warn("Incomplete Spotify playback data received?\n" . (main::INFOLOG ? Data::Dump::dump($args) : ''));

	$cb->({
		name => cstring($client, 'PLUGIN_SPOTTY_NO_PLAYER_FOUND'),
	});
}

=pod
sub recentlyPlayed {
	my ($client, $cb, $params, $args) = @_;
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->recentlyPlayed(sub {
		my ($items) = @_;
		
		foreach ( @{ $items, [] }) {
			if ($_->{type} eq 'playlist') {
				$_ = playlistList($client, [$_])->[0];
			}
			elsif ($_->{type} eq 'track') {
				$_ = trackList($client, [$_])->[0];
			}
			elsif ($_->{type} eq 'album') {
				$_ = albumList($client, [$_])->[0];
				warn Data::Dump::dump($_);
			}
		}

		$cb->({ items => $items });
	});
}
=cut

sub trackList {
	my ( $client, $tracks, $args ) = @_;
	
	my $show_numbers = $args->{show_numbers} || 0;
	my $image        = $args->{image};
	
	my $items = [];
	
	
	my $count = 0;
	for my $track ( @{$tracks} ) {
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
				favorites_url => $track->{uri},
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
			$log->error("unsupported track data structure?\n" . Data::Dump::dump($track));
		}
	}
	
	return $items;
}

sub albumList {
	my ( $client, $albums ) = @_;
	
	my $items = [];

	my $indexList = [];
	my $indexLetter;
	my $count = 0;
	
	for my $album ( @{$albums} ) {		
		my $artists = join( ', ', map { $_->{name} } @{ $album->{artists} } );

		my $textkey = uc(substr($album->{name} || '', 0, 1));

		if ( defined $indexLetter && $indexLetter ne ($textkey || '') ) {
			push @$indexList, [$indexLetter, $count];
			$count = 0;
		}

		$count++;
		$indexLetter = $textkey;
					
		push @{$items}, {
			type  => 'playlist',
			name  => $album->{name} . ($artists ? (' ' . cstring($client, 'BY') . ' ' . $artists) : ''),
			line1 => $album->{name},
			line2 => $artists,
			textkey => $textkey,
			url   => \&album,
			favorites_url => $album->{uri},
			image => $album->{image} || IMG_ALBUM,
			passthrough => [{
				uri => $album->{uri}
			}]
		};
	}

	push @$indexList, [$indexLetter, $count];
	
	return wantarray ? ($items, $indexList) : $items;
}

sub artistList {
	my ( $client, $artists, $myAlbumsOnly ) = @_;
	
	my $items = [];

	my $indexList = [];
	my $indexLetter;
	my $count = 0;

	for my $artist ( @{$artists} ) {
		my $textkey = substr($artist->{sortname} || '', 0, 1);
		
		if ( defined $indexLetter && $indexLetter ne ($textkey || '') ) {
			push @$indexList, [$indexLetter, $count];
			$count = 0;
		}
		
		$count++;
		$indexLetter = $textkey;
		
		push @{$items}, {
			name => $artist->{name},
			textkey => $textkey,
			image => $artist->{image} || IMG_ACCOUNT,
			url  => \&artist,
			playlist => $artist->{uri},
			favorites_url => $artist->{uri},
			passthrough => [{
				uri => $artist->{uri},
				myAlbumsOnly => $myAlbumsOnly ? 1 : 0,
			}]
		};
	}

	push @$indexList, [$indexLetter, $count];
	
	return wantarray ? ($items, $indexList) : $items;
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
			favorites_url => $list->{uri},
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
	
	my $args;

	# if we're dealing with a Spotify track we can use the URI to get more direct results
	if ( $url =~ /^spotify:/ ) {
		my $uri = $url;
		$uri =~ s/\///g;

		# Hmm... can't do an async lookup, as trackInfoMenu is run synchronously
		my $track = Plugins::Spotty::Plugin->getAPIHandler($client)->trackCached(undef, $uri) || {};
		
		$args = {
			artists => $track->{artists},
			album   => $track->{album},
			uri     => $uri,
		};
	}
	else {
		$args = {
			artist => $track->remote ? $remoteMeta->{artist} : $track->artistName,
			album  => $track->remote ? $remoteMeta->{album}  : ( $track->album ? $track->album->name : undef ),
			title  => $track->remote ? $remoteMeta->{title}  : $track->title,
		};
	}

	return _objInfoMenu($client, $args);
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta) = @_;
	
	$remoteMeta ||= {};
	
	return _objInfoMenu($client, {
		artist => $artist->name || $remoteMeta->{artist},
	});
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;

	$remoteMeta ||= {};
	
	return _objInfoMenu($client, {
		album => $album->title || $remoteMeta->{album},
		artists => [ map { $_->name } $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST') ],
	});
}

sub _objInfoMenu {
	my ( $client, $args ) = @_;

	return unless $client && ref $args;
	
	my $items = [];
	my $prefix = cstring($client, 'PLUGIN_SPOTTY_ON_SPOTIFY') . cstring($client, 'COLON') . ' ';

	# if we're dealing with a Spotify item we can use the URI to get more direct results
	if ( my $uri = $args->{uri} ) {
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
		} if $uri =~ /spotify:track/;
	
		for my $artist ( @{ $args->{artists} || [] } ) {
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
			name => $prefix . $args->{album}->{name},
			type => 'link',
			url   => \&album,
			passthrough => [{
				uri => $args->{album}->{uri}
			}]
		} if $args->{album} && ref $args->{album} && $args->{album}->{uri};
	}
	# if we're playing content from other than Spotify, provide a search
	else {
		my $artist = $args->{artist};
		my $artists = $args->{artists} || [];
		my $album  = $args->{album};
		my $title  = $args->{title};
		
		push @$artists, $artist if defined $artist && !grep $artist, @$artists;

		foreach my $artist (@$artists) {
			push @$items, {
				name  => $prefix . $artist,
				url   => \&search,
				passthrough => [{
					query => 'artist:"' . $artist . '"',
					type  => 'context',
				}]
			};
		}

		push @$items, {
			name  => $prefix . $album,
			url   => \&search,
			passthrough => [{
				query => 'album:"' . $album . '"',
				type  => 'context',
			}]
		} if $album;

		push @$items, {
			name  => $prefix . $title,
			url   => \&search,
			passthrough => [{
				query => 'track:"' . $title . '"',
				type  => 'context',
			}]
		} if $title;
	}

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

sub selectAccount {
	my ($client, $cb, $params) = @_;

	my $items = [];
	my $username = Plugins::Spotty::Plugin->getAPIHandler($client)->username;
	
	foreach ( @{ Plugins::Spotty::Plugin->getSortedCredentialTupels() } ) {
		my ($name, $id) = each %{$_};
		
		next if $name eq $username;
		
		push @$items, {
			name => $name,
			url  => \&_selectAccount,
			passthrough => [{
				id => $id
			}],
			nextWindow => 'parent'
		}
	}
	
	$cb->({ items => $items });
}

sub _selectAccount {
	my ($client, $cb, $params, $args) = @_;
	
	return unless $client;

	Plugins::Spotty::Plugin->setAccount($client, $args->{id});
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->me(sub {
		$cb->({ items => [{
			nextWindow => 'grandparent',
		}] });
	});
}

sub _withAccount {
	my ($client, $cb, $params, $args) = @_;

	my $credentials = Plugins::Spotty::Plugin->getAllCredentials();
	my $id = lc($credentials->{$args->{name}});

	main::INFOLOG && $log->is_info && $log->info(sprintf('Running query for %s (%s)', $args->{name}, $id));

	Plugins::Spotty::Plugin->setAccount($client, $id);
	
	Plugins::Spotty::Plugin->getAPIHandler($client)->me(sub {
		$args->{cb}->($client, $cb, $params);
	});
}

sub _enableAdvancedFeatures {
	Plugins::Spotty::Plugin->hasDefaultIcon() ? 0 : 1;
}

1;

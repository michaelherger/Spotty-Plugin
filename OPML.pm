package Plugins::Spotty::OPML;

use strict;

use URI::Escape qw(uri_escape_utf8);

use Plugins::Spotty::AccountHelper;
use Plugins::Spotty::API;
use Plugins::Spotty::PlaylistFolders;

use Slim::Menu::BrowseLibrary;
use Slim::Menu::GlobalSearch;
use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string cstring);

use constant IMG_TRACK => '/html/images/cover.png';
use constant IMG_ALBUM => 'plugins/Spotty/html/images/album.png';
use constant IMG_PODCAST => 'plugins/Spotty/html/images/podcasts.png';
use constant IMG_PLAYLIST => 'plugins/Spotty/html/images/playlist.png';
use constant IMG_COLLABORATIVE => 'plugins/Spotty/html/images/playlist-collab.png';
use constant IMG_SEARCH => 'plugins/Spotty/html/images/search.png';
use constant IMG_WHATSNEW => 'plugins/Spotty/html/images/whatsnew.png';
use constant IMG_ACCOUNT => 'plugins/Spotty/html/images/account.png';
use constant IMG_TOPTRACKS => 'plugins/Spotty/html/images/toptracks.png';
use constant IMG_INBOX => 'plugins/Spotty/html/images/inbox.png';

use constant MAX_RECENT => 50;

my $prefs = preferences('plugin.spotty');
my $serverPrefs = preferences('server');
my $log = logger('plugin.spotty');
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

	if ( Slim::Utils::PluginManager->isEnabled('Slim::Plugin::OnlineLibrary::Plugin') ) {
		require Slim::Plugin::OnlineLibrary::BrowseArtist;
		Slim::Plugin::OnlineLibrary::BrowseArtist->registerBrowseArtistItem( spotify => sub {
			my ( $client ) = @_;

			return {
				name => cstring($client, 'BROWSE_ON_SERVICE', 'Spotify'),
				type => 'link',
				icon => Plugins::Spotty::Plugin->_pluginDataFor('icon'),
				url  => \&browseArtistMenu,
			};
		} );

		main::INFOLOG && $log->is_info && $log->info("Successfully registered BrowseArtist handler for Spotify");
	}

#                                                               |requires Client
#                                                               |  |is a Query
#                                                               |  |  |has Tags
#                                                               |  |  |  |Function to call
#                                                               C  Q  T  F
	Slim::Control::Request::addDispatch(['spotty','recentsearches'],
	                                                            [0, 0, 1, \&_recentSearchesCLI]
	);

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
	elsif ( !Plugins::Spotty::AccountHelper->hasCredentials() || !Plugins::Spotty::AccountHelper->getAccount($client) ) {
		$cb->({
			items => [{
				name => cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED') . "\n" . cstring($client, 'PLUGIN_SPOTTY_NOT_AUTHORIZED_HINT'),
				type => 'textarea'
			}]
		});

		return;
	}
	# if there's no account assigned to the player, just pick one - we should never get here...
	elsif ( !Plugins::Spotty::AccountHelper->getCredentials($client) ) {
		selectAccount($client, $cb, $args);
		return;
	}

	# update users' display names every now and then
	if ( Plugins::Spotty::AccountHelper->hasMultipleAccounts() && $nextNameCheck < time ) {
		foreach ( @{ Plugins::Spotty::AccountHelper->getSortedCredentialTupels() } ) {
			my ($name, $id) = each %{$_};
			Plugins::Spotty::AccountHelper->getName($client, $name);
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

		if ( Plugins::Spotty::Helper->getCapability('podcasts') ) {
			push @$personalItems, {
				name  => cstring($client, 'PLUGIN_SPOTTY_SHOWS'),
				type  => 'link',
				image => IMG_PODCAST,
				url   => \&shows
			};
		}

		# only give access to the tracks list if the user is using his own client ID
		if ( _enableAdvancedFeatures() ) {
			unshift @$personalItems, {
				name  => cstring($client, 'PLUGIN_SPOTTY_SONGS_LIST'),
				type  => 'playlist',
				image => IMG_PLAYLIST,
				url  => \&mySongs,
			}
		}

		if ( !$prefs->get('accountSwitcherMenu') && Plugins::Spotty::AccountHelper->hasMultipleAccounts() ) {
			my $credentials = Plugins::Spotty::AccountHelper->getAllCredentials();

			foreach my $name ( sort {
				lc($a) cmp lc($b)
			} keys %$credentials ) {
				push @$items, {
					name => cstring($client, 'PLUGIN_SPOTTY_USERS_LIBRARY', Plugins::Spotty::AccountHelper->getDisplayName($name)),
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

		if ( $prefs->get('accountSwitcherMenu') && Plugins::Spotty::AccountHelper->hasMultipleAccounts() ) {
			push @$items, {
				name  => cstring($client, 'PLUGIN_SPOTTY_ACCOUNT'),
				items => [{
					name => Plugins::Spotty::AccountHelper->getDisplayName($spotty->username),
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
#			name  => cstring($client, 'PLUGIN_SPOTTY_NAME') . (Plugins::Spotty::AccountHelper->hasMultipleAccounts() ? sprintf(' (%s)', Plugins::Spotty::AccountHelper->getDisplayName($spotty->username)) : ''),
			items => $items,
		});
	} );
}

sub search {
	my ($client, $cb, $params, $args) = @_;

	$params->{search} ||= $args->{query};
	$params->{type}   ||= $args->{type};

	my $type = $params->{type} || '';
	$type = '' if $type eq 'context';

	if (my $uriInfo = parseUri($params->{search})) {
		$args->{uri} = $uriInfo->{uri};
		if ($uriInfo->{type} eq 'playlist') {
			return playlist($client, $cb, $params, $args);
		}
		elsif ($uriInfo->{type} eq 'album') {
			return album($client, $cb, $params, $args);
		}
		elsif ($uriInfo->{type} eq 'artist') {
			return artist($client, $cb, $params, $args);
		}
		elsif ($uriInfo->{type} eq 'show') {
			return show($client, $cb, $params, $args);
		}
	}

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
		elsif ($type eq 'show_audio') {
			push @items, @{podcastList($client, $results)};
		}
		elsif ($type eq 'episode_audio') {
			push @items, @{episodesList($client, $results)};
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

sub parseUri {
	my ($uri) = @_;
	my ($type, $id);

	# https://open.spotify.com/playlist/3i6JdDL2IaDoIdrZCVngUv
	if ($uri =~ m|open.spotify.com/(.+)/([a-z0-9]+)|i) {
		$type = $1;
		$id   = $2;
		$uri  = "spotify:$type:$id";
	}
	elsif ($uri =~ /^spotify:(.+?):([a-z0-9]+)$/i) {
		$type = $1;
		$id   = $2;
	}

	main::INFOLOG && $log->is_info && $log->info("URI info: " . Data::Dump::dump({
		type => $type,
		id   => $id,
		uri  => $uri
	}));

	return $type && $id && {
		type => $type,
		id   => $id,
		uri  => $uri
	};
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
	} grep {
		Plugins::Spotty::Helper->getCapability('podcasts') || $_->[1] !~ /^(?:show|episode)_/;
	} (
		[ 'ARTISTS', 'artist', IMG_ACCOUNT ],
		[ 'ALBUMS', 'album', IMG_ALBUM ],
		[ 'PLAYLISTS', 'playlist', IMG_PLAYLIST ],
		[ 'SONGS', 'track', IMG_TRACK ],
		# https://github.com/spotify/web-api/issues/551#issuecomment-486898766
		[ 'PLUGIN_SPOTTY_SHOWS', 'show_audio', IMG_PODCAST ],
		[ 'PLUGIN_SPOTTY_EPISODES', 'episode_audio', IMG_PODCAST ],
		[ 'PLUGIN_SPOTTY_USERS', 'user', IMG_ACCOUNT ]
	);

	return \@items
}

sub whatsNew {
	my ($client, $cb, $params) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->newReleases(sub {
		my ($albums) = @_;

		my $items = albumList($client, $albums, 1);

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

sub shows {
	my ($client, $cb, $params) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->myShows(sub {
		my ($result) = @_;

		my ($items, $indexList) = podcastList($client, $result);

		$cb->({
			items => $items,
			indexList => $indexList
		});
	});
}

sub show {
	my ($client, $cb, $params, $args) = @_;

	Plugins::Spotty::Plugin->getAPIHandler($client)->show(sub {
		my ($show) = @_;

		if ($prefs->client($client)->get('reversePodcastOrder')) {
			$show->{episodes} = [ reverse @{$show->{episodes}}];
		}

		my $items = episodesList($client, $show->{episodes});

		push @$items, {
			name => cstring($client, 'PLUGIN_SPOTTY_ADD_SHOW_TO_LIBRARY'),
			url  => \&addShowToLibrary,
			passthrough => [{ id => $show->{id}, name => $show->{name} }],
			nextWindow => 'parent'
		};

		if ($show->{description}) {
			push @$items, {
				name => cstring($client, 'DESCRIPTION'),
				items => [{
					name => $show->{description},
					type => 'textarea'
				}]
			};
		}

		if ($show->{languages}) {
			my $lang = ref $show->{languages} ? join(', ', map { uc } @{$show->{languages}}) : uc($show->{languages});
			push @$items, {
				name => cstring($client, 'LANGUAGE') . cstring($client, 'COLON') . " $lang",
				type => 'text'
			} if $lang;
		}

		$cb->({ items => $items });
	}, {
		uri => $params->{uri} || $args->{uri}
	});
}

sub addShowToLibrary {
	my ($client, $cb, $params, $args) = @_;

	$args ||= {};

	Plugins::Spotty::Plugin->getAPIHandler($client)->addShowToLibrary(sub {
		$cb->({ items => [{
			name => cstring($client, 'PLUGIN_SPOTTY_MUSIC_ADDED'),
			showBriefly => 1
		}] });
	}, $params->{ids} || $args->{ids} || $params->{id} || $args->{id});
}

sub playlists {
	my ($client, $cb, $params, $args) = @_;

	my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);

	$spotty->playlists(sub {
		my ($result) = @_;

		my $items;

		my $hierarchy = Plugins::Spotty::PlaylistFolders->getTree([ map {
			$_->{uri};
		} @$result ]);

		if ($hierarchy) {
			main::INFOLOG && $log->is_info && $log->info("Found playlist folder hierarchy! Let's use it: " . Data::Dump::dump($hierarchy));

			my %tree;
			foreach my $playlist (@$result) {
				my $parent = '/';
				my $node = $hierarchy->{$playlist->{uri}};
				if ($node && ref $node) {
					$parent = $node->{parent} || '/';
				}

				$tree{$parent} ||= [];
				push @{$tree{$parent}}, @{playlistList($client, [$playlist])};
			}

			foreach my $data (map {
				$hierarchy->{$_}->{id} = $_;
				$hierarchy->{$_};
			} sort {
				$hierarchy->{$a}->{order} <=> $hierarchy->{$b}->{order}
			} grep {
				ref $hierarchy->{$_} && $hierarchy->{$_}->{isFolder} && $tree{$_}
			} keys %$hierarchy) {
				if (my $parent = $data->{parent}) {
					$tree{$parent} ||= [];
					push @{$tree{$parent}}, {
						type  => 'outline',
						name  => $data->{name},
						image => IMG_PLAYLIST,
						id    => $data->{id}
					};
				}
			}

			# now let's try to bring the order back in...
			foreach my $parent (keys %tree) {
				main::INFOLOG && $log->is_info && $log->info("Sort items in $parent");
				$tree{$parent} = [ sort {
					my $aId = $a->{favorites_url} || $a->{id};
					my $bId = $b->{favorites_url} || $b->{id};

					my $aOrder = eval { $hierarchy->{$aId}->{order} } || 0;
					my $bOrder = eval { $hierarchy->{$bId}->{order} } || 0;

					$aOrder <=> $bOrder;
				} @{$tree{$parent}} ];
			}

			# now add ordered sub trees
			foreach my $parent (keys %tree) {
				main::INFOLOG && $log->is_info && $log->info("Add items to $parent");
				foreach my $item (@{$tree{$parent}}) {
					$item->{items} = $tree{$item->{id}} if $item->{id};
				}
			}

			main::DEBUGLOG && $log->is_debug && $log->debug("Final playlist folder order " . Data::Dump::dump($tree{'/'}));
			$items = $tree{'/'};
		}
		else {
			$items = playlistList($client, $result);

			push @$items, {
				name => cstring($client, 'PLUGIN_SPOTTY_ADD_STUFF'),
				type => 'text',
			} unless scalar @$items;
		}

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
			nextWindow => 'parent'
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
		uri => $params->{uri} || $args->{uri} || $params->{extid} || $args->{extid}
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
		nextWindow => 'parent'
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
		elsif ( $info && $info->{context} ) {
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

	if ($args && ref $args && $args->{context}) {
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
	my $filterExplicitContent = $prefs->client($client->master)->get('filterExplicitContent') || 0;

	for my $track ( @{$tracks} ) {
		if ( $track->{explicit} && $filterExplicitContent == 1) {
			main::INFOLOG && $log->is_info && $log->info('skip track, it has explicit content: ' . $track->{name});
		}
		elsif ( $track->{uri} ) {
			my $title  = $show_numbers ? $track->{track_number} . '. ' . $track->{name} : $track->{name};
			my $artist = join( ', ', map { $_->{name} } @{ $track->{artists} } );
			my $album  = $track->{album}->{name};

			my ($track_uri) = $track->{uri} =~ /^spotify:(track:.+)/;

			if ( my $i = $track->{album}->{image} ) {
				$image = $i;
			}

			# my $trackinfo = [];
			# push @$trackinfo, {
			# 	name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . sprintf('%s:%02s', int($track->{duration_ms} / 60_000), $track->{duration_ms} % 60_000),
			# 	type => 'text',
			# } if $track->{duration_ms};

			my $item = {
				name      => sprintf('%s %s %s %s %s', $title, cstring($client, 'BY'), $artist, cstring($client, 'FROM'), $album),
				line1     => $title,
				line2     => "${artist} \x{2022} ${album}",
				image     => $image || IMG_TRACK,
			};

			if ($track->{explicit} && $filterExplicitContent) {
				$item->{type} = 'text';
				$item->{name} = '* ' . $item->{name};
				$item->{line1} = '* ' . $item->{line1};
			}
			else {
				$item->{play} = 'spotify://' . $track_uri;
				$item->{favorites_url} = $track->{uri};
				$item->{on_select} = 'play';
				$item->{duration} = $track->{duration_ms} / 1000;
				$item->{playall} = 1;
				$item->{passthrough} = [{
					uri => $track->{uri}
				}];
			}

			push @{$items}, $item;
		}
		else {
			$log->error("unsupported track data structure?\n" . Data::Dump::dump($track));
		}
	}

	return $items;
}

sub albumList {
	my ( $client, $albums, $noIndexList ) = @_;

	my $items = [];

	my $indexList = [];
	my $indexLetter;
	my $count = 0;

	for my $album ( @{$albums} ) {
		my $artists = join( ', ', map { $_->{name} } @{ $album->{artists} } );

		my $textkey = $noIndexList ? '' : uc(substr($album->{name} || '', 0, 1));

		if ( defined $indexLetter && $indexLetter ne ($textkey || '') ) {
			push @$indexList, [$indexLetter, $count];
			$count = 0;
		}

		$count++;
		$indexLetter = $textkey;

		my $year = $serverPrefs->get('showYear') && $album->{release_date};
		if ($year) {
			$year =~ s/.*(\d{4}).*/$1/;
			$year = " ($year)"
		}

		push @{$items}, {
			type  => 'playlist',
			name  => $album->{name} . ($year || '') . ($artists ? (' ' . cstring($client, 'BY') . ' ' . $artists) : ''),
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

		my $item = {
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

		if ($artist->{followers} && $artist->{followers}->{total}) {
			$item->{line2} = cstring($client, 'PLUGIN_SPOTTY_FOLLOWERS') . ' ' . $artist->{followers}->{total};
		}

		push @{$items}, $item;
	}

	push @$indexList, [$indexLetter, $count];

	return wantarray ? ($items, $indexList) : $items;
}

sub podcastList {
	my ( $client, $shows, $noIndexList ) = @_;

	my $items = [];

	my $indexList = [];
	my $indexLetter;
	my $count = 0;

	for my $show ( @{$shows} ) {
		if ( $show->{is_externally_hosted} || ($show->{media_type} || 'audio') ne 'audio' ) {
			main::INFOLOG && $log->warn("This show needs inspection: " . Data::Dump::dump($show));
			# main::INFOLOG && $log->is_info && $log->info('skip show, it is not of audio content: ' . $show->{uri});
		}

		my $textkey = $noIndexList ? '' : uc(substr($show->{name} || '', 0, 1));

		if ( defined $indexLetter && $indexLetter ne ($textkey || '') ) {
			push @$indexList, [$indexLetter, $count];
			$count = 0;
		}

		$count++;
		$indexLetter = $textkey;

		push @{$items}, {
			type  => 'playlist',
			name  => $show->{name},
			line1 => $show->{name},
			line2 => $show->{description},
			textkey => $textkey,
			url   => \&show,
			favorites_url => $show->{uri},
			image => $show->{image} || IMG_PODCAST,
			passthrough => [{
				uri => $show->{uri}
			}]
		};
	}

	push @$indexList, [$indexLetter, $count];

	return wantarray ? ($items, $indexList) : $items;
}

sub episodesList {
	my ( $client, $episodes, $args ) = @_;

# TODO - what should this be?
	my $image = $args->{image};

	my $items = [];
	my $filterExplicitContent = $prefs->client($client->master)->get('filterExplicitContent') || 0;

	for my $episode ( @{$episodes} ) {
		if ( $episode->{is_externally_hosted} ) {
			main::INFOLOG && $log->warn("This episode might need inspection: " . Data::Dump::dump($episode));
		}

		if ( $episode->{media_type} && $episode->{media_type} ne 'audio' ) {
			main::INFOLOG && $log->warn("This episode needs inspection: " . Data::Dump::dump($episode));
			main::INFOLOG && $log->is_info && $log->info('skip episode, it is not of audio content: ' . $episode->{uri});
		}
		elsif ( $episode->{explicit} && $filterExplicitContent == 1) {
			main::INFOLOG && $log->is_info && $log->info('skip episode, it has explicit content: ' . $episode->{name});
		}
		elsif ( $episode->{uri} ) {
			my $title  = $episode->{name};
			my $show  = $episode->{show}->{name} || $episode->{album}->{name};

			my ($episode_uri) = $episode->{uri} =~ /^spotify:(episode:.+)/;

			if ( my $i = ($episode->{image} || $episode->{show}->{image} || $episode->{album}->{image}) ) {
				$image = $i;
			}

			# my $episodeinfo = [];
			# push @$episodeinfo, {
			# 	name => cstring($client, 'LENGTH') . cstring($client, 'COLON') . ' ' . sprintf('%s:%02s', int($episode->{duration_ms} / 60_000), $episode->{duration_ms} % 60_000),
			# 	type => 'text',
			# } if $episode->{duration_ms};

			my $item = {
				name  => join(' - ', $episode->{release_date}, $title),
				line1 => join(' - ', $episode->{release_date}, $title),
				line2 => substr($episode->{description}, 0, 512),		# longer descriptions would wrap, rendering the screen unreadable
				image => $image || IMG_TRACK,
			};

			if ($episode->{explicit} && $filterExplicitContent) {
				$item->{type} = 'text';
				$item->{name} = '* ' . $item->{name};
				$item->{line1} = '* ' . $item->{line1};
			}
			else {
				$item->{play} = 'spotify://' . $episode_uri;
				$item->{favorites_url} = $episode->{uri};
				$item->{on_select} = 'play';
				$item->{duration} = $episode->{duration_ms} / 1000;
				# $item->{playall} = 1;
				$item->{passthrough} = [{
					uri => $episode->{uri}
				}];
			}

			push @{$items}, $item;
		}
		else {
			$log->error("unsupported episode data structure?\n" . Data::Dump::dump($episode));
		}
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
			artist => {
				name => $track->remote ? $remoteMeta->{artist} : $track->artistName
			},
			album  => {
				name => $track->remote ? $remoteMeta->{album} : ( $track->album ? $track->album->name : undef )
			},
			title  => $track->remote ? $remoteMeta->{title} : $track->title,
			uri    => $track->extid,
		};
	}

	return _objInfoMenu($client, $args);
}

sub artistInfoMenu {
	my ($client, $url, $artist, $remoteMeta) = @_;

	$remoteMeta ||= {};

	return _objInfoMenu($client, {
		artist => {
			name => $artist->name || $remoteMeta->{artist},
			uri  => $artist->extid
		},
		uri => $artist->extid,
	});
}

sub browseArtistMenu {
	my ($client, $cb, $params, $args) = @_;

	my $artistId = $params->{artist_id} || $args->{artist_id};

	if ( defined($artistId) && $artistId =~ /^\d+$/ && (my $artistObj = Slim::Schema->resultset("Contributor")->find($artistId))) {
		if (my ($extId) = grep /spotify:artist:/, @{$artistObj->extIds}) {
			$params->{uri} = $extId;
			return artist($client, $cb, $params, $args);
		}
		else {
			$args->{query} = 'artist:"' . $artistObj->name . '"';
			$args->{type} = 'artist';
			return search($client, sub {
				my $items = shift || { items => [] };

				my $uri;
				if (scalar @{$items->{items}} == 1) {
					$uri = $items->{items}->[0]->{playlist};
				}
				else {
					my @uris = map {
						$_->{playlist}
					} grep {
						Slim::Utils::Text::ignoreCase($_->{name} ) eq $artistObj->namesearch
					} @{$items->{items}};

					if (scalar @uris == 1) {
						$uri = shift @uris;
					}
					else {
						$items->{items} = [ grep {
							Slim::Utils::Text::ignoreCase($_->{name} ) eq $artistObj->namesearch
						} @{$items->{items}} ];
					}
				}

				if ($uri) {
					$params->{uri} = $uri;
					return artist($client, $cb, $params, $args);
				}

				$cb->($items);
			}, $params, $args);
		}
	}

	$cb->([{
		type  => 'text',
		title => cstring($client, 'EMPTY'),
	}]);
}

sub albumInfoMenu {
	my ($client, $url, $album, $remoteMeta) = @_;

	$remoteMeta ||= {};

	my $albumInfo = {
		name => $album->title || $remoteMeta->{album}
	};

	if ($album->extid && $album->extid =~ /^spotify:/) {
		$albumInfo->{uri} = $album->extid;
	}

	my $artistsInfo = [ map {
		my $artist = {
			name => $_->name
		};

		if ($_->extid =~ /(spotify:artist:[0-9a-z]+)/i) {
			$artist->{uri} = $1;
		}

		$artist;
	} $album->artistsForRoles('ARTIST'), $album->artistsForRoles('ALBUMARTIST') ];

	my $objInfoMenu = _objInfoMenu($client, {
		album   => $albumInfo,
		artists => $artistsInfo,
		uri     => $album->extid
	});

	push @$objInfoMenu, {
		type => 'text',
		name => cstring($client, 'SOURCE') . cstring($client, 'COLON') . ' Spotify',
	} if $album->extid && $album->extid =~ /^spotify:album:/;

	return $objInfoMenu;
}

sub _objInfoMenu {
	my ( $client, $args ) = @_;

	return unless $client && ref $args;

	my $items = [];
	my $prefix = cstring($client, 'PLUGIN_SPOTTY_ON_SPOTIFY') . cstring($client, 'COLON') . ' ';

	my $uri = $args->{uri};

	# if we're dealing with a Spotify item we can use the URI to get more direct results
	if ($uri && $uri =~ /^spotify:/) {
		if ($args->{artist} && !$args->{artists}) {
			$args->{artists} = [ $args->{artist} ];
		}

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
			} if $artist->{uri};
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
				name  => $prefix . $artist->{name},
				url   => \&search,
				passthrough => [{
					query => 'artist:"' . $artist->{name} . '"',
					type  => 'context',
				}]
			};
		}

		push @$items, {
			name  => $prefix . $album->{name},
			url   => \&search,
			passthrough => [{
				query => 'album:"' . $album->{name} . '"',
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

sub _recentSearchesCLI {
	my $request = shift;
	my $client = $request->client;

	# check this is the correct command.
	if ($request->isNotCommand([['spotty'], ['recentsearches']])) {
		$request->setStatusBadDispatch();
		return;
	}

	my $list = $prefs->get('spotify_recent_search') || [];
	my $del = $request->getParam('deleteMenu') || $request->getParam('delete') || 0;

	if (!scalar @$list || $del >= scalar @$list) {
		$log->error('Search item to delete is outside the history list!');
		$request->setStatusBadParams();
		return;
	}

	my $items = [];

	if (defined $request->getParam('deleteMenu')) {
		push @$items, {
			text => cstring($client, 'DELETE') . cstring($client, 'COLON') . ' "' . ($list->[$del] || '') . '"',
			actions => {
				go => {
					player => 0,
					cmd    => ['spotty', 'recentsearches' ],
					params => {
						delete => $del
					},
				},
			},
			nextWindow => 'parent',
		},{
			text => cstring($client, 'PLUGIN_SPOTTY_CLEAR_SEARCH_HISTORY'),
			actions => {
				go => {
					player => 0,
					cmd    => ['spotty', 'recentsearches' ],
					params => {
						deleteAll => 1
					},
				}
			},
			nextWindow => 'grandParent',
		};

		$request->addResult('offset', 0);
		$request->addResult('count', scalar @$items);
		$request->addResult('item_loop', $items);
	}
	elsif ($request->getParam('deleteAll')) {
		$prefs->set( 'spotify_recent_search', [] );
	}
	elsif (defined $request->getParam('delete')) {
		splice(@$list, $del, 1);
		$prefs->set( 'spotify_recent_search', $list );
	}

	$request->setStatusDone;
}

sub recentSearches {
	my ($client, $cb, $params) = @_;

	my $items = [];

	my $i = 0;
	for my $recent ( @{ $prefs->get('spotify_recent_search') || [] } ) {
		unshift @$items, {
			name  => $recent,
			type  => 'link',
			url   => \&search,
			itemActions => {
				info => {
					command     => ['spotty', 'recentsearches'],
					fixedParams => { deleteMenu => $i++ },
				},
			},
			passthrough => [{
				query => $recent,
				recent => 1
			}],
		};
	}

	unshift @$items, {
		name  => cstring($client, 'PLUGIN_SPOTTY_NEW_SEARCH'),
		type  => 'search',
		url   => \&search,
	};

	$cb->({ items => $items });
}

sub selectAccount {
	my ($client, $cb, $params) = @_;

	my $items = [];
	my $username = Plugins::Spotty::Plugin->getAPIHandler($client)->username;

	foreach ( @{ Plugins::Spotty::AccountHelper->getSortedCredentialTupels() } ) {
		my ($name, $id) = each %{$_};

		next if $name eq $username;

		push @$items, {
			name => Plugins::Spotty::AccountHelper->getDisplayName($name),
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

	Plugins::Spotty::AccountHelper->setAccount($client, $args->{id});

	Plugins::Spotty::Plugin->getAPIHandler($client)->me(sub {
		$cb->({ items => [{
			nextWindow => 'grandparent',
		}] });
	});
}

sub _withAccount {
	my ($client, $cb, $params, $args) = @_;

	my $credentials = Plugins::Spotty::AccountHelper->getAllCredentials();
	my $id = lc($credentials->{$args->{name}});

	main::INFOLOG && $log->is_info && $log->info(sprintf('Running query for %s (%s)', $args->{name}, $id));

	Plugins::Spotty::AccountHelper->setAccount($client, $id);

	Plugins::Spotty::Plugin->getAPIHandler($client)->me(sub {
		$args->{cb}->($client, $cb, $params);
	});
}

sub _enableAdvancedFeatures {
	Plugins::Spotty::Plugin->hasDefaultIcon() ? 0 : 1;
}

1;

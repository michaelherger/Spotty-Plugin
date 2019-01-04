package Plugins::Spotty::PlaylistFolders;

# This playlist hierarchy parser is based on https://github.com/mikez/spotify-folders

use strict;

use Digest::MD5 qw(md5_hex);
use File::Next;
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use Tie::Cache::LRU::Expires;
use URI::Escape qw(uri_unescape);

use Slim::Utils::Cache;
use Slim::Utils::Log;

use constant MAX_FILE_TO_PARSE => 512 * 1024;
use constant MAC_PERSISTENT_CACHE_PATH => catdir($ENV{HOME}, 'Library/Application Support/Spotify/PersistentCache/Storage');
use constant LINUX_PERSISTENT_CACHE_PATH => catdir(($ENV{XDG_CACHE_HOME} || catdir($ENV{HOME}, '.cache')), 'spotify/Storage');

# Unfortunately we don't have any user information in the folder hierarchy data. Thus we have to take some guesses.
# If this percentage of playlists is in the top matching hiearchy, then we'll use it. Otherwise not.
use constant ASSUMED_HIT_THRESHOLD => 0.8;

tie my %treeCache, 'Tie::Cache::LRU::Expires', EXPIRES => 60, 5;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');

sub parse {
	my ($filename) = @_;

	my $data = read_file($filename);
	main::idle();

	my @items = split /spotify:[use]/, $data;

	my @stack = ();
	my $parent = '/';
	my $map = {};

	my $i = 0;
	foreach my $item (@items) {
		if ($item =~ /^ser:/) {
			$map->{'spotify:u' . substr($item, 0, -1)} = $parent;
		}
		elsif ($item =~ /^tart-group/) {
			my @tags = split ':', $item;
			my $name = uri_unescape($tags[-1]);
			$name =~ s/\+/ /g;
			if (Slim::Utils::Unicode::looks_like_latin1($name)) {
				$name = substr($name, 0, -1);
			}
			else {
				$name = Slim::Utils::Unicode::utf8decode( Slim::Utils::Unicode::recomposeUnicode($name) );
			}

			$map->{$tags[-2]} = {
				name => $name,
				parent => $parent
			};

			push @stack, $parent;
			$parent = $tags[-2];
		}
		elsif ($item =~ /nd-group/) {
			$parent = pop @stack;
		}
	}

	return $map;
}

sub findAllCachedFiles {
	my $cacheFolder;

	if (main::ISMAC) {
		$cacheFolder = MAC_PERSISTENT_CACHE_PATH;
	}
	elsif (main::ISWINDOWS) {
		# C:\Users\michael\AppData\Local\Spotify\Storage
		require Win32;
		$cacheFolder = catdir(Win32::GetFolderPath(Win32::CSIDL_LOCAL_APPDATA), 'Spotify', 'Storage');
	}
	else {
		$cacheFolder = LINUX_PERSISTENT_CACHE_PATH;
	}

	my $files = File::Next::files($cacheFolder);

	my $i = 0;
	my $candidates = [];
	while ( defined (my $file = $files->()) ) {
		if ($file =~ /\.file$/ && -s $file < MAX_FILE_TO_PARSE) {
			my $data = read_file($file);
			if ($data =~ /\bstart-group\b/) {
				push @$candidates, $file;
			}
		}

		main::idle() if !(++$i % 10);
	}

	return $candidates;
}

sub getTree {
	my ($class, $user, $uris) = @_;

	my $key = md5_hex(join('||', sort @$uris));

	if (my $cached = $treeCache{$key}) {
		return $cached;
	}

	my $max = scalar @$uris;
	my (%stats, $paths);

	if (my $cached = $cache->get("spotty-playlist-folders-$user")) {
		$paths = [$cached];
	}
	else {
		$paths = findAllCachedFiles();
	}

	foreach my $candidate ( @$paths ) {
		my $data = parse($candidate);
		my $hits = 0;
		foreach (@$uris) {
			$hits++ if $data->{$_};
		}

		$stats{$hits / $max} = {
			path => $candidate,
			data => $data
		};
	}

	my ($winner) = sort { $b <=> $a } keys %stats;
	if ($winner && $winner > ASSUMED_HIT_THRESHOLD) {
		main::INFOLOG && $log->is_info && $log->info(sprintf('Found a hierarchy which has %s%% of the playlist\'s tracks', int($winner * 100)));
		my $treeData = $stats{$winner};

		# remember what file we chose for this user
		$cache->set("spotty-playlist-folders-$user", $treeData->{path}, 86400);
		return $treeCache{$key} = $treeData->{data};
	}
}

1;
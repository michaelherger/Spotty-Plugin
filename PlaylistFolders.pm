package Plugins::Spotty::PlaylistFolders;

# This playlist hierarchy parser is based on https://github.com/mikez/spotify-folders

use strict;

use Digest::MD5 qw(md5_hex);
use File::Basename qw(basename);
use File::Next;
use File::Slurp;
use File::Spec::Functions qw(catdir catfile);
use JSON::XS::VersionOneAndTwo;
use Tie::Cache::LRU::Expires;
use URI::Escape qw(uri_unescape);

use Slim::Utils::Cache;
use Slim::Utils::Log;
use Slim::Utils::Prefs;
use Slim::Utils::Strings qw(string);

use constant MAX_PLAYLIST_FOLDER_FILE_AGE => 86400 * 30;
use constant MAX_FILE_TO_PARSE => 512 * 1024;
use constant MAC_PERSISTENT_CACHE_PATH => catdir($ENV{HOME}, 'Library/Application Support/Spotify/PersistentCache/Storage');
use constant LINUX_PERSISTENT_CACHE_PATH => catdir(($ENV{XDG_CACHE_HOME} || catdir($ENV{HOME}, '.cache')), 'spotify/Storage');

# Unfortunately we don't have any user information in the folder hierarchy data. Thus we have to take some guesses.
# If this percentage of playlists is in the top matching hiearchy, then we'll use it. Otherwise not.
use constant ASSUMED_HIT_THRESHOLD => 0.8;

tie my %treeCache, 'Tie::Cache::LRU::Expires', EXPIRES => 60, 5;

my $cache = Slim::Utils::Cache->new();
my $log = logger('plugin.spotty');

# the file upload is handled through a custom request handler, dealing with multi-part POST requests
Slim::Web::Pages->addRawFunction("plugins/spotty/uploadPlaylistFolderData", \&handleUpload);

sub parse {
	my ($filename) = @_;

	return {} unless $filename && -f $filename && -r _ && -s _ < MAX_FILE_TO_PARSE;

	my $data = read_file($filename) || '';
	main::idle();

	# don't continue if there are no groups - we're not interested in flat lists
	return {} unless $data && $data =~ /\bstart-group\b/;

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

	if (my $cached = $treeCache{'spotty-playlist-folders'}) {
		return $cached;
	}

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

	my $i = 0;
	my $candidates = [];

	for my $folder (Plugins::Spotty::Plugin->cacheFolder('playlistFolders'), $cacheFolder) {
		next unless -d $folder && -r _;

		my $files = File::Next::files({
			file_filter => sub {
				main::idle() if !(++$i % 10);
				return -s $File::Next::name < MAX_FILE_TO_PARSE && /\.file$/;
			}
		}, $folder);
		main::idle();

		while ( defined (my $file = $files->()) ) {
			my $data = read_file($file, scalar_ref => 1);
			if ($$data =~ /\bstart-group\b/) {
				push @$candidates, $file;
			}
		}
	}

	return $treeCache{'spotty-playlist-folders'} = $candidates;
}

sub getTree {
	my ($class, $user, $uris) = @_;

	my $key = md5_hex(join('||', sort @$uris));

	if (my $cached = $treeCache{$key}) {
		return $cached;
	}

	my $max = scalar @$uris;
	my (%stats, $paths);

	my $cachedPath = $cache->get("spotty-playlist-folders-$user");
	if ( $cachedPath && -r $cachedPath ) {
		main::INFOLOG && $log->is_info && $log->info("Using cached file path for user $user: $cachedPath");
		$paths = [$cachedPath];
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
		$cache->set("spotty-playlist-folders-$user", $treeData->{path}, 7*86400);
		return $treeCache{$key} = $treeData->{data};
	}
}

sub handleUpload {
	my ($httpClient, $response, $func) = @_;

	my $request = $response->request;
	my $result = {};

	my $t = Time::HiRes::time();

	main::INFOLOG && $log->is_info && $log->info("New data to upload. Size: " . formatKB($request->content_length));

	if ( $request->content_length > MAX_FILE_TO_PARSE ) {
		$result = {
			error => string('PLUGIN_DNDPLAY_FILE_TOO_LARGE', formatKB($request->content_length), formatKB(MAX_FILE_TO_PARSE)),
			code  => 413,
		};
	}
	else {
		my $ct = $request->header('Content-Type');
		my ($boundary) = $ct =~ /boundary=(.*)/;

		my ($k, $fh, $uploadedFile);
		my $folder = Plugins::Spotty::Plugin->cacheFolder('playlistFolders');

		# open a pseudo-filehandle to the uploaded data ref for further processing
		open TEMP, '<', $request->content_ref;

		while (<TEMP>) {
			if ( Time::HiRes::time - $t > 0.2 ) {
				main::idleStreams();
				$t = Time::HiRes::time();
			}

			# a new part starts - reset some variables
			if ( /--\Q$boundary\E/i ) {
				$k = '';
				close $fh if $fh;
			}

			# write data to file handle
			elsif ( $fh ) {
				print $fh $_;
			}

			# we got an uploaded file name
			elsif ( !$k && /filename="(.+?)"/i ) {
				$k = $1;
				main::INFOLOG && $log->is_info && $log->info("New file to upload: $k")
			}

			# we got the separator after the upload file name: file data comes next. Open a file handle to write the data to.
			elsif ( $k && /^\s*$/ ) {
				mkdir $folder if ! -d $folder;

				$uploadedFile = catfile($folder, $k);
				open($fh, '>', $uploadedFile) || $log->warn("Failed to open file $uploadedFile: $@");
			}
		}

		close $fh if $fh;

		close TEMP;

		main::idle();

		# some cache cleanup
		if ( $folder && -d $folder && opendir(DIR, $folder) ) {
			foreach my $file ( grep { -f $_ && -r _ } map { catfile($folder, $_) } readdir(DIR) ) {
				my (undef, undef, undef, undef, undef, undef, undef, undef, undef, $mtime) = stat($file);
				unlink $file if time() - $mtime > MAX_PLAYLIST_FOLDER_FILE_AGE;
			}
		}

		my $parsed = parse($uploadedFile);
		if (!$parsed || !ref $parsed || keys %$parsed < 2) {
			$result->{error} = 'No playlist items found';
		}

		if ( $result->{error} && $uploadedFile && -f $uploadedFile ) {
			unlink $uploadedFile;
			$result->{basename($uploadedFile)} = 'failed';
		}
		else {
			$result->{basename($uploadedFile)} = 'success';
		}
	}

	$log->error($result->{error}) if $result->{error};

	my $content = to_json($result);
	$response->header( 'Content-Length' => length($content) );
	$response->code($result->{code} || 200);
	$response->header('Connection' => 'close');
	$response->content_type('application/json');

	Slim::Web::HTTP::addHTTPResponse( $httpClient, $response, \$content	);
}

sub formatKB {
	return Slim::Utils::Misc::delimitThousands(int($_[0] / 1024)) . 'KB';
}

1;
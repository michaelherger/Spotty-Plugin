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

	my $key = _cacheKey($filename);
	my $cached = $cache->get($key);

	if ($cached && ref $cached) {
		return $cached;
	}

	my $data = read_file($filename) || '';
	main::idleStreams();

	# don't continue if there are no groups - we're not interested in flat lists
	return {} unless $data && $data =~ /\bstart-group\b/;

	my @items = split /spotify:[use]/, $data;

	my @stack = ();
	my $parent = '/';
	my $map = {};

	my $i = 0;
	foreach my $item (@items) {
		# Note: '\r' marks end of repeated block. This might break in
		# future versions of Spotify. An alternative solution is to read
		# the number of repeats coded into the protobuf file.
		$item =~ s/(.*?)\r.*/$1/s;

		if ($item =~ /^ser:/) {
			# the the last part of the URI is an ID which must be no longer than 22 characters
			$item =~ s/^(ser(:[^:]*){0,1}:playlist:[a-z0-9]{22}).*$/$1/i;

			$map->{'spotify:u' . $item} = {
				parent => $parent,
				order => $i++
			};
		}
		elsif ($item =~ /^tart-group/) {
			my @tags = split ':', $item;
			my $name = uri_unescape($tags[-1]);
			$name =~ s/\+/ /g;
			if (Slim::Utils::Unicode::looks_like_latin1($name)) {
				$name = substr(Slim::Utils::Unicode::utf8decode($name), 0, -1);
			}
			else {
				$name = Slim::Utils::Unicode::utf8decode( Slim::Utils::Unicode::recomposeUnicode($name) );
			}

			main::INFOLOG && $log->is_info && $log->info("Start Group $name : $parent ($i)");

			$map->{$tags[-2]} = {
				name => $name,
				order => $i++,
				isFolder => 1,
				parent => $parent
			};

			push @stack, $parent;
			$parent = $tags[-2];
			main::INFOLOG && $log->is_info && $log->info("Start Group Push : $parent ($i)");

		}
		elsif ($item =~ /nd-group/) {
			$parent = pop @stack;
			main::INFOLOG && $log->is_info && $log->info("End Group : $parent ($i)");
		}
	}

	$cache->set($key, $map, 86400 * 7);
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
				main::idleStreams() if !(++$i % 10);
				return -s $File::Next::name < MAX_FILE_TO_PARSE && /\.file$/;
			}
		}, $folder);

		while ( defined (my $file = $files->()) ) {
			my $key = _cacheKey($file);

			# we keep state in cache, as it's cheaper to look up than parsing the file all the time
			my $cached = $cache->get($key);
			if (defined $cached) {
				push @$candidates, $file if $cached;
			}
			else {
				my $data = read_file($file, scalar_ref => 1);
				if ($$data =~ /\bstart-group\b/) {
					$cache->set($key, 1, 86400 * 7);
					push @$candidates, $file;
				}
				else {
					$cache->set($key, 0, 86400 * 7);
				}
			}
		}
	}

	return $treeCache{'spotty-playlist-folders'} = $candidates;
}

sub _cacheKey {
	my $file = $_[0];
	my $size = (stat($file))[7];
	my $mtime = (stat(_))[9];

	return join(':', 'spotty', $file, $size, $mtime);
}

sub getTree {
	my ($class, $uris) = @_;

	my $key = md5_hex(join('||', sort @$uris));

	if (my $cached = $treeCache{$key}) {
		return $cached;
	}

	my $max = scalar @$uris;
	my @stats;

	my $paths = findAllCachedFiles();

	foreach my $candidate ( @$paths ) {
		my $data = parse($candidate);
		my $hits = 0;
		foreach (@$uris) {
			$hits++ if $data->{$_};
		}

		push @stats, {
			ratio => $hits / $max,
			path => $candidate,
			data => $data,
			timestamp => (stat($candidate))[9]
		};
	}

	my ($winner) = sort {
		# if two have the same hit-rate, the more recent wins
		if ($a->{ratio} == $b->{ratio}) {
			return $b->{timestamp} <=> $a->{timestamp};
		}

		return $b->{ratio} <=> $a->{ratio};
	} @stats;

	if ($winner && ref $winner && $winner->{ratio} > ASSUMED_HIT_THRESHOLD) {
		main::INFOLOG && $log->is_info && $log->info(sprintf('Found a hierarchy which has %s%% of the playlist\'s tracks', int($winner->{ratio} * 100)));
		return $treeCache{$key} = $winner->{data};
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

		main::idleStreams();

		# some cache cleanup
		if ( $folder && -d $folder && opendir(DIR, $folder) ) {
			foreach my $file ( grep { -f $_ && -r _ } map { catfile($folder, $_) } readdir(DIR) ) {
				my $mtime = (stat(_))[9];
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
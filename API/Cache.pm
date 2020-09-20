package Plugins::Spotty::API::Cache;

use strict;

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Spotty', 'lib');
use Hash::Merge qw(merge);

use Slim::Utils::Cache;

use constant CACHE_TTL => 86400 * 7;
use constant TTL => 86400 * 90;

my $self;
my $cache = Slim::Utils::Cache->new();

sub new {
	my ($class) = @_;

	return $self if $self;

	$self = {
		cache => Slim::Utils::Cache->new('spotty', 0),
	};

	# right precedence, don't add duplicates to lists
	Hash::Merge::specify_behavior({
		SCALAR => {
			SCALAR => sub { $_[1] },
			ARRAY  => sub { [ $_[0], @{$_[1]} ] },
			HASH   => sub { $_[1] },
		},
		ARRAY => {
			SCALAR => sub { $_[1] },
			# customized behaviour: uniq list based on URI if URI is defined. This will get rid of duplicate artists
			ARRAY  => sub {
				my %seen;
				[ grep { $_->{uri} ? !$seen{$_->{uri}}++ : 1 } @{$_[0]}, @{$_[1]} ]
			},
			HASH   => sub { $_[1] },
		},
		HASH => {
			SCALAR => sub { $_[1] },
			ARRAY  => sub { [ values %{$_[0]}, @{$_[1]} ] },
			HASH   => sub { Hash::Merge::_merge_hashes( $_[0], $_[1] ) },
		},
	}, 'NO_DUPLICATES');

	return bless $self, $class;
}

sub get {
	my ($self, $uri) = @_;
	return $self->{cache}->get($uri);
}

sub set {
	my ($self, $uri, $data, $fast) = @_;

	return if !$uri;

	my $cached = $self->get($uri);
	return if ($fast && $cached);

	my $merged;
	if ($cached) {
		$merged = merge($cached, $data);
	}

	$self->{cache}->set($uri, $merged || $data, time() + TTL);

	return $merged || $data;
}

sub getLargestArtwork {
	my ($class, $images) = @_;

	if ( $images && ref $images && ref $images eq 'ARRAY' ) {
		my ($image) = sort { $b->{height} <=> $a->{height} } @$images;

		return $image->{url} if $image;
	}

	return '';
}

sub cleanupTags {
	my ($class, $text) = @_;
	# remove additions like "remaster", "Deluxe edition" etc.
	# $text =~ s/(?<!^)[\(\[].*?[\)\]]//g if $text !~ /Peter Gabriel .*\b[1-4]\b/i;
	$text =~ s/[([][^)\]]*?(deluxe|edition|remaster|live|anniversary)[^)\]]*?[)\]]//ig;
	$text =~ s/ -[^-]*(deluxe|edition|remaster|live|anniversary).*//ig;

	$text =~ s/\s*$//;
	$text =~ s/^\s*//;

	return $text;
}

sub normalize {
	my ($self, $item, $fast) = @_;

	my $type = $item->{type} || '';

	if ($type eq 'album') {
		$item->{image}  = $self->getLargestArtwork(delete $item->{images});
		$item->{artist} ||= $item->{artists}->[0]->{name} if $item->{artists} && ref $item->{artists};

		$item = _removeUnused($item, 'copyright', 'copyrights', 'label');
		foreach my $artist ( @{$item->{artists} || []} ) {
			_removeUnused($artist);
		}

		my $minAlbum = {
			name         => $item->{name},
			artists      => $item->{artists},
			image        => $item->{image},
			id           => $item->{id},
			uri          => $item->{uri},
			release_date => $item->{release_date},
			album_type   => $item->{album_type},
			added_at     => $item->{added_at},
		};

		$item->{tracks}  = [ map {
			$_->{album} = $minAlbum unless $_->{album} && $_->{album}->{name};

			$self->normalize($_, $fast)
		} @{ $item->{tracks}->{items} } ] if $item->{tracks};

		$item = $self->set($item->{uri}, $item, $fast);
	}
	elsif ($type eq 'playlist') {
		if ( $item->{owner} && ref $item->{owner} ) {
			$item->{creator} = $item->{owner}->{id};
			my $ownerId = Slim::Utils::Unicode::utf8off($item->{owner}->{id});
			if ( ($cache->get('playlist_owner_' . $item->{id}) || '') ne $ownerId)  {
				$cache->set('playlist_owner_' . $item->{id}, $ownerId, 86400*30);
			}
		}

		$item->{image} = $self->getLargestArtwork(delete $item->{images});
		$item = _removeUnused($item, 'primary_color');
	}
	elsif ($type eq 'artist') {
		$item->{sortname} = Slim::Utils::Text::ignoreArticles($item->{name});
		$item->{image} = $self->getLargestArtwork(delete $item->{images});

		_removeUnused($item);

		if (!$item->{image}) {
			$item->{image} = $cache->get('spotify_artist_image_' . $item->{id});
		}
		elsif ( !$fast || !$cache->get('spotify_artist_image_' . $item->{id}) ) {
			$cache->set('spotify_artist_image_' . $item->{id}, $item->{image}, CACHE_TTL);
		}
	}
	elsif ($type eq 'show') {
		$item->{image} = $self->getLargestArtwork(delete $item->{images});
		$item->{artists} ||= [{ name => $item->{publisher} }] if $item->{publisher};
		delete $item->{available_markets};

		my $minShow = {
			name => $item->{name},
			artists => $item->{artists},
			image => $item->{image},
		};

		$item->{episodes}  = [ map {
			$_->{album} = $minShow unless $_->{show} && $_->{show}->{name};

			$self->normalize($_, $fast)
		} @{ $item->{episodes}->{items} } ] if $item->{episodes};
	}
	elsif ($type eq 'episode') {
		$item->{album}  ||= {};

		$item->{album}->{name} ||= $item->{show}->{name} if $item->{show}->{name};

		$item->{image} ||= $self->getLargestArtwork(delete $item->{images}) if $item->{images};
		$item->{album}->{image} ||= $self->getLargestArtwork(delete $item->{show}->{images}) if $item->{show}->{images};
		$item->{album}->{image} ||= $self->getLargestArtwork(delete $item->{album}->{images}) if $item->{album}->{images};
		_removeUnused($item->{album});

		delete $item->{show}->{available_markets};
		$item->{artists} ||= [{ name => $item->{publisher} }] if $item->{publisher};
		$item->{artists} ||= [{ name => $item->{show}->{publisher} }] if $item->{show}->{publisher};
		$item->{artists} ||= $item->{album}->{artists} if $item->{album}->{artists};

		# Cache all tracks for use in track_metadata
		_removeUnused($item);
		$cache->set( $item->{uri}, $item, CACHE_TTL ) if $item->{uri} && (!$fast || !$cache->get( $item->{uri} ));
	}
	# track
	elsif ($type eq 'track') {
		$item->{album}  ||= {};
		$item->{album}->{image} ||= $self->getLargestArtwork(delete $item->{album}->{images}) if $item->{album}->{images};
		$item->{image} ||= $item->{album}->{image} if $item->{album}->{image};
		_removeUnused($item->{album});

		foreach my $artist ( @{$item->{artists} || []} ) {
			_removeUnused($artist);
		}

		foreach my $artist ( @{$item->{album}->{artists} || []} ) {
			_removeUnused($artist);
		}

		_removeUnused($item, 'preview_url', 'is_local', 'episode', 'external_ids');
		_removeUnused($item->{linked_from});

		# Cache all tracks for use in track_metadata
		$item = $self->set($item->{uri}, $item, $fast);

		# sometimes we'd get metadata for an alternative track ID
		if ( $item->{linked_from} && $item->{linked_from}->{uri} ) {
			$self->set($item->{linked_from}->{uri}, $item, $fast);
		}
	}

	$item->{description} =~ s/<.+?>//g if $item->{description};
	delete $item->{available_markets};		# this is rather lengthy, repetitive and never used

	return $item;
}

sub _removeUnused {
	my $item = shift;
	foreach ( qw(available_markets href external_urls external_ids type), @_ ) {
		delete $item->{$_};
	}

	return $item;
}


1;
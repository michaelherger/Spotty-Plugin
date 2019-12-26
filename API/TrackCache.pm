package Plugins::Spotty::API::TrackCache;

use File::Spec::Functions qw(catdir);
use FindBin qw($Bin);
use lib catdir($Bin, 'Plugins', 'Spotty', 'lib');
use Hash::Merge qw(merge);

use Slim::Utils::Cache;

sub new {
	my ($class) = @_;

	my $cache = Slim::Utils::Cache->new('sptytrks', 0);
	$cache->{_cache}->{default_expires_in} = 86400 * 90;

	my $self = {
		cache => $cache,
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
	return shift->{cache}->get(@_);
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

	$self->{cache}->set($uri, $merged || $data);
}

1;
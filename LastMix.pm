package Plugins::Spotty::LastMix;

use strict;

use base qw(Plugins::LastMix::Services::Base);

use Slim::Utils::Prefs;

use Plugins::Spotty::Plugin;

my $prefs = preferences('plugin.spotty');

sub isEnabled {
	my ($class, $client) = @_;

	return unless $client;

	return unless Slim::Utils::PluginManager->isEnabled('Plugins::Spotty::Plugin');

	return Plugins::Spotty::AccountHelper->getCredentials($client) ? 'Spotty' : undef;
}

sub lookup {
	my ($class, $client, $cb, $args) = @_;

	$class->client($client) if $client;
	$class->cb($cb) if $cb;
	$class->args($args) if $args;

	Plugins::Spotty::Plugin->getAPIHandler($client)->search(sub {
		my $searchResult = shift;

		if (!$searchResult) {
			$class->cb->();
		}

		my $candidates = [];
		my $searchArtist = $class->args->{artist};

		for my $track ( @$searchResult ) {
			next unless $track->{artists} && ref $track->{artists} && $track->{uri} && $track->{name};

			# might want to investigate them all?
			my $artist = $track->{artists}->[0]->{name} || next;

			push @$candidates, {
				title  => $track->{name},
				artist => $artist,
				url    => $track->{uri},
			};
		}

		$class->cb->( $class->extractTrack($candidates) );
	},{
		query => sprintf("artist:%s track:%s", $args->{artist}, $args->{title}),
		type  => 'track',
		limit => 5,
	});
}

sub protocol { 'spotify' }


1;

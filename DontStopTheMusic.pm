package Plugins::Spotty::DontStopTheMusic;

use strict;

use Digest::MD5 qw(md5_hex);

use Slim::Plugin::DontStopTheMusic::Plugin;
use Slim::Schema;
use Slim::Utils::Log;

use Plugins::Spotty::Plugin;

my $log = logger('plugin.spotty');

sub init 	{
	Slim::Plugin::DontStopTheMusic::Plugin->registerHandler('PLUGIN_SPOTTY_RECOMMENDATIONS', \&dontStopTheMusic);
}

sub dontStopTheMusic {
	my ($client, $cb) = @_;

	my $seedTracks = Slim::Plugin::DontStopTheMusic::Plugin->getMixableProperties($client, 5);

	# don't seed from radio stations - only do if we're playing from some track based source
	if ($seedTracks && ref $seedTracks && scalar @$seedTracks) {
		main::INFOLOG && $log->info("Auto-mixing Spotify tracks from random items in current playlist");

		my $spotty = Plugins::Spotty::Plugin->getAPIHandler($client);

		if (!$spotty) {
			$cb->($client);
			return;
		}

		my @searchData;
		my $seedData = {
			limit => 25
		};

		my $getRecommendations = sub {
			if ( grep /^seed_/, keys %$seedData ) {
				$spotty->recommendations(sub {
					$cb->($client, [
						map {
							$_->{uri} =~ /(track:.*)/;
							"spotify://$1";
						} @{$_[0] || []}
					]);
				}, $seedData);
			}
			else {
				$cb->($client);
			}
		};

		foreach my $track ( @$seedTracks ) {
			# if this is a RemoteTrack item, we might want to check whether it's a Spotify track already
			if ( $track->{id} && $track->{id} =~ /^-\d+$/ ) {
				my $trackObj = Slim::Schema->find('Track', $track->{id});
				if ($trackObj && $trackObj->url) {
					$track->{id} = $trackObj->url;
				}
			}

			if ( $track->{id} && $track->{id} =~ /track:([a-z0-9]+)/i ) {
				$seedData->{seed_tracks} ||= [];
				push @{$seedData->{seed_tracks}}, $1;
			}
			# if we haven't found an ID already, build search data
			elsif ( $track->{artist} && $track->{title} ) {
				push @searchData, [ $track->{artist}, $track->{title} ];
			}
		}

		# if we're not done yet...
		if ( scalar @searchData ) {
			my $findArtistSeed = sub {
				$spotty->search(sub {
					my $artists = shift || [];

					foreach my $searchData ( @searchData ) {
						my $artist = $searchData->[0] || next;

						if ( my ($match) = grep {
							$_->{name} =~ /\Q$artist\E/i
						} @$artists ) {
							$seedData->{seed_artists} ||= [];
							push @{$seedData->{seed_artists}}, $match->{id};
							$searchData = [];
						}
					}

					if ( $seedData->{seed_artists} && scalar @{$seedData->{seed_artists}} > 5 ) {
						splice @{$seedData->{seed_artists}}, 5;
					}

					$getRecommendations->();
				},{
					series => { map { $_ => {
						q      => sprintf('artist:"%s"', $_),
						type   => 'artist',
						market => 'from_token',
						limit  => 5
					} } map {
						$_->[0];
					} grep {
						$_->[0]
					} @searchData },
					type => 'artist'
				});
			};

			$spotty->search(sub {
				my $tracks = shift || [];

				foreach my $searchData ( @searchData ) {
					my ($artist, $title) = @$searchData;

					if ( my ($match) = grep {
						$_->{name} =~ /^\Q$title\E/i
						&& $_->{artists} && grep {
							$_->{name} =~ /\Q$artist\E/i
						} @{$_->{artists}}
					} @$tracks ) {
						$seedData->{seed_tracks} ||= [];
						push @{$seedData->{seed_tracks}}, $match->{id};
						$searchData = [];
					}
				}

				if ( $seedData->{seed_tracks} && scalar @{$seedData->{seed_tracks}} > 5 ) {
					splice @{$seedData->{seed_tracks}}, 5;
				}

				if ( !grep { scalar @{$_} } @searchData ) {
					$getRecommendations->();
				}
				else {
					$findArtistSeed->();
				}
			},{
				series => { map {
					my $key = $_->[0] . $_->[1];
					utf8::encode($key);
					md5_hex($key) => {
						q      => sprintf('%s artist:"%s"', $_->[1], $_->[0]),
						type   => 'track',
						market => 'from_token',
						limit  => 5
					};
				} @searchData },
				type => 'track'
			});
		}
		else {
			$getRecommendations->();
		}
	}
	else {
		$cb->($client);
	}
}


1;
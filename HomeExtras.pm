package Plugins::Spotty::HomeExtras;

use strict;

use Plugins::Spotty::OPML;

Plugins::Spotty::HomeExtraSpotty->initPlugin();
Plugins::Spotty::HomeExtraHome->initPlugin();
Plugins::Spotty::HomeExtraWhatsNew->initPlugin();
Plugins::Spotty::HomeExtraTopTracks->initPlugin();
Plugins::Spotty::HomeExtraPopularPlaylists->initPlugin();

1;

package Plugins::Spotty::HomeExtraBase;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	my $tag = $args{tag};

	$class->SUPER::initPlugin(
		feed => sub { handleFeed($tag, @_) },
		tag  => "SpottyExtras${tag}",
		extra => {
			title => $args{title},
			icon  => $args{icon} || Plugins::Spotty::Plugin->_pluginDataFor('icon'),
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($tag, $client, $cb, $args) = @_;

	$args->{params}->{menu} = "home_heroes_${tag}";

	Plugins::Spotty::OPML::handleFeed($client, $cb, $args);
}

package Plugins::Spotty::HomeExtraSpotty;

use base qw(Plugins::Spotty::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_SPOTTY',
		tag => 'spotty'
	);
}

1;


package Plugins::Spotty::HomeExtraHome;

use base qw(Plugins::Spotty::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_SPOTTY_HOME_EXTRA_HOME',
		tag => 'home'
	);
}

1;


package Plugins::Spotty::HomeExtraWhatsNew;

use base qw(Plugins::Spotty::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_SPOTTY_WHATS_NEW',
		tag => 'whatsnew'
	);
}

1;


package Plugins::Spotty::HomeExtraTopTracks;

use base qw(Plugins::Spotty::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_SPOTTY_TOP_TRACKS',
		tag => 'toptracks'
	);
}

1;


package Plugins::Spotty::HomeExtraPopularPlaylists;

use base qw(Plugins::Spotty::HomeExtraBase);

sub initPlugin {
	my ($class, %args) = @_;

	$class->SUPER::initPlugin(
		title => 'PLUGIN_SPOTTY_HOME_EXTRA_POPULAR_PLAYLISTS',
		tag => 'popularplaylists'
	);
}

1;


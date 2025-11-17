package Plugins::Spotty::HomeExtras;

use strict;

use Plugins::Spotty::OPML;

Plugins::Spotty::HomeExtraHome->initPlugin();

1;

package Plugins::Spotty::HomeExtraHome;

use base qw(Plugins::MaterialSkin::HomeExtraBase);

sub initPlugin {
	my $class = shift;

	$class->SUPER::initPlugin(
		feed => \&handleFeed,
		tag  => 'spottyHomeExtras',
		extra => {
			title => 'PLUGIN_SPOTTY_HOME_EXTRA_HOME',
			icon  => Plugins::Spotty::Plugin->_pluginDataFor('icon'),
			needsPlayer => 1,
		}
	);
}

sub handleFeed {
	my ($client, $cb, $args) = @_;

	$args->{params}->{menu} = 'home_heroes';

	Plugins::Spotty::OPML::handleFeed($client, $cb, $args);
}

1;
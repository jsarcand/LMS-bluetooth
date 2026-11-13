package Plugins::Bluetooth::Settings;

use strict;
use warnings;
use utf8;

use base qw(Slim::Web::Settings);

use Slim::Utils::Prefs;

use Plugins::Bluetooth::Plugin;
use Plugins::Bluetooth::Registry;

my $prefs = preferences('plugin.bluetooth');

use constant SETTINGS_URL => 'plugins/Bluetooth/settings/basic.html';

sub name {
	my $name = 'PLUGIN_BLUETOOTH';
	return eval { Slim::Web::HTTP::CSRF->protectName($name) } || $name;
}

sub page {
	return eval { Slim::Web::HTTP::CSRF->protectURI(SETTINGS_URL) } || SETTINGS_URL;
}

sub prefs {
	return ($prefs);
}

sub handler {
	my ($class, $client, $params, $callback, $httpClient, $response) = @_;

	if ($params->{bt_action} && $params->{bt_action} eq 'scan') {
		Plugins::Bluetooth::Plugin::launch_scan();
		$params->{bt_notice} = Slim::Utils::Strings::string('PLUGIN_BLUETOOTH_SEARCHING');
	}
	elsif ($params->{bt_action}) {
		my $result = Plugins::Bluetooth::Plugin::apply_form($params);
		if ($result->{ok}) {
			$params->{bt_notice} = Slim::Utils::Strings::string('PLUGIN_BLUETOOTH_SAVED');
		}
		else {
			$params->{bt_notice} = Plugins::Bluetooth::Plugin::error_text($result->{error});
		}
	}

	Plugins::Bluetooth::Plugin::refresh_subs();
	my $state = Plugins::Bluetooth::Plugin::state();
	my %names;
	for my $player (@{ Plugins::Bluetooth::Plugin::players() }) {
		$names{lc $player->{id}} = $player->{name};
	}
	my $view = Plugins::Bluetooth::Registry::view($state);
	$params->{bt_cards} = Plugins::Bluetooth::Registry::cards($state, \%names);
	$params->{bt_found} = Plugins::Bluetooth::Plugin::found($state);
	$params->{bt_bridges} = $view->{bridges};
	$params->{bt_players} = Plugins::Bluetooth::Plugin::players();

	return $class->SUPER::handler($client, $params, $callback, $httpClient, $response);
}

1;

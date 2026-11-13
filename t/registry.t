#!/usr/bin/perl
use strict;
use warnings;
use utf8;
use Test::More;
use FindBin;

require "$FindBin::Bin/../Bluetooth/Registry.pm";

my $state = { bridges => [], devices => [], links => [] };

ok(Plugins::Bluetooth::Registry::add_bridge($state, { id => 'audio', host => '192.168.1.4', port => 8765, name => 'Audio', token => 'secret' })->{ok});
is(Plugins::Bluetooth::Registry::view($state)->{bridges}[0]{has_token}, 1);
ok(!exists Plugins::Bluetooth::Registry::view($state)->{bridges}[0]{token});

my $added = Plugins::Bluetooth::Registry::add_device($state, {
	id => 'firetv', name => 'Fire TV', role => 'input', bridge_id => 'audio', address => 'aa:bb:cc:dd:ee:01',
});
ok($added->{ok});
is($added->{device}{bridge_sync}, 'pending');
ok(!Plugins::Bluetooth::Registry::add_device($state, { id => 'firetv', role => 'input' })->{ok});

ok(Plugins::Bluetooth::Registry::attach($state, { device_id => 'firetv', player_id => 'AA:BB:CC:DD:EE:10', drift_ms => 80 })->{ok});
ok(Plugins::Bluetooth::Registry::attach($state, { device_id => 'firetv', player_id => 'aa:bb:cc:dd:ee:11', drift_ms => 0 })->{ok});

my $view = Plugins::Bluetooth::Registry::view($state);
is($view->{links}[0]{delay_ms}, 280);
is($view->{links}[0]{apart}, 0);
is($view->{links}[1]{delay_ms}, 200);
is($view->{links}[1]{apart}, 1);

ok(Plugins::Bluetooth::Registry::set_drift($state, 'firetv', 'aa:bb:cc:dd:ee:10', -1000)->{ok});
is(Plugins::Bluetooth::Registry::view($state)->{links}[0]{delay_ms}, 60);

my $sub = Plugins::Bluetooth::Registry::add_device($state, { id => 'dynamo', name => 'Dynamo 10', role => 'subwoofer', profile => 'anthem-sub' });
ok($sub->{ok});
is($sub->{device}{bridge_sync}, 'local');
ok(Plugins::Bluetooth::Registry::attach($state, { device_id => 'dynamo', player_id => 'salon', drift_ms => 40 })->{ok});
my ($sublink) = grep { $_->{device_id} eq 'dynamo' } @{ Plugins::Bluetooth::Registry::view($state)->{links} };
is($sublink->{timing}, 'stored');
ok(!defined $sublink->{delay_ms});

ok(!Plugins::Bluetooth::Registry::remove_bridge($state, 'audio')->{ok});
ok(Plugins::Bluetooth::Registry::remove_device($state, 'firetv')->{ok});
ok(!grep { $_->{device_id} eq 'firetv' } @{ $state->{links} });
ok(Plugins::Bluetooth::Registry::remove_bridge($state, 'audio')->{ok});
ok(!Plugins::Bluetooth::Registry::attach($state, { device_id => 'missing', player_id => 'salon' })->{ok});
ok(!Plugins::Bluetooth::Registry::set_drift($state, 'dynamo', 'nobody', 10)->{ok});

is(Plugins::Bluetooth::Registry::role_from_name('S2306|Dynamo 10'), 'subwoofer');
is(Plugins::Bluetooth::Registry::role_from_name('Living Room Fire TV'), 'input');
is(Plugins::Bluetooth::Registry::role_from_name('Salon Headphones'), 'output');

my $scan = <<'SCAN';
[NEW] Device 60:EF:AB:51:7B:6E S2306|Dynamo 10
[NEW] Device 60:EF:AB:27:65:8A S2303|Abyss 8
[NEW] Device AA:BB:CC:DD:EE:01 Living Room Fire TV
SCAN
my $rows = Plugins::Bluetooth::Registry::rows_from_scan($scan);
is($rows->[0]{name}, 'Abyss 8');
is($rows->[0]{role}, 'subwoofer');
is($rows->[0]{profile}, 'anthem-sub');
is($rows->[1]{name}, 'Dynamo 10');
my $empty = { bridges => [], devices => [], links => [] };
my $adopted = Plugins::Bluetooth::Registry::adopt_subs($empty, $rows);
is(scalar @$adopted, 2);
is($empty->{devices}[0]{role}, 'subwoofer');
is(scalar @{ Plugins::Bluetooth::Registry::adopt_subs($empty, $rows) }, 0);
my $chg = "[CHG] Device 60:EF:AB:27:65:8A RSSI: -60\n";
ok(grep { $_ eq '60:EF:AB:27:65:8A' } @{ Plugins::Bluetooth::Registry::macs_from_scan($chg) });
my $colored = "[\e[0;92mNEW\e[0m] Device 60:EF:AB:27:65:8A S2303|Abyss 8\n";
my $colored_rows = Plugins::Bluetooth::Registry::rows_from_scan($colored);
is($colored_rows->[0]{name}, 'Abyss 8');
is($colored_rows->[0]{role}, 'subwoofer');

my $paired = "Device 68:13:F3:FB:82:EA Jean-Sebastien's Fire TV\n[CHG] Device 60:EF:AB:27:65:8A RSSI: -60\n";
my $prows = Plugins::Bluetooth::Registry::rows_from_paired($paired);
is($prows->[0]{name}, "Jean-Sebastien's Fire TV");
is($prows->[0]{role}, 'input');
is($prows->[0]{profile}, 'a2dp-input');

my $menu_cards = [
	{
		id => 'firetv', name => 'Fire TV', role => 'input',
		rows => [
			{ player_id => 'AA:BB', drift_ms => 80, active => 1 },
			{ player_id => 'cc:dd', drift_ms => 0 },
		],
	},
	{
		id => 'phones', name => 'Phones', role => 'output',
		rows => [ { player_id => 'aa:bb', drift_ms => -20 } ],
	},
	{
		id => 'other', name => 'Other', role => 'input',
		rows => [ { player_id => 'ee:ff', drift_ms => 0 } ],
	},
];
my $menu = Plugins::Bluetooth::Registry::player_menu($menu_cards, 'aa:bb');
is(scalar @{ $menu->{play} }, 1);
is($menu->{play}[0]{id}, 'firetv');
is($menu->{play}[0]{active}, 1);
is(scalar @{ $menu->{settings} }, 2);
is($menu->{settings}[1]{role}, 'output');
is($menu->{settings}[1]{drift_ms}, -20);
is(scalar @{ Plugins::Bluetooth::Registry::player_menu($menu_cards, '')->{play} }, 0);
my $pstate = { bridges => [], devices => [], links => [] };
is(scalar @{ Plugins::Bluetooth::Registry::adopt_paired($pstate, $prows) }, 1);
is($pstate->{devices}[0]{role}, 'input');
is(scalar @{ Plugins::Bluetooth::Registry::adopt_paired($pstate, $prows) }, 0);

my $cards = Plugins::Bluetooth::Registry::cards($state, { salon => 'Salon' });
is($cards->[0]{name}, 'Dynamo 10');
is($cards->[0]{rows}[0]{player_name}, 'Salon');
ok(!exists $cards->[0]{address});
ok(!exists $cards->[0]{rows}[0]{delay_ms});

done_testing;

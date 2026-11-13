package Plugins::Bluetooth::Plugin;

use strict;
use warnings;
use utf8;

use base qw(Slim::Plugin::Base);

use JSON::XS::VersionOneAndTwo qw(encode_json decode_json);
use Slim::Control::Request;
use Slim::Player::Client;
use Slim::Utils::Log;
use Slim::Utils::Prefs;

use Plugins::Bluetooth::Registry;
use Plugins::Bluetooth::BTIN;

my $log = Slim::Utils::Log->addLogCategory({
	category     => 'plugin.bluetooth',
	defaultLevel => 'INFO',
	description  => 'PLUGIN_BLUETOOTH',
});

my $prefs = preferences('plugin.bluetooth');
my %seen_logged;

my %ERRORS = (
	bad_id          => 'PLUGIN_BLUETOOTH_ERR_ID',
	bad_host        => 'PLUGIN_BLUETOOTH_ERR_HOST',
	bad_port        => 'PLUGIN_BLUETOOTH_ERR_PORT',
	bad_role        => 'PLUGIN_BLUETOOTH_ERR_ROLE',
	bad_player      => 'PLUGIN_BLUETOOTH_ERR_PLAYER',
	bad_drift       => 'PLUGIN_BLUETOOTH_ERR_DRIFT',
	duplicate_device => 'PLUGIN_BLUETOOTH_ERR_DUP',
	unknown_device  => 'PLUGIN_BLUETOOTH_ERR_DEVICE',
	unknown_link    => 'PLUGIN_BLUETOOTH_ERR_LINK',
	unknown_bridge  => 'PLUGIN_BLUETOOTH_ERR_BRIDGE',
	bridge_in_use   => 'PLUGIN_BLUETOOTH_ERR_BRIDGE_USED',
);

sub getDisplayName { 'PLUGIN_BLUETOOTH' }

sub initPlugin {
	my $class = shift;

	$prefs->init({
		bridges => [],
		devices => [],
		links   => [],
	});

	$class->SUPER::initPlugin(@_);
	Slim::Utils::Log->setLogLevelForCategory('plugin.bluetooth', 'INFO');
	require Slim::Utils::Timers;
	# No scan at startup. A scan runs only while the Bluetooth menu is open.
	_stop_le_scan();
	_arm_link_watch();

	Slim::Control::Request::addDispatch(
		['bluetooth', 'bridges'],
		[0, 1, 1, \&_cmdBridges]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'bridge', 'add', '_id', '_host', '_port', '_name'],
		[0, 0, 1, \&_cmdBridgeAdd]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'bridge', 'remove', '_id'],
		[0, 0, 1, \&_cmdBridgeRemove]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'devices'],
		[0, 1, 1, \&_cmdDevices]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'device', 'add', '_id', '_name', '_role'],
		[0, 0, 1, \&_cmdDeviceAdd]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'device', 'remove', '_id'],
		[0, 0, 1, \&_cmdDeviceRemove]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'attach', '_id', '_player', '_drift'],
		[0, 0, 1, \&_cmdAttach]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'detach', '_id', '_player'],
		[0, 0, 1, \&_cmdDetach]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'drift', '_id', '_player', '_drift'],
		[0, 0, 1, \&_cmdDrift]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'page'],
		[0, 1, 1, \&_cmdPage]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'scan'],
		[0, 1, 1, \&_cmdScan]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'menu'],
		[0, 1, 1, \&_menu]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'input', 'use', '_id'],
		[1, 0, 1, \&_cmdInputUse]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'sub', 'settings'],
		[1, 1, 1, \&_cmdSubSettings]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'sub', 'set', '_id', '_setting', '_value'],
		[0, 0, 1, \&_cmdSubSet]
	);
	Slim::Control::Request::addDispatch(
		['bluetooth', 'sub', 'close'],
		[0, 0, 1, \&_cmdSubClose]
	);

	Slim::Utils::Timers::setTimer(undef, time() + 1, \&_register_scene_modules);

	if (main::WEBUI) {
		require Plugins::Bluetooth::Settings;
		Plugins::Bluetooth::Settings->new;
	}

	# WaveInput leaves arecord running after a Bluetooth input is stopped.
	Slim::Control::Request::subscribe(\&_onPlaylistEvent, [['playlist'], ['stop', 'pause', 'clear']]);
	Slim::Control::Request::subscribe(\&_onMixerVolume, [['mixer'], ['volume']]);

	# AVRCP titles are read in another process. This thread only stats a file.
	_start_meta_watcher();
	_arm_meta_poll();
}

sub shutdownPlugin {
	Slim::Control::Request::unsubscribe(\&_onPlaylistEvent);
	Slim::Control::Request::unsubscribe(\&_onMixerVolume);
	_reap_arecord();
	_stop_meta_watcher();
}

sub webPages {
	if (main::WEBUI) {
		require Plugins::Bluetooth::Settings;
		Plugins::Bluetooth::Settings->new;
	}
}

sub state {
	return {
		bridges => $prefs->get('bridges') || [],
		devices => $prefs->get('devices') || [],
		links   => $prefs->get('links') || [],
	};
}

sub commit {
	my ($state) = @_;
	$prefs->set('bridges', $state->{bridges} || []);
	$prefs->set('devices', $state->{devices} || []);
	$prefs->set('links', $state->{links} || []);
}

sub players {
	my @rows;
	for my $client (Slim::Player::Client::clients()) {
		next unless $client && $client->id;
		push @rows, { id => $client->id, name => $client->name || $client->id };
	}
	return \@rows;
}

sub _notice {
	my ($error) = @_;
	return '' unless $error;
	my $token = $ERRORS{$error} || 'PLUGIN_BLUETOOTH_ERR';
	return Slim::Utils::Strings::string($token);
}

sub _fill {
	my ($request, $result) = @_;
	if (!$result->{ok}) {
		$request->addResult('ok', 0);
		$request->addResult('error', $result->{error} || 'error');
		return;
	}
	$request->addResult('ok', 1);
	my $view = Plugins::Bluetooth::Registry::view(state());
	my $i = 0;
	for my $row (@{ $view->{devices} }) {
		$request->addResultLoop('devices', $i, 'id', $row->{id});
		$request->addResultLoop('devices', $i, 'name', $row->{name});
		$request->addResultLoop('devices', $i, 'role', $row->{role});
		$request->addResultLoop('devices', $i, 'bridge_id', $row->{bridge_id});
		$request->addResultLoop('devices', $i, 'bridge_sync', $row->{bridge_sync});
		$i++;
	}
	$request->addResult('count', $i);
	my $j = 0;
	for my $link (@{ $view->{links} }) {
		$request->addResultLoop('links', $j, 'device_id', $link->{device_id});
		$request->addResultLoop('links', $j, 'player_id', $link->{player_id});
		$request->addResultLoop('links', $j, 'drift_ms', $link->{drift_ms});
		$request->addResultLoop('links', $j, 'timing', $link->{timing});
		$request->addResultLoop('links', $j, 'apart', $link->{apart});
		$request->addResultLoop('links', $j, 'delay_ms', $link->{delay_ms})
			if defined $link->{delay_ms};
		$j++;
	}
}

sub _finish {
	my ($request, $result) = @_;
	_fill($request, $result);
	$request->setStatusDone();
}

sub _cmdBridges {
	my $request = shift;
	$request->setStatusProcessing();
	my $view = Plugins::Bluetooth::Registry::view(state());
	my $i = 0;
	for my $row (@{ $view->{bridges} }) {
		$request->addResultLoop('bridges', $i, 'id', $row->{id});
		$request->addResultLoop('bridges', $i, 'name', $row->{name});
		$request->addResultLoop('bridges', $i, 'host', $row->{host});
		$request->addResultLoop('bridges', $i, 'port', $row->{port});
		$request->addResultLoop('bridges', $i, 'has_token', $row->{has_token});
		$i++;
	}
	$request->addResult('count', $i);
	$request->setStatusDone();
}

sub _cmdBridgeAdd {
	my $request = shift;
	$request->setStatusProcessing();
	my $state = state();
	my $result = Plugins::Bluetooth::Registry::add_bridge($state, {
		id    => $request->getParam('_id'),
		host  => $request->getParam('_host'),
		port  => $request->getParam('_port'),
		name  => $request->getParam('_name'),
	});
	commit($state) if $result->{ok};
	_finish($request, $result);
}

sub _cmdBridgeRemove {
	my $request = shift;
	$request->setStatusProcessing();
	my $state = state();
	my $result = Plugins::Bluetooth::Registry::remove_bridge($state, $request->getParam('_id'));
	commit($state) if $result->{ok};
	_finish($request, $result);
}

sub _cmdDevices {
	my $request = shift;
	$request->setStatusProcessing();
	# Known devices and the current input, from memory. No scan.
	my $json = _page_json($request);
	$request->addResult('page', $json) if $json;
	_finish($request, { ok => 1 });
}

# Cards, paired devices, and which input is active. Reads prefs and the last
# scan file only. Does not start a scan or a bluetoothctl process.
sub _page_json {
	my ($request) = @_;
	my %names;
	my $player_rows = players();
	for my $player (@$player_rows) {
		$names{ lc $player->{id} } = $player->{name};
		$names{ $player->{id} } = $player->{name};
	}
	my $state = state();
	my $cards = Plugins::Bluetooth::Registry::cards($state, \%names);
	my $client = ($request && $request->can('client')) ? $request->client : undef;
	_mark_active($cards, $client ? $client->id : '');
	my $payload = {
		cards   => $cards,
		found   => found($state),
		players => $player_rows,
	};
	return eval { encode_json($payload) };
}

sub _add_page_result {
	my ($request) = @_;
	my $json = _page_json($request);
	if (!$json) {
		$request->addResult('ok', 0);
		$request->addResult('error', 'bad_page');
		return 0;
	}
	$request->addResult('ok', 1);
	$request->addResult('page', $json);
	return 1;
}

sub _cmdPage {
	my $request = shift;
	$request->setStatusProcessing();
	my $noscan = $request->getParam('noscan');
	# Material menus ask for noscan:1. Only the Bluetooth screen scans.
	if (defined $noscan && $noscan ne '' && $noscan ne '0') {
		if (!_add_page_result($request)) {
			$request->setStatusDone();
			return;
		}
		$request->setStatusDone();
		return;
	}
	if (_bluetooth_input_playing()) {
		_stop_le_scan();
	} else {
		_note_bluetooth_menu();
		launch_scan();
	}
	refresh_subs();
	if (!_add_page_result($request)) {
		$request->setStatusDone();
		return;
	}
	$request->setStatusDone();
}

sub _cmdScan {
	my $request = shift;
	$request->setStatusProcessing();
	if (_bluetooth_input_playing()) {
		_stop_le_scan();
		$request->addResult('ok', 0);
		$request->addResult('error', 'input_playing');
		$request->setStatusDone();
		return;
	}
	_note_bluetooth_menu();
	launch_scan();
	$request->addResult('ok', 1);
	$request->setStatusDone();
}

sub _cmdDeviceAdd {
	my $request = shift;
	$request->setStatusProcessing();
	my $fields = {
		id        => $request->getParam('_id'),
		name      => $request->getParam('_name'),
		role      => lc($request->getParam('_role') || ''),
		bridge_id => $request->getParam('bridge_id') || '',
		address   => $request->getParam('address') || '',
		profile   => $request->getParam('profile') || '',
	};
	if (!$fields->{address} && ($fields->{id} || '') =~ /^[0-9A-Fa-f:]{17}$/) {
		$fields->{address} = uc $fields->{id};
	}
	if (!$fields->{profile} && $fields->{role} eq 'subwoofer') {
		$fields->{profile} = ($fields->{name} || '') =~ /svs/i ? 'svs' : 'anthem-sub';
	}
	_change($request, 'add_device', $fields);
}

sub _cmdDeviceRemove {
	my $request = shift;
	$request->setStatusProcessing();
	_change($request, 'remove_device', { id => $request->getParam('_id') });
}

sub _cmdAttach {
	my $request = shift;
	$request->setStatusProcessing();
	_change($request, 'attach', {
		device_id => $request->getParam('_id'),
		player_id => $request->getParam('_player'),
		drift_ms  => $request->getParam('_drift'),
	});
}

sub _cmdDetach {
	my $request = shift;
	$request->setStatusProcessing();
	_change($request, 'detach', {
		device_id => $request->getParam('_id'),
		player_id => $request->getParam('_player'),
	});
}

sub _cmdDrift {
	my $request = shift;
	$request->setStatusProcessing();
	_change($request, 'drift', {
		device_id => $request->getParam('_id'),
		player_id => $request->getParam('_player'),
		drift_ms  => $request->getParam('_drift'),
	});
}

sub _change {
	my ($request, $action, $fields) = @_;
	my $state = state();
	my $result = _mutate($state, $action, $fields);
	if (!$result->{ok}) {
		_finish($request, $result);
		return;
	}
	commit($state);
	_trace($action, $result);
	my $pushed = _push_bridge($state, $action, $result);
	if (!$pushed) {
		_finish($request, $result);
		return;
	}
	# The page returns immediately. The CLI waits so the bridge answer is visible.
	$pushed->(sub {
		my ($sync) = @_;
		my $fresh = state();
		my $id = $result->{device}{id};
		Plugins::Bluetooth::Registry::mark_sync($fresh, $id, $sync) if $id;
		commit($fresh);
		$result->{bridge_sync} = $sync;
		_finish($request, $result);
	});
}

sub apply_form {
	my ($fields) = @_;
	my $action = $fields->{bt_action} || '';
	my $state = state();
	my $result;

	if ($action eq 'add_bridge') {
		my $spec = {
			id    => $fields->{bt_id},
			host  => $fields->{bt_host},
			port  => $fields->{bt_port},
			name  => $fields->{bt_name},
		};
		$spec->{token} = $fields->{bt_token} if defined $fields->{bt_token} && $fields->{bt_token} ne '';
		$result = Plugins::Bluetooth::Registry::add_bridge($state, $spec);
	}
	elsif ($action eq 'remove_bridge') {
		$result = Plugins::Bluetooth::Registry::remove_bridge($state, $fields->{bt_id});
	}
	elsif ($action eq 'add_device' || $action eq 'remove_device' || $action eq 'attach' || $action eq 'detach' || $action eq 'drift') {
		$result = _mutate($state, $action, {
			id        => $fields->{bt_id},
			name      => $fields->{bt_name},
			role      => $fields->{bt_role},
			bridge_id => $fields->{bt_bridge},
			address   => $fields->{bt_address},
			profile   => $fields->{bt_profile},
			device_id => $fields->{bt_id},
			player_id => $fields->{bt_player},
			drift_ms  => $fields->{bt_drift},
		});
		if ($action eq 'add_device' && $result->{ok} && $fields->{bt_player}) {
			my $link = Plugins::Bluetooth::Registry::attach($state, {
				device_id => $result->{device}{id},
				player_id => $fields->{bt_player},
				drift_ms  => $fields->{bt_drift},
			});
			$result->{link} = $link->{link} if $link->{ok};
		}
	}
	else {
		return { ok => 0, error => 'bad_id' };
	}

	commit($state) if $result->{ok};
	_trace($action, $result) if $result->{ok};
	if ($result->{ok}) {
		my $pushed = _push_bridge($state, $action, $result);
		$pushed->(sub {
			my ($sync) = @_;
			my $fresh = state();
			my $id = $result->{device} && $result->{device}{id};
			if ($id) {
				Plugins::Bluetooth::Registry::mark_sync($fresh, $id, $sync);
				commit($fresh);
			}
			$log->info('bridge sync ' . $sync . ' for ' . ($id || ''));
		}) if $pushed;
	}
	return $result;
}

sub _mutate {
	my ($state, $action, $fields) = @_;
	if ($action eq 'add_device') {
		return Plugins::Bluetooth::Registry::add_device($state, $fields);
	}
	if ($action eq 'remove_device') {
		my $mac = _device_mac($state, $fields->{id});
		my $result = Plugins::Bluetooth::Registry::remove_device($state, $fields->{id});
		_reap_arecord($mac) if $result->{ok};
		return $result;
	}
	if ($action eq 'attach') {
		return Plugins::Bluetooth::Registry::attach($state, $fields);
	}
	if ($action eq 'detach') {
		my $mac = _device_mac($state, $fields->{device_id});
		my $result = Plugins::Bluetooth::Registry::detach($state, $fields->{device_id}, $fields->{player_id});
		_reap_arecord($mac) if $result->{ok};
		return $result;
	}
	if ($action eq 'drift') {
		return Plugins::Bluetooth::Registry::set_drift(
			$state, $fields->{device_id}, $fields->{player_id}, $fields->{drift_ms}
		);
	}
	return { ok => 0, error => 'bad_id' };
}

sub _bridge_row {
	my ($state, $id) = @_;
	return undef unless $id;
	for my $bridge (@{ $state->{bridges} || [] }) {
		return $bridge if $bridge->{id} eq $id;
	}
	return undef;
}

sub _push_bridge {
	my ($state, $action, $result) = @_;
	return undef unless $result->{ok} && $result->{device};
	my $device = $result->{device};
	my $bridge = _bridge_row($state, $device->{bridge_id});
	return undef unless $bridge && $bridge->{host} && $bridge->{token};

	my ($path, $body);
	if ($action eq 'add_device') {
		$path = '/v1/devices/register';
		$body = encode_json({
			device_id => $device->{id},
			name      => $device->{name},
			transport => ($device->{role} eq 'input' || $device->{role} eq 'output') ? 'a2dp' : 'ble',
		});
	}
	elsif ($action eq 'remove_device') {
		$path = '/v1/devices/remove';
		$body = encode_json({ device_id => $device->{id} });
	}
	else {
		return undef;
	}

	my $url = 'http://' . $bridge->{host} . ':' . $bridge->{port} . $path;
	my $token = $bridge->{token};
	return sub {
		my ($done) = @_;
		require Slim::Networking::SimpleAsyncHTTP;
		my $http = Slim::Networking::SimpleAsyncHTTP->new(
			sub {
				my $response = shift;
				my $code = $response->code || 0;
				my $sync = 'ok';
				$sync = 'unauthorized' if $code == 401;
				$sync = 'missing' if $code == 404;
				$sync = 'rejected' if $code && $code !~ /^2/;
				$done->($sync);
			},
			sub {
				$done->('offline');
			},
			{ timeout => 3 }
		);
		$http->post(
			$url,
			Authorization  => 'Bearer ' . $token,
			'Content-Type' => 'application/json',
			$body,
		);
	};
}

my %SUB_FIELDS = (
	mode => { kind => 'choice', values => { music => 1, movie => 1, night => 1 } },
	level => { kind => 'int', min => -40, max => 12 },
	phase => { kind => 'int', min => 0, max => 180 },
	polarity => { kind => 'choice', values => { normal => 1, inverted => 1 } },
	lowpass => { kind => 'int', min => 35, max => 120 },
);

my $scene_modules_ready = 0;
my $scene_modules_tries = 0;

sub _register_scene_modules {
	return if $scene_modules_ready;
	$scene_modules_tries++;
	my $loaded = eval { require Plugins::Scenes::Plugin; 1 };
	if (!$loaded || !Plugins::Scenes::Plugin->can('addModule')) {
		Slim::Utils::Timers::setTimer(undef, time() + 2, \&_register_scene_modules)
			if $scene_modules_tries < 5;
		return;
	}
	$scene_modules_ready = 1;
	my @specs = (
		{
			id => 'bluetooth.sub.mode', title => 'Mode du caisson', desc => 'Musique, film ou nuit.',
			setting => 'mode',
			field => { id => 'mode', type => 'enum', label => 'Mode', values => [
				{ id => 'music', label => 'Musique' },
				{ id => 'movie', label => 'Film' },
				{ id => 'night', label => 'Nuit' },
			]},
		},
		{
			id => 'bluetooth.sub.level', title => 'Niveau du caisson', desc => 'De -40 à 12.',
			setting => 'level',
			field => { id => 'value', type => 'number', label => 'Niveau', min => -40, max => 12 },
		},
		{
			id => 'bluetooth.sub.phase', title => 'Phase du caisson', desc => 'De 0 à 180 degrés.',
			setting => 'phase',
			field => { id => 'value', type => 'number', label => 'Phase', min => 0, max => 180 },
		},
		{
			id => 'bluetooth.sub.polarity', title => 'Polarité du caisson', desc => 'Normale ou inversée.',
			setting => 'polarity',
			field => { id => 'polarity', type => 'enum', label => 'Polarité', values => [
				{ id => 'normal', label => 'Normale' },
				{ id => 'inverted', label => 'Inversée' },
			]},
		},
		{
			id => 'bluetooth.sub.lowpass', title => 'Passe-bas du caisson', desc => 'De 35 à 120 Hz.',
			setting => 'lowpass',
			field => { id => 'value', type => 'number', label => 'Passe-bas', min => 35, max => 120 },
		},
	);
	for my $spec (@specs) {
		my $setting = $spec->{setting};
		my $key = $spec->{field}{id};
		Plugins::Scenes::Plugin->addModule({
			id     => $spec->{id},
			title  => $spec->{title},
			group  => 'Caisson',
			desc   => $spec->{desc},
			params => [
				{ id => 'device', type => 'sub', label => 'Caisson' },
				$spec->{field},
			],
			run => sub {
				my ($client, $params, $done) = @_;
				$params = {} unless ref $params eq 'HASH';
				apply_sub_setting({
					device  => $params->{device},
					setting => $setting,
					value   => $params->{$key},
				});
				$done->() if $done;
			},
		});
	}
	return 1;
}

sub _device_by_id {
	my ($state, $id) = @_;
	my $want = lc($id || '');
	return unless $want ne '';
	for my $device (@{ $state->{devices} || [] }) {
		my $row_id = lc($device->{id} || '');
		my $address = lc($device->{address} || '');
		return $device if $row_id eq $want || $address eq $want;
	}
	return;
}

sub _mark_active {
	my ($cards, $player_id) = @_;
	return unless $player_id && ref $cards eq 'ARRAY';
	my $active = $prefs->get('active_input') || {};
	return unless ref $active eq 'HASH';
	my $want = lc($active->{lc $player_id} || '');
	return if $want eq '';
	for my $card (@$cards) {
		next unless $card && ($card->{role} || '') eq 'input';
		my $on = lc($card->{id} || '') eq $want ? 1 : 0;
		for my $row (@{ $card->{rows} || [] }) {
			next unless lc($row->{player_id} || '') eq lc $player_id;
			$row->{active} = $on;
		}
	}
}

sub _cmdInputUse {
	my $request = shift;
	my $client = $request->client;
	my $id = $request->getParam('_id') || '';
	if (!$client || $id eq '') {
		$request->setStatusBadParams();
		return;
	}
	my $state = state();
	my $device = _device_by_id($state, $id);
	my $player_id = lc $client->id;
	my $linked = 0;
	if ($device && ($device->{role} || '') eq 'input') {
		for my $link (@{ $state->{links} || [] }) {
			$linked = 1 if lc($link->{device_id} || '') eq lc($device->{id})
				&& lc($link->{player_id} || '') eq $player_id;
		}
	}
	if (!$linked) {
		$request->addResult('ok', 0);
		$request->addResult('error', 'unknown_link');
		$request->setStatusDone();
		return;
	}
	my $active = $prefs->get('active_input') || {};
	$active = {} unless ref $active eq 'HASH';
	$active->{$player_id} = $device->{id};
	$prefs->set('active_input', $active);
	$log->info('input use name=' . ($device->{name} || '') . ' player=' . $player_id);
	# Raw PCM with a short arecord period. The btin handler also asks the
	# player to start after 32 KB, so a live source does not keep the
	# several-second remote buffer used for files.
	my $mac = uc($device->{address} || $device->{id});
	my $url = 'btin:bluealsa:DEV=' . $mac . ',PROFILE=a2dp,SRV=org.bluealsa';
	# The capture needs the adapter. Drop any menu scan before the stream starts.
	_stop_le_scan();
	_reap_arecord($mac);
	Slim::Control::Request::executeRequest($client, ['playlist', 'play', $url, $device->{name} || 'Bluetooth']);
	$log->info('input play url=' . $url . ' player=' . $player_id);
	$request->addResult('ok', 1);
	$request->addResult('url', $url);
	$request->setStatusDone();
}

sub apply_sub_setting {
	my ($spec) = @_;
	$spec = {} unless ref $spec eq 'HASH';
	my $setting = $spec->{setting} || '';
	my $field = $SUB_FIELDS{$setting};
	my $value = defined $spec->{value} ? $spec->{value} : '';
	$value =~ s/^\s+|\s+$//g if !ref $value;
	my $state = state();
	my $device = _device_by_id($state, $spec->{device});
	if (!$field || !$device || ($device->{role} || '') ne 'subwoofer') {
		$log->warn('sub rejected setting=' . $setting);
		return { ok => 0, error => 'bad_setting' };
	}
	if ($field->{kind} eq 'int') {
		return { ok => 0, error => 'bad_setting' } if $value !~ /^-?\d+$/;
		my $number = int($value);
		if ($number < $field->{min} || $number > $field->{max}) {
			$log->warn('sub rejected name=' . ($device->{name} || '') . ' setting=' . $setting);
			return { ok => 0, error => 'bad_setting' };
		}
		$value = $number;
	} elsif (!$field->{values}{$value}) {
		$log->warn('sub rejected name=' . ($device->{name} || '') . ' setting=' . $setting);
		return { ok => 0, error => 'bad_setting' };
	}
	if (!_is_anthem_sub($device)) {
		$log->warn('sub profile skipped name=' . ($device->{name} || '') . ' profile=' . ($device->{profile} || ''));
		return { ok => 0, error => 'unsupported_profile', sent => 0 };
	}
	# The helper runs in another process. This thread does not wait, and nothing
	# is stored until the sub echoes the value back.
	my $mac = uc($device->{address} || $device->{id} || '');
	my $live = _sub_ble_cmd('write', $mac, $setting, $value);
	if ($live && $live->{error} && $live->{error} eq 'missing_helper') {
		return { ok => 0, error => 'missing_helper', sent => 0 };
	}
	my $confirmed = ($live && $live->{ok} && !$live->{pending})
		? _accept_setting($setting, $live->{value})
		: undef;
	if (defined $confirmed) {
		_store_sub_setting($device->{id}, $setting, $confirmed);
		_cache_sub_value($mac, $setting, $confirmed);
		$log->info('sub wrote name=' . ($device->{name} || '') . ' setting=' . $setting . ' value=' . $confirmed);
		return { ok => 1, sent => 1, value => $confirmed };
	}
	if ($live && $live->{pending}) {
		_arm_write_harvest($device->{id}, $mac, $setting);
		return { ok => 1, sent => 0, pending => 1, value => $value };
	}
	$log->warn('sub write failed name=' . ($device->{name} || '') . ' setting=' . $setting . ' error=' . (($live && $live->{error}) || 'no_readback'));
	return { ok => 0, error => ($live && $live->{error}) || 'no_readback', sent => 0 };
}

sub _store_sub_setting {
	my ($device_id, $setting, $confirmed) = @_;
	return unless $device_id && defined $confirmed;
	my $stored = $prefs->get('sub_settings') || {};
	$stored = {} unless ref $stored eq 'HASH';
	my $row = $stored->{$device_id} || {};
	$row = {} unless ref $row eq 'HASH';
	$row->{$setting} = $confirmed;
	$stored->{$device_id} = $row;
	$prefs->set('sub_settings', $stored);
}

# MartinLogan and Paradigm share the ASCII profile. SVS is a different frame and is not sent.
sub _is_anthem_sub {
	my ($device) = @_;
	return 0 unless $device && ($device->{role} || '') eq 'subwoofer';
	my $profile = lc($device->{profile} || '');
	return 0 if $profile eq 'svs';
	return 1 if $profile eq 'anthem-sub' || $profile eq '';
	return 0;
}

# Keep a wire value only when it is one of the five panel fields.
sub _accept_setting {
	my ($setting, $value) = @_;
	my $field = $SUB_FIELDS{$setting} or return;
	return if !defined $value;
	if ($field->{kind} eq 'int') {
		return if $value !~ /^-?\d+$/;
		my $number = int($value);
		return if $number < $field->{min} || $number > $field->{max};
		return $number;
	}
	return if !$field->{values}{$value};
	return $value;
}

my %SUB_DEFAULTS = (
	mode     => 'music',
	level    => 0,
	phase    => 0,
	polarity => 'normal',
	lowpass  => 80,
);

# Stored settings for one sub, filled with defaults.
sub sub_settings_for {
	my ($device_id) = @_;
	my $stored = $prefs->get('sub_settings') || {};
	$stored = {} unless ref $stored eq 'HASH';
	my $row = $stored->{$device_id || ''};
	$row = {} unless ref $row eq 'HASH';
	my %out = %SUB_DEFAULTS;
	for my $key (keys %SUB_DEFAULTS) {
		$out{$key} = $row->{$key} if defined $row->{$key};
	}
	return \%out;
}

# Subs linked to the client player, with their settings.
# [playerid, ["bluetooth","sub","settings"]]
sub _cmdSubSettings {
	my $request = shift;
	my $client = $request->client;
	if (!$client) {
		$request->setStatusBadParams();
		return;
	}
	my $player_id = lc $client->id;
	my $state = state();
	my %mine = map { lc($_->{device_id} || '') => 1 }
		grep { lc($_->{player_id} || '') eq $player_id } @{ $state->{links} || [] };
	my $i = 0;
	for my $device (@{ $state->{devices} || [] }) {
		next unless ($device->{role} || '') eq 'subwoofer';
		next unless $mine{ lc($device->{id} || '') };
		my $settings = sub_settings_for($device->{id});
		my $live;
		if (_is_anthem_sub($device)) {
			$live = _sub_live_for($device);
			_merge_sub_read($device->{id}, $settings, $live);
		}
		my $missing = ($live && ref $live->{missing} eq 'ARRAY') ? $live->{missing} : [];
		my $complete = ($live && $live->{ok} && $live->{complete} && !@$missing) ? 1 : 0;
		$request->addResultLoop('sub_loop', $i, 'id', $device->{id});
		$request->addResultLoop('sub_loop', $i, 'name', $device->{name} || $device->{id});
		for my $key (qw(mode level phase polarity lowpass)) {
			my $value = $settings->{$key};
			$value = $value + 0 if $SUB_FIELDS{$key}{kind} eq 'int';
			$request->addResultLoop('sub_loop', $i, $key, $value);
		}
		$request->addResultLoop('sub_loop', $i, 'sent', 0);
		$request->addResultLoop('sub_loop', $i, 'live', $complete);
		$request->addResultLoop('sub_loop', $i, 'source', $complete ? 'live' : 'stored');
		$request->addResultLoop('sub_loop', $i, 'settings_readable', $complete);
		if ($live && $live->{ok}) {
			$request->addResultLoop('sub_loop', $i, 'connected', 1);
			$request->addResultLoop('sub_loop', $i, 'model', $live->{model}) if $live->{model};
			$request->addResultLoop('sub_loop', $i, 'sku', $live->{sku}) if $live->{sku};
			$request->addResultLoop('sub_loop', $i, 'manufacturer', $live->{manufacturer}) if $live->{manufacturer};
			$request->addResultLoop('sub_loop', $i, 'gap_name', $live->{gap_name}) if $live->{gap_name};
			$request->addResultLoop('sub_loop', $i, 'connect_s', $live->{connect_s} + 0) if defined $live->{connect_s};
			$request->addResultLoop('sub_loop', $i, 'bridge', 'pi-ble');
		} else {
			$request->addResultLoop('sub_loop', $i, 'connected', ($live && $live->{connected}) ? 1 : 0);
			$request->addResultLoop('sub_loop', $i, 'bridge', 'pi-ble');
			$request->addResultLoop('sub_loop', $i, 'bridge_error', $live->{error}) if $live && $live->{error};
		}
		$i++;
	}
	$request->addResult('count', $i);
	$request->addResult('ranges', {
		level   => { min => $SUB_FIELDS{level}{min},   max => $SUB_FIELDS{level}{max} },
		phase   => { min => $SUB_FIELDS{phase}{min},   max => $SUB_FIELDS{phase}{max} },
		lowpass => { min => $SUB_FIELDS{lowpass}{min}, max => $SUB_FIELDS{lowpass}{max} },
		mode     => [qw(music movie night)],
		polarity => [qw(normal inverted)],
	});
	$request->setStatusDone();
}

# Run the Pi BLE helper (python3.11 + bleak) with a JSON reply.
sub _sub_ble_bin {
	my $pm = $INC{'Plugins/Bluetooth/Plugin.pm'} || '';
	$pm =~ s/Plugin\.pm$/sub-ble.py/;
	return $pm;
}

# Copy the keys the sub actually answered. A partial read does not replace the missing ones.
sub _merge_sub_read {
	my ($device_id, $settings, $live) = @_;
	return unless $live && $live->{ok} && ref $live->{settings} eq 'HASH';
	my $got = $live->{settings};
	my $stored = $prefs->get('sub_settings') || {};
	$stored = {} unless ref $stored eq 'HASH';
	my $row = $stored->{$device_id} || {};
	$row = {} unless ref $row eq 'HASH';
	my $changed = 0;
	for my $key (qw(mode level phase polarity lowpass)) {
		next unless exists $got->{$key};
		my $value = _accept_setting($key, $got->{$key});
		next unless defined $value;
		$row->{$key} = $value;
		$settings->{$key} = $value;
		$changed = 1;
	}
	if ($changed) {
		$stored->{$device_id} = $row;
		$prefs->set('sub_settings', $stored);
	}
}

use constant SUB_CACHE_SECS => 180;

my $write_timer = {};
my %write_pending;

sub _ble_tag {
	my ($cmd, $mac, $setting) = @_;
	$setting = '' unless defined $setting;
	my $tag = join('-', $cmd, uc($mac || ''), $setting);
	$tag =~ s/[^0-9A-Za-z._-]/_/g;
	return $tag;
}

sub _ble_paths {
	my ($cmd, $mac, $setting) = @_;
	my $base = '/tmp/lyrion-sub-ble-' . _ble_tag($cmd, $mac, $setting);
	return ($base . '.json', $base . '.json.next');
}

sub _ble_file_age {
	my ($path) = @_;
	return undef unless $path && -f $path;
	return time() - (stat $path)[9];
}

sub _read_ble_json {
	my ($path) = @_;
	return unless $path && -f $path;
	open my $fh, '<', $path or return;
	local $/;
	my $out = <$fh> // '';
	close $fh;
	$out =~ s/^\s+|\s+$//g;
	return if $out eq '';
	my $json = eval { decode_json($out) };
	if (!$json && $out =~ /({.*})/s) {
		$json = eval { decode_json($1) };
	}
	return $json if ref $json eq 'HASH';
	return;
}

# Start the helper and return at once. The JSON lands in a file.
sub _spawn_ble {
	my ($cmd, $mac, $setting, $value) = @_;
	my $bin = _sub_ble_bin();
	return 0 if !$bin || !-f $bin;
	my ($dest, $next) = _ble_paths($cmd, $mac, $setting);
	my $pending = _ble_file_age($next);
	return 0 if defined $pending && $pending < 45;
	my $timeout = ($cmd eq 'read' || $cmd eq 'write') ? 40 : 22;
	my $args = $cmd . ' ' . $mac;
	if ($cmd eq 'write') {
		$args .= ' ' . $setting . ' ' . $value;
		unlink $dest;
	}
	unlink $next;
	system(qq{setsid sh -c '/usr/bin/timeout $timeout /usr/local/bin/python3.11 "$bin" $args > "$next" 2>>/tmp/lyrion-sub-ble-spawn.log; mv -f "$next" "$dest"' </dev/null >/dev/null 2>&1 &});
	$log->info("sub ble async cmd=$cmd mac=$mac");
	return 1;
}

# Never waits. A fresh file is returned; otherwise a read is started beside Lyrion.
sub _sub_ble_cmd {
	my ($cmd, $mac, $setting, $value) = @_;
	$mac = uc($mac || '');
	$mac =~ s/[^0-9A-F:]//g;
	return { ok => 0, error => 'missing_mac' } if $mac eq '';
	my $bin = _sub_ble_bin();
	if (!$bin || !-f $bin) {
		return { ok => 0, error => 'missing_helper' };
	}
	$cmd =~ s/[^a-z]//g;
	return { ok => 0, error => 'unknown_cmd' } if $cmd !~ /^(hold|release|status|read|write)$/;
	$setting = '' unless defined $setting;
	$value = '' unless defined $value;
	if ($cmd eq 'write') {
		$setting =~ s/[^a-z]//g;
		$value =~ s/^\s+|\s+$//g;
		return { ok => 0, error => 'bad_setting' } if $setting eq '' || ($value !~ /^-?\d+$/ && $value !~ /^[a-z]+$/);
	}
	my ($dest, $next) = _ble_paths($cmd, $mac, $setting);
	if ($cmd eq 'write') {
		_spawn_ble($cmd, $mac, $setting, $value);
		return { ok => 0, pending => 1, error => 'pending' };
	}
	my $have = _read_ble_json($dest);
	my $age = _ble_file_age($dest);
	my $inflight = _ble_file_age($next);
	if (defined $age && $age < SUB_CACHE_SECS && $have && $have->{ok}) {
		return $have;
	}
	if (!defined $inflight || $inflight >= 45) {
		_spawn_ble($cmd, $mac, $setting, $value);
	}
	return $have if $have && $have->{ok};
	return { ok => 0, pending => 1, error => 'pending' };
}

sub _arm_write_harvest {
	my ($device_id, $mac, $setting) = @_;
	return unless $device_id && $mac && $setting;
	$write_pending{"$device_id|$setting"} = {
		device_id => $device_id,
		mac       => uc($mac),
		setting   => $setting,
		started   => time(),
	};
	Slim::Utils::Timers::killTimers($write_timer, \&_harvest_writes);
	Slim::Utils::Timers::setTimer($write_timer, time() + 2, \&_harvest_writes);
}

# Store a sub value only after the helper file echoes it. This timer does not read BLE.
sub _harvest_writes {
	my $again = 0;
	for my $key (keys %write_pending) {
		my $job = $write_pending{$key} || next;
		my ($dest) = _ble_paths('write', $job->{mac}, $job->{setting});
		my $mtime = -f $dest ? (stat $dest)[9] : 0;
		if ($mtime && $mtime >= $job->{started}) {
			delete $write_pending{$key};
			my $live = _read_ble_json($dest);
			my $confirmed = ($live && $live->{ok}) ? _accept_setting($job->{setting}, $live->{value}) : undef;
			if (defined $confirmed) {
				_store_sub_setting($job->{device_id}, $job->{setting}, $confirmed);
				_cache_sub_value($job->{mac}, $job->{setting}, $confirmed);
				$log->info('sub wrote name=' . $job->{device_id} . ' setting=' . $job->{setting} . ' value=' . $confirmed);
			} else {
				$log->warn('sub write failed name=' . $job->{device_id} . ' setting=' . $job->{setting} . ' error=' . (($live && $live->{error}) || 'no_readback'));
			}
			next;
		}
		if (time() - $job->{started} > 45) {
			delete $write_pending{$key};
			$log->warn('sub write failed name=' . $job->{device_id} . ' setting=' . $job->{setting} . ' error=timeout');
			next;
		}
		$again = 1;
	}
	Slim::Utils::Timers::setTimer($write_timer, time() + 2, \&_harvest_writes) if $again;
}

sub _sub_ble_hold {
	my ($mac) = @_;
	return _sub_ble_cmd('hold', $mac);
}

sub _sub_ble_release {
	my ($mac) = @_;
	return _sub_ble_cmd('release', $mac);
}

# Close the Pi BLE session to every known sub. Menu dismiss uses this.
# ["bluetooth","sub","close"]
sub _cmdSubClose {
	my $request = shift;
	my $state = state();
	my $n = 0;
	for my $device (@{ $state->{devices} || [] }) {
		next unless ($device->{role} || '') eq 'subwoofer';
		_sub_ble_release($device->{address} || $device->{id});
		$n++;
	}
	$request->addResult('ok', 1);
	$request->addResult('count', $n);
	$request->setStatusDone();
}

# ["bluetooth","sub","set",<id>,<setting>,<value>]
sub _cmdSubSet {
	my $request = shift;
	my $id = $request->getParam('_id');
	my $setting = $request->getParam('_setting');
	my $value = $request->getParam('_value');
	if (!defined $id || $id eq '' || !defined $setting || $setting eq '' || !defined $value) {
		$request->setStatusBadParams();
		return;
	}
	my $device = _device_by_id(state(), $id);
	if (!$device || ($device->{role} || '') ne 'subwoofer') {
		$request->addResult('ok', 0);
		$request->addResult('error', 'unknown_device');
		$request->setStatusDone();
		return;
	}
	my $result = apply_sub_setting({ device => $device->{id}, setting => $setting, value => $value });
	$request->addResult('ok', $result->{ok} ? 1 : 0);
	$request->addResult('sent', $result->{sent} ? 1 : 0);
	$request->addResult('error', $result->{error}) if $result->{error};
	if ($result->{ok}) {
		my $settings = sub_settings_for($device->{id});
		_cache_sub_value($device->{address} || $device->{id}, $setting, $settings->{$setting});
		$request->addResult('value', $settings->{$setting});
	}
	$request->setStatusDone();
}

sub _menu {
	my $request = shift;
	$request->setStatusProcessing();
	my $view = Plugins::Bluetooth::Registry::view(state());
	my $i = 0;
	if (!@{ $view->{devices} }) {
		$request->addResultLoop('item_loop', 0, 'text', Slim::Utils::Strings::string('PLUGIN_BLUETOOTH_EMPTY'));
		$request->addResult('count', 1);
		$request->setStatusDone();
		return;
	}
	for my $row (@{ $view->{devices} }) {
		my @mine = grep { $_->{device_id} eq $row->{id} } @{ $view->{links} };
		my $player = @mine ? $mine[0]{player_id} : Slim::Utils::Strings::string('PLUGIN_BLUETOOTH_UNLINKED');
		my $text = $row->{name} . ' — ' . $player;
		if (@mine && defined $mine[0]{delay_ms}) {
			$text .= ' — ' . $mine[0]{drift_ms} . ' ms';
		}
		$request->addResultLoop('item_loop', $i, 'text', $text);
		$i++;
	}
	$request->addResult('count', $i);
	$request->setStatusDone();
}

sub error_text {
	my ($error) = @_;
	return _notice($error);
}

sub _trace {
	my ($action, $result) = @_;
	my $device = $result->{device} || {};
	my $link = $result->{link} || {};
	my $bridge = $result->{bridge} || {};
	$log->info(join(' ',
		"action=$action",
		'id=' . ($device->{id} || $link->{device_id} || $bridge->{id} || ''),
		'name=' . ($device->{name} || $bridge->{name} || ''),
		'role=' . ($device->{role} || ''),
		'address=' . ($device->{address} || ''),
		'profile=' . ($device->{profile} || ''),
		'bridge=' . ($device->{bridge_id} || $bridge->{id} || ''),
		'host=' . ($bridge->{host} || ''),
		'port=' . ($bridge->{port} || ''),
		'player=' . ($link->{player_id} || ''),
		'drift=' . (defined $link->{drift_ms} ? $link->{drift_ms} : ''),
		'sync=' . ($device->{bridge_sync} || ''),
	));
}

my $scan_timer = {};
my $link_watch = {};
my $scan_until = 0;
my %sub_cache;

use constant SCAN_IDLE_SECS => 25;
use constant SCAN_EVERY_SECS => 8;
use constant LINK_EVERY_SECS => 180;

# The Fire TV capture uses the same adapter. While it plays, nothing else may scan or connect.
sub _bluetooth_input_playing {
	return 0 unless Slim::Player::Client->can('clients');
	for my $client (Slim::Player::Client::clients()) {
		next unless $client;
		my $mode = eval { Slim::Player::Source::playmode($client) } || '';
		next unless $mode eq 'play';
		my $url = '';
		my $song = eval { $client->playingSong() };
		if ($song && $song->can('currentTrack')) {
			my $track = $song->currentTrack();
			$url = $track->url if $track && $track->can('url');
		}
		return 1 if defined $url && $url =~ /^(?:btin|wavin):/i;
	}
	return 0;
}

# The Material dialog polls bluetooth page every 8 s while its list is open, and stops when it closes.
sub _note_bluetooth_menu {
	return if _bluetooth_input_playing();
	my $continue = $scan_until && time() < $scan_until;
	$scan_until = time() + SCAN_IDLE_SECS;
	launch_paired();
	return if $continue;
	Slim::Utils::Timers::killTimers($scan_timer, \&_scan_tick);
	Slim::Utils::Timers::setTimer($scan_timer, time() + 1, \&_scan_tick);
	$log->info('bluetooth menu scan armed');
}

sub _scan_tick {
	if (!$scan_until || time() >= $scan_until || _bluetooth_input_playing()) {
		_stop_le_scan();
		$log->info('bluetooth menu scan stopped');
		return;
	}
	launch_scan();
	Slim::Utils::Timers::setTimer($scan_timer, time() + SCAN_EVERY_SECS, \&_scan_tick);
}

sub _stop_le_scan {
	$scan_until = 0;
	Slim::Utils::Timers::killTimers($scan_timer, \&_scan_tick);
	return unless opendir(my $dh, '/proc');
	while (my $pid = readdir $dh) {
		next unless $pid =~ /^\d+$/ && $pid > 1;
		open my $fh, '<', "/proc/$pid/cmdline" or next;
		local $/;
		my $cmd = <$fh> // '';
		close $fh;
		next unless $cmd =~ /lyrion-bt-scan\.next/;
		kill 'TERM', -$pid;
		kill 'TERM', $pid;
	}
	closedir $dh;
}

my $meta_watch = {};
my $meta_raw = '';

sub _meta_bin {
	my $path = $INC{'Plugins/Bluetooth/Plugin.pm'} || '';
	$path =~ s/Plugin\.pm$/bt-meta.py/;
	return $path;
}

sub _read_pid {
	my ($path) = @_;
	open my $fh, '<', $path or return 0;
	my $pid = <$fh> // '';
	close $fh;
	return ($pid =~ /(\d+)/) ? $1 : 0;
}

sub _pid_alive {
	my ($pid) = @_;
	return $pid && kill(0, $pid) ? 1 : 0;
}

sub _start_meta_watcher {
	my $bin = _meta_bin();
	return unless $bin && -f $bin;
	my $pid = _read_pid('/tmp/lyrion-bt-meta.pid');
	return if _pid_alive($pid);
	system(qq{setsid "$bin" </dev/null >>/tmp/lyrion-bt-meta.log 2>&1 &});
	$log->info('meta watcher started');
}

sub _stop_meta_watcher {
	my $pid = _read_pid('/tmp/lyrion-bt-meta.pid');
	return unless $pid;
	kill 'TERM', $pid;
}

sub _arm_meta_poll {
	Slim::Utils::Timers::killTimers($meta_watch, \&_meta_poll);
	Slim::Utils::Timers::setTimer($meta_watch, time() + 1, \&_meta_poll);
}

# Copy the latest AVRCP track onto every player that is on that Bluetooth input.
# A missing or empty title leaves the current name in place.
sub _meta_poll {
	_arm_meta_poll();
	my $path = '/tmp/lyrion-bt-meta.json';
	return unless -f $path;
	open my $fh, '<:utf8', $path or return;
	local $/;
	my $raw = <$fh> // '';
	close $fh;
	return if $raw eq $meta_raw;
	$meta_raw = $raw;
	my $data = eval { decode_json($raw || '') };
	return unless ref $data eq 'HASH';
	return unless Slim::Player::Client->can('clients');
	for my $client (Slim::Player::Client::clients()) {
		next unless $client;
		my $url = _playlist_url($client);
		my $mac = uc(_bluealsa_mac_from_url($url) || '');
		next unless $mac && ref $data->{$mac} eq 'HASH';
		my $row = $data->{$mac};
		my $duration = int(($row->{duration_ms} || 0) / 1000);
		my $changed = Plugins::Bluetooth::BTIN->remember($mac, {
			title    => $row->{title} || '',
			artist   => $row->{artist} || '',
			album    => $row->{album} || '',
			duration => $duration,
		});
		my $master = eval { $client->master } || $client;
		my $song = eval { $master->playingSong } || eval { $master->streamingSong };
		# Displayed time is startOffset plus elapsed. Move only the displayed
		# position. The Bluetooth audio itself is not seeked.
		_align_position($master, $song, $row->{position_ms});
		_apply_volume($client, $mac, $row->{volume});
		next unless $changed;
		eval { Slim::Music::Info::setCurrentTitle($url, $row->{title}, $master) };
		$song->duration($duration) if $song && $duration && eval { $song->can('duration') };
		eval { $master->currentPlaylistUpdateTime(Time::HiRes::time()) };
		Slim::Control::Request::notifyFromArray($master, ['newmetadata']);
		$log->info('meta title=' . ($row->{title} || '') . ' artist=' . ($row->{artist} || '') . ' player=' . ($master->id || ''));
	}
}

my %volume_sent;

sub _apply_volume {
	my ($master, $mac, $volume) = @_;
	return unless defined $volume && $volume =~ /^\d+$/ && $master && $mac;
	$volume = int($volume);
	return if $volume < 0 || $volume > 100;
	my $current = eval { $master->volume };
	return unless defined $current && abs($current - $volume) >= 2;
	$volume_sent{$mac} = [time(), $volume];
	eval { $master->execute(['mixer', 'volume', $volume]) };
}

sub _write_volume_want {
	my ($mac, $volume) = @_;
	my $raw = encode_json({ address => uc($mac), volume => int($volume) });
	my $next = '/tmp/lyrion-bt-volume-want.json.next';
	open my $fh, '>:utf8', $next or return;
	print $fh $raw;
	close $fh;
	rename $next, '/tmp/lyrion-bt-volume-want.json';
}

sub _onMixerVolume {
	my $request = shift;
	return unless $request && eval { $request->isCommand([['mixer'], ['volume']]) };
	my $client = $request->client || return;
	my $url = _playlist_url($client);
	my $mac = uc(_bluealsa_mac_from_url($url) || '');
	return unless $mac;
	my $volume = $request->getParam('_newvalue');
	$volume = eval { $client->volume } unless defined $volume && $volume =~ /^\d+$/;
	return unless defined $volume && $volume =~ /^\d+$/;
	my $sent = $volume_sent{$mac};
	return if $sent && abs($sent->[1] - $volume) < 2 && time() - $sent->[0] < 3;
	_write_volume_want($mac, int($volume));
}

sub _align_position {
	my ($master, $song, $position_ms) = @_;
	return unless $song && defined $position_ms && $position_ms =~ /^\d+$/;
	my $position = int($position_ms / 1000);
	return if $position <= 0;
	return unless eval { $song->can('startOffset') } && eval { $master->can('songElapsedSeconds') };
	my $elapsed = $master->songElapsedSeconds || 0;
	my $shown = ($song->startOffset || 0) + $elapsed;
	return if abs($shown - $position) <= 2;
	$song->startOffset($position - $elapsed);
}

sub _arm_link_watch {
	Slim::Utils::Timers::killTimers($link_watch, \&_link_watch);
	Slim::Utils::Timers::setTimer($link_watch, time() + LINK_EVERY_SECS, \&_link_watch);
}

# Connection only, in another process. No LE scan and no wait on this thread.
sub _link_watch {
	_arm_link_watch();
	return if _bluetooth_input_playing();
	return if $scan_until && time() < $scan_until;
	my $state = state();
	for my $device (@{ $state->{devices} || [] }) {
		next unless $device && ($device->{role} || '') eq 'subwoofer';
		next unless _is_anthem_sub($device);
		my $mac = uc($device->{address} || $device->{id} || '');
		next unless $mac =~ /^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$/;
		my $next = "/tmp/lyrion-sub-link-$mac.next";
		my $age = -f $next ? time() - (stat $next)[9] : undef;
		next if defined $age && $age < 30;
		system(qq{setsid sh -c 'bluetoothctl --timeout 2 info $mac > "$next" 2>/dev/null; mv -f "$next" "/tmp/lyrion-sub-link-$mac.txt"' </dev/null >/dev/null 2>&1 &});
		$log->info("sub link check mac=$mac");
	}
}

# Full GATT read when the sub menu opens and the last answer is older than a few minutes.
# While the Bluetooth input plays, return the remembered answer and do not touch the adapter.
sub _sub_live_for {
	my ($device) = @_;
	my $mac = uc($device->{address} || $device->{id} || '');
	my $slot = $sub_cache{$mac};
	my $fresh = $slot && ref $slot->{live} eq 'HASH' && (time() - $slot->{at}) < SUB_CACHE_SECS;
	if ($fresh) {
		$log->info('sub cache hit mac=' . $mac . ' age=' . (time() - $slot->{at}));
		return $slot->{live};
	}
	if (_bluetooth_input_playing()) {
		$log->info("sub read skipped, bluetooth input playing mac=$mac");
		return ($slot && ref $slot->{live} eq 'HASH') ? $slot->{live} : undef;
	}
	my $live = _sub_ble_cmd('read', $mac);
	if ($live && $live->{ok}) {
		$sub_cache{$mac} = { at => time(), live => $live };
		return $live;
	}
	# A read may still be running in the helper. Keep the last answer on screen.
	return ($slot && ref $slot->{live} eq 'HASH') ? $slot->{live} : undef;
}

sub _cache_sub_value {
	my ($mac, $setting, $value) = @_;
	$mac = uc($mac || '');
	my $slot = $sub_cache{$mac};
	return unless $slot && ref $slot->{live} eq 'HASH';
	$slot->{live}{settings} = {} unless ref $slot->{live}{settings} eq 'HASH';
	$slot->{live}{settings}{$setting} = $value;
	$slot->{at} = time();
}

sub _scan_age {
	my $path = '/tmp/lyrion-bt-scan.txt';
	return undef unless -f $path;
	return time - (stat $path)[9];
}

sub launch_scan {
	return 0 if _bluetooth_input_playing();
	my $next = '/tmp/lyrion-bt-scan.next';
	if (-f $next) {
		my $pending = time - (stat $next)[9];
		return 0 if $pending < 15;
	}
	my $age = _scan_age();
	return 0 if defined $age && $age < 12;
	# The finished scan stays readable. A new pass lands beside it and replaces it only if a device was seen.
	system(q{setsid sh -c 'bluetoothctl --timeout 8 scan le > /tmp/lyrion-bt-scan.next 2>&1; grep -q "Device " /tmp/lyrion-bt-scan.next && mv -f /tmp/lyrion-bt-scan.next /tmp/lyrion-bt-scan.txt' </dev/null >/dev/null 2>&1 &});
	$log->info('scan le started');
	return 1;
}

sub refresh_subs {
	my $text = '';
	if (open my $fh, '<', '/tmp/lyrion-bt-scan.txt') {
		local $/;
		$text = <$fh> // '';
		close $fh;
	}
	my $rows = Plugins::Bluetooth::Registry::rows_from_scan($text);
	my $state = state();
	my %have;
	for my $device (@{ $state->{devices} || [] }) {
		$have{uc $device->{address}} = 1 if $device->{address};
		$have{uc $device->{id}} = 1 if $device->{id};
	}
	my %named = map { $_->{address} => 1 } grep { ($_->{role} || '') eq 'subwoofer' } @$rows;
	# bluetoothctl info runs in another process. Skip it while the Salon input owns the adapter.
	if (!_bluetooth_input_playing()) {
		my $lookups = 0;
		for my $mac (@{ Plugins::Bluetooth::Registry::macs_from_scan($text) }) {
			next if $named{$mac} || $have{$mac};
			next unless $mac =~ /^(?:60:EF:AB|08:EB:ED)/;
			last if ++$lookups > 2;
			my $ident = _sub_identity($mac);
			if ($ident) {
				push @$rows, $ident;
			} elsif (!$seen_logged{"miss:$mac"}) {
				$seen_logged{"miss:$mac"} = 1;
				$log->info("sub unnamed address=$mac");
			}
		}
	}
	my $added = Plugins::Bluetooth::Registry::adopt_subs($state, $rows);
	if (@$added) {
		commit($state);
		for my $row (@$added) {
			$log->info("sub name=$row->{name} raw=$row->{raw} address=$row->{address} profile=$row->{profile}");
		}
	}
	refresh_paired();
	return scalar @$added;
}

sub refresh_paired {
	my $text = '';
	if (open my $fh, '<', '/tmp/lyrion-bt-paired.txt') {
		local $/;
		$text = <$fh> // '';
		close $fh;
	}
	# Never call bluetoothctl here. A stale file just means the next menu open refreshes it.
	return 0 if $text !~ /Device [0-9A-Fa-f:]{17}/;
	my $rows = Plugins::Bluetooth::Registry::rows_from_paired($text);
	my $state = state();
	my $added = Plugins::Bluetooth::Registry::adopt_paired($state, $rows);
	if (@$added) {
		commit($state);
		for my $row (@$added) {
			$log->info("paired name=$row->{name} role=$row->{role} address=$row->{address} profile=$row->{profile}");
		}
	}
	return scalar @$added;
}

sub launch_paired {
	return 0 if _bluetooth_input_playing();
	my $path = '/tmp/lyrion-bt-paired.txt';
	my $age = -f $path ? time - (stat $path)[9] : undef;
	return 0 if defined $age && $age < 15;
	system(q{setsid sh -c 'bluetoothctl --timeout 2 devices Paired > /tmp/lyrion-bt-paired.next 2>&1; grep -q "Device " /tmp/lyrion-bt-paired.next && mv -f /tmp/lyrion-bt-paired.next /tmp/lyrion-bt-paired.txt' </dev/null >/dev/null 2>&1 &});
	return 1;
}

# bluetoothctl info reads the BlueZ cache. It runs beside Lyrion; this thread only reads the file.
sub _sub_identity {
	my ($mac) = @_;
	return unless $mac && $mac =~ /^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$/;
	my $dest = "/tmp/lyrion-bt-ident-$mac.txt";
	my $next = $dest . '.next';
	my $age = -f $dest ? time() - (stat $dest)[9] : undef;
	my $pending = -f $next ? time() - (stat $next)[9] : undef;
	if ((!defined $age || $age > 120) && (!defined $pending || $pending > 20)) {
		system(qq{setsid sh -c 'bluetoothctl --timeout 3 info $mac > "$next" 2>/dev/null; mv -f "$next" "$dest"' </dev/null >/dev/null 2>&1 &});
	}
	return _identity_from_file($mac, $dest);
}

sub _identity_from_file {
	my ($mac, $path) = @_;
	open my $fh, '<', $path or return;
	local $/;
	my $out = <$fh> // '';
	close $fh;
	return unless $out =~ /^\s*Name:\s*(.+)$/m;
	my $raw = $1;
	$raw =~ s/\s+$//;
	my $sub = $raw =~ /svs/i || $out =~ /1fee6acf-a826-4e37-9635-4d8a01642c5d/i;
	my $anthem = $out =~ /5461b27b-e747-4867-bb63-6d0397e5fb57/i || $raw =~ /dynamo|abyss|defiance|^s23/i;
	return unless $sub || $anthem;
	my $name = $raw;
	$name = $1 if $raw =~ /\|([^|]+)$/;
	$name =~ s/^\s+|\s+$//g;
	return {
		id      => $mac,
		name    => $name || $raw,
		raw     => $raw,
		role    => 'subwoofer',
		profile => $sub ? 'svs' : 'anthem-sub',
		address => $mac,
	};
}

sub found {
	my ($state) = @_;
	my %have;
	for my $device (@{ $state->{devices} || [] }) {
		$have{uc($device->{address})} = 1 if $device->{address};
		$have{uc($device->{id})} = 1 if $device->{id};
	}
	open my $fh, '<', '/tmp/lyrion-bt-scan.txt' or return [];
	local $/;
	my $text = <$fh> // '';
	close $fh;
	my @rows;
	for my $row (@{ Plugins::Bluetooth::Registry::rows_from_scan($text) }) {
		next if $row->{role} eq 'subwoofer';
		next if ($row->{raw} || '') =~ /^[0-9A-F]{2}(?:-[0-9A-F]{2}){5}$/i;
		next if $have{$row->{address}} || $have{$row->{id}};
		unless ($seen_logged{$row->{address}}) {
			$seen_logged{$row->{address}} = 1;
			$log->info("seen address=$row->{address} name=$row->{raw} role=" . ($row->{role} || 'unknown'));
		}
		push @rows, {
			id   => $row->{id},
			name => $row->{name},
			role => $row->{role},
		};
	}
	return \@rows;
}

sub _device_mac {
	my ($state, $id) = @_;
	$state ||= eval { state() };
	return unless $id;
	if ($state) {
		my $device = _device_by_id($state, $id);
		if ($device) {
			my $addr = $device->{address} || $device->{id} || '';
			return $addr if $addr;
		}
	}
	return $id if $id =~ /^[0-9A-Fa-f:]{17}$/;
	return;
}

sub _bluealsa_mac_from_url {
	my ($url) = @_;
	return unless defined $url && $url ne '';
	return $1 if $url =~ /bluealsa:DEV=([^,;\s]+)/i;
	return;
}

sub _playlist_url {
	my ($client) = @_;
	return '' unless $client;
	my $url = eval { Slim::Player::Playlist::url($client) } || '';
	if (!$url) {
		my $song = eval { $client->playingSong };
		if ($song) {
			$url = eval { $song->currentTrack()->url } || eval { $song->track()->url } || '';
		}
	}
	return $url || '';
}

sub _bluealsa_mac_in_use {
	my ($want) = @_;
	return 0 unless Slim::Player::Client->can('clients');
	for my $c (Slim::Player::Client::clients()) {
		next unless $c;
		next unless eval { $c->isPlaying };
		my $mac = _bluealsa_mac_from_url(_playlist_url($c));
		next unless $mac;
		return 1 if !$want || uc($mac) eq uc($want);
	}
	return 0;
}

sub _mac_in_cmdline {
	my ($cmd, $mac) = @_;
	return 1 unless $mac;
	my $hex = uc($mac);
	$hex =~ s/[^0-9A-F]//g;
	return 0 unless $hex =~ /^[0-9A-F]{12}$/;
	my $colon = join(':', unpack('(A2)*', $hex));
	my $dash  = join('-', unpack('(A2)*', $hex));
	return $cmd =~ /\Q$colon\E/i || $cmd =~ /\Q$dash\E/i || $cmd =~ /\Q$hex\E/i;
}

sub _proc_cmdline {
	my ($pid) = @_;
	my $path = "/proc/$pid/cmdline";
	open(my $fh, '<', $path) or return;
	local $/;
	my $raw = <$fh> // '';
	close $fh;
	$raw =~ s/\0/ /g;
	$raw =~ s/\s+\z//;
	return $raw;
}

sub _arecord_bluealsa_pids {
	my ($mac) = @_;
	my @pids;
	if (opendir(my $dh, '/proc')) {
		while (my $pid = readdir($dh)) {
			next unless $pid =~ /^\d+$/;
			next if $pid <= 1;
			my $cmd = _proc_cmdline($pid) || next;
			next unless $cmd =~ /(?:^|[\/\s])arecord(?:\s|$)/;
			next unless $cmd =~ /bluealsa/i;
			next unless _mac_in_cmdline($cmd, $mac);
			push @pids, $pid;
		}
		closedir $dh;
	}
	return @pids;
}

# Kill leftover WaveInput arecord captures for a Bluetooth (bluealsa) device.
# Without a MAC, only processes whose command line contains both arecord and
# bluealsa are targeted — never a generic arecord, never pkill -f.
sub _reap_arecord {
	my ($mac) = @_;
	my @pids = _arecord_bluealsa_pids($mac);
	return 0 unless @pids;
	for my $pid (@pids) {
		$log->info("reaping arecord pid=$pid" . ($mac ? " mac=$mac" : ''));
		kill 'TERM', $pid;
	}
	select(undef, undef, undef, 0.25);
	for my $pid (_arecord_bluealsa_pids($mac)) {
		$log->info("arecord pid=$pid still alive, sending KILL");
		kill 'KILL', $pid;
	}
	return 1;
}

sub _reap_arecord_timer {
	my ($client, $mac) = @_;
	if ($mac) {
		return if _bluealsa_mac_in_use($mac);
		_reap_arecord($mac);
		return;
	}
	return if _bluealsa_mac_in_use();
	_reap_arecord();
}

sub _onPlaylistEvent {
	my $request = shift;
	my $client = $request->client() || return;
	my $url = _playlist_url($client);
	my $mac = _bluealsa_mac_from_url($url);
	# After stop the current URL may already be empty. Fall back to the
	# last Bluetooth input this plugin started on that player.
	if (!$mac && $client) {
		my $active = $prefs->get('active_input') || {};
		my $id = ref $active eq 'HASH' ? $active->{lc $client->id} : undef;
		$mac = _device_mac(eval { state() }, $id) if $id;
		return if $mac && eval { $client->isPlaying };
	}
	Slim::Utils::Timers::killTimers($client, \&_reap_arecord_timer);
	Slim::Utils::Timers::setTimer($client, time() + 1, \&_reap_arecord_timer, $mac);
}

1;

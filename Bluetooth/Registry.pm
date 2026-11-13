package Plugins::Bluetooth::Registry;

use strict;
use warnings;
use utf8;

# LMS is the registry. A device points at one platine per link.
# Drift is the extra shift for that link. The bridge is not asked
# to play, pair, or write a subwoofer setting.

use constant BASE_LATENCY_MS => 200;
use constant MIN_BUFFER_MS   => 60;
use constant MAX_DELAY_MS    => 800;

my %ROLES = map { $_ => 1 } qw(input output remote subwoofer);

sub delay_ms {
	my ($drift) = @_;
	my $value = BASE_LATENCY_MS + int($drift || 0);
	$value = MIN_BUFFER_MS if $value < MIN_BUFFER_MS;
	$value = MAX_DELAY_MS if $value > MAX_DELAY_MS;
	return $value;
}

sub _clean_id {
	my ($id) = @_;
	return '' unless defined $id;
	$id =~ s/^\s+|\s+$//g;
	return '' if $id eq '' || $id =~ /\s/;
	return $id;
}

sub _index {
	my ($list, $key, $value) = @_;
	return undef unless $list && $value;
	for my $i (0 .. $#$list) {
		return $i if ($list->[$i]{$key} || '') eq $value;
	}
	return undef;
}

sub add_bridge {
	my ($state, $spec) = @_;
	my $id = _clean_id($spec->{id});
	my $host = $spec->{host} || '';
	$host =~ s/^\s+|\s+$//g;
	my $port = $spec->{port};
	$port = 8765 if !defined $port || $port eq '';
	return { ok => 0, error => 'bad_id' } unless $id;
	return { ok => 0, error => 'bad_host' } if $host eq '' || $host =~ /\s/;
	return { ok => 0, error => 'bad_port' } if $port !~ /^\d+$/ || $port < 1 || $port > 65535;

	my $bridges = $state->{bridges} ||= [];
	my $i = _index($bridges, 'id', $id);
	my $token = $spec->{token};
	if (defined $i) {
		my $row = $bridges->[$i];
		$row->{name} = $spec->{name} || $row->{name} || $id;
		$row->{host} = $host;
		$row->{port} = int($port);
		$row->{token} = $token if defined $token && $token ne '';
		return { ok => 1, bridge => _public_bridge($row) };
	}

	my $row = {
		id    => $id,
		name  => $spec->{name} || $id,
		host  => $host,
		port  => int($port),
		token => (defined $token ? $token : ''),
	};
	push @$bridges, $row;
	return { ok => 1, bridge => _public_bridge($row) };
}

sub remove_bridge {
	my ($state, $id) = @_;
	$id = _clean_id($id);
	my $bridges = $state->{bridges} || [];
	my $i = _index($bridges, 'id', $id);
	return { ok => 0, error => 'unknown_bridge' } unless defined $i;
	for my $device (@{ $state->{devices} || [] }) {
		return { ok => 0, error => 'bridge_in_use' } if ($device->{bridge_id} || '') eq $id;
	}
	splice @$bridges, $i, 1;
	return { ok => 1 };
}

sub add_device {
	my ($state, $spec) = @_;
	my $id = _clean_id($spec->{id});
	my $role = lc($spec->{role} || '');
	return { ok => 0, error => 'bad_id' } unless $id;
	return { ok => 0, error => 'bad_role' } unless $ROLES{$role};

	my $bridge_id = _clean_id($spec->{bridge_id});
	if ($bridge_id) {
		return { ok => 0, error => 'unknown_bridge' }
			unless defined _index($state->{bridges} || [], 'id', $bridge_id);
	}

	my $devices = $state->{devices} ||= [];
	return { ok => 0, error => 'duplicate_device' } if defined _index($devices, 'id', $id);

	my $address = $spec->{address} || '';
	$address =~ s/^\s+|\s+$//g;
	$address = uc $address if $address =~ /^[0-9a-f:]+$/i;

	my $sync = 'local';
	if ($bridge_id) {
		my $b = _index($state->{bridges} || [], 'id', $bridge_id);
		my $token = $state->{bridges}[$b]{token} || '';
		$sync = 'pending' if length $token;
	}

	my $device = {
		id          => $id,
		name        => ($spec->{name} || $id),
		role        => $role,
		address     => $address,
		profile     => ($spec->{profile} || ''),
		bridge_id   => $bridge_id,
		bridge_sync => $sync,
	};
	push @$devices, $device;
	return { ok => 1, device => { %$device } };
}

sub remove_device {
	my ($state, $id) = @_;
	$id = _clean_id($id);
	my $devices = $state->{devices} || [];
	my $i = _index($devices, 'id', $id);
	return { ok => 0, error => 'unknown_device' } unless defined $i;
	my $device = $devices->[$i];
	splice @$devices, $i, 1;
	my $links = $state->{links} || [];
	@$links = grep { ($_->{device_id} || '') ne $id } @$links;
	$state->{links} = $links;
	return { ok => 1, device => { %$device } };
}

sub attach {
	my ($state, $spec) = @_;
	my $device_id = _clean_id($spec->{device_id});
	my $player_id = $spec->{player_id} || '';
	$player_id =~ s/^\s+|\s+$//g;
	$player_id = lc $player_id if $player_id =~ /^[0-9a-f:]+$/i;
	return { ok => 0, error => 'unknown_device' }
		unless defined _index($state->{devices} || [], 'id', $device_id);
	return { ok => 0, error => 'bad_player' } if $player_id eq '';

	my $drift = _drift($spec->{drift_ms});
	return $drift unless $drift->{ok};

	my $links = $state->{links} ||= [];
	for my $link (@$links) {
		if ($link->{device_id} eq $device_id && $link->{player_id} eq $player_id) {
			$link->{drift_ms} = $drift->{value};
			return { ok => 1, link => { %$link } };
		}
	}
	my $link = {
		device_id => $device_id,
		player_id => $player_id,
		drift_ms  => $drift->{value},
	};
	push @$links, $link;
	return { ok => 1, link => { %$link } };
}

sub detach {
	my ($state, $device_id, $player_id) = @_;
	$device_id = _clean_id($device_id);
	$player_id = lc($player_id || '');
	$player_id =~ s/^\s+|\s+$//g;
	my $links = $state->{links} || [];
	my $kept = [];
	my $found = 0;
	for my $link (@$links) {
		if ($link->{device_id} eq $device_id && lc($link->{player_id}) eq $player_id) {
			$found = 1;
			next;
		}
		push @$kept, $link;
	}
	return { ok => 0, error => 'unknown_link' } unless $found;
	$state->{links} = $kept;
	return { ok => 1 };
}

sub set_drift {
	my ($state, $device_id, $player_id, $drift_ms) = @_;
	$device_id = _clean_id($device_id);
	$player_id = lc($player_id || '');
	$player_id =~ s/^\s+|\s+$//g;
	my $drift = _drift($drift_ms);
	return $drift unless $drift->{ok};
	for my $link (@{ $state->{links} || [] }) {
		if ($link->{device_id} eq $device_id && lc($link->{player_id}) eq $player_id) {
			$link->{drift_ms} = $drift->{value};
			return { ok => 1, link => { %$link } };
		}
	}
	return { ok => 0, error => 'unknown_link' };
}

sub mark_sync {
	my ($state, $device_id, $sync) = @_;
	my $i = _index($state->{devices} || [], 'id', $device_id);
	return unless defined $i;
	$state->{devices}[$i]{bridge_sync} = $sync;
}

sub _drift {
	my ($value) = @_;
	$value = 0 if !defined $value || $value eq '';
	return { ok => 0, error => 'bad_drift' } unless $value =~ /^-?\d+$/;
	return { ok => 0, error => 'bad_drift' } if $value < -5000 || $value > 5000;
	return { ok => 1, value => int($value) };
}

sub _public_bridge {
	my ($row) = @_;
	return {
		id        => $row->{id},
		name      => $row->{name},
		host      => $row->{host},
		port      => $row->{port},
		has_token => ($row->{token} && length $row->{token}) ? 1 : 0,
	};
}

sub _plain {
	my ($text) = @_;
	$text = '' unless defined $text;
	$text =~ s/\e\[[0-9;]*m//g;
	return $text;
}

sub macs_from_scan {
	my ($text) = @_;
	my %mac;
	my $plain = _plain($text);
	while ($plain =~ /\[(?:NEW|CHG)\] Device ([0-9A-Fa-f:]{17})/g) {
		$mac{uc $1} = 1;
	}
	return [sort keys %mac];
}

sub rows_from_scan {
	my ($text) = @_;
	my %seen;
	for my $line (split /\n/, _plain($text)) {
		next unless $line =~ /\[NEW\] Device ([0-9A-Fa-f:]{17})\s+(.+?)\s*$/;
		my ($mac, $raw) = (uc $1, $2);
		next if $raw eq '' || $raw =~ /AdvertisementMonitor/;
		my $role = role_from_name($raw) || '';
		my $name = $raw;
		$name = $1 if $raw =~ /\|([^|]+)$/;
		$name =~ s/^\s+|\s+$//g;
		my $profile = '';
		$profile = ($raw =~ /svs/i) ? 'svs' : 'anthem-sub' if $role eq 'subwoofer';
		$seen{$mac} = {
			id      => $mac,
			name    => $name || $raw,
			raw     => $raw,
			role    => $role,
			profile => $profile,
			address => $mac,
		};
	}
	return [sort { $a->{name} cmp $b->{name} } values %seen];
}

sub rows_from_paired {
	my ($text) = @_;
	my %seen;
	for my $line (split /\n/, _plain($text)) {
		next unless $line =~ /^Device ([0-9A-Fa-f:]{17})\s+(.+?)\s*$/;
		my ($mac, $raw) = (uc $1, $2);
		next if $raw =~ /^[0-9A-F]{2}(?:-[0-9A-F]{2}){5}$/;
		my $role = role_from_name($raw) || '';
		next unless $role;
		my $name = $raw;
		$name = $1 if $raw =~ /\|([^|]+)$/;
		$name =~ s/^\s+|\s+$//g;
		my $profile = '';
		if ($role eq 'subwoofer') {
			$profile = ($raw =~ /svs/i) ? 'svs' : 'anthem-sub';
		} elsif ($role eq 'input') {
			$profile = 'a2dp-input';
		} elsif ($role eq 'output') {
			$profile = 'a2dp-output';
		}
		$seen{$mac} = {
			id      => $mac,
			name    => $name || $raw,
			raw     => $raw,
			role    => $role,
			profile => $profile,
			address => $mac,
		};
	}
	return [sort { $a->{name} cmp $b->{name} } values %seen];
}

sub adopt_subs {
	my ($state, $rows) = @_;
	my @added;
	for my $row (@{ $rows || [] }) {
		next unless ($row->{role} || '') eq 'subwoofer';
		my $known = 0;
		for my $device (@{ $state->{devices} || [] }) {
			my $address = uc($device->{address} || '');
			my $id = uc($device->{id} || '');
			$known = 1 if $address eq $row->{address} || $id eq $row->{id};
		}
		next if $known;
		my $result = add_device($state, $row);
		push @added, $row if $result->{ok};
	}
	return \@added;
}

sub adopt_paired {
	my ($state, $rows) = @_;
	my @added;
	for my $row (@{ $rows || [] }) {
		next unless $row->{role};
		my $known = 0;
		for my $device (@{ $state->{devices} || [] }) {
			my $address = uc($device->{address} || '');
			my $id = uc($device->{id} || '');
			$known = 1 if $address eq $row->{address} || $id eq $row->{id};
		}
		next if $known;
		my $result = add_device($state, $row);
		push @added, $row if $result->{ok};
	}
	return \@added;
}

sub role_from_name {
	my ($name) = @_;
	my $folded = lc($name || '');
	return 'subwoofer' if $folded =~ /dynamo|abyss|defiance|^s23|\bsvs\b/;
	return 'input' if $folded =~ /fire\s?tv|firestick|apple tv|shield tv|chromecast/;
	return 'remote' if $folded =~ /remote|telecommande|télécommande/;
	return 'output' if $folded =~ /headphone|headset|airpod|buds|speaker|enceinte|soundbar|écouteur|ecouteur|haut-parleur/;
	return '';
}

sub cards {
	my ($state, $names) = @_;
	$names ||= {};
	my $view = view($state);
	my %card;
	my @order;
	for my $device (@{ $view->{devices} }) {
		$card{$device->{id}} = {
			id    => $device->{id},
			name  => $device->{name},
			role  => $device->{role},
			rows  => [],
		};
		push @order, $device->{id};
	}
	for my $link (@{ $view->{links} }) {
		my $item = $card{$link->{device_id}} or next;
		my $pid = $link->{player_id};
		my $name = $names->{lc $pid} || $names->{$pid} || '';
		my $drift = $link->{drift_ms} || 0;
		push @{ $item->{rows} }, {
			player_id     => $pid,
			player_name   => $name,
			drift_ms      => $link->{drift_ms},
			drift_amount  => abs($drift),
			timing        => $link->{timing},
			apart         => $link->{apart},
		};
	}
	return [ map { $card{$_} } @order ];
}

# What one player sees outside the Material skin.
# play: inputs linked to that player. settings: every linked device.
sub player_menu {
	my ($cards, $player_id) = @_;
	my $want = lc($player_id || '');
	my @play;
	my @settings;
	return { play => \@play, settings => \@settings } if $want eq '';
	for my $card (@{ $cards || [] }) {
		next unless $card && $card->{id};
		my $linked;
		for my $row (@{ $card->{rows} || [] }) {
			next unless $row && lc($row->{player_id} || '') eq $want;
			$linked = $row;
			last;
		}
		next unless $linked;
		if (($card->{role} || '') eq 'input') {
			push @play, {
				id     => $card->{id},
				name   => $card->{name} || $card->{id},
				active => $linked->{active} ? 1 : 0,
			};
		}
		push @settings, {
			id        => $card->{id},
			name      => $card->{name} || $card->{id},
			role      => $card->{role} || '',
			drift_ms  => defined $linked->{drift_ms} ? $linked->{drift_ms} : 0,
			player_id => $linked->{player_id},
		};
	}
	return { play => \@play, settings => \@settings };
}

sub _lip_sync {
	my ($role) = @_;
	return $role eq 'input' || $role eq 'output';
}

sub view {
	my ($state) = @_;
	my $devices = $state->{devices} || [];
	my %groups;
	for my $link (@{ $state->{links} || [] }) {
		push @{ $groups{$link->{device_id}} }, $link;
	}

	my @links;
	for my $device (@$devices) {
		my $group = $groups{$device->{id}} || [];
		my $master_delay;
		if (_lip_sync($device->{role}) && @$group) {
			$master_delay = delay_ms($group->[0]{drift_ms});
		}
		for my $link (@$group) {
			my $lip = _lip_sync($device->{role});
			my $delay = $lip ? delay_ms($link->{drift_ms}) : undef;
			push @links, {
				device_id   => $device->{id},
				device_name => $device->{name},
				role        => $device->{role},
				player_id   => $link->{player_id},
				drift_ms    => $link->{drift_ms},
				delay_ms    => $delay,
				timing      => $lip ? 'lip-sync' : 'stored',
				apart       => ($lip && defined $master_delay && $delay != $master_delay) ? 1 : 0,
			};
		}
	}

	my @device_rows;
	for my $device (@$devices) {
		my $bridge = undef;
		if ($device->{bridge_id}) {
			my $i = _index($state->{bridges} || [], 'id', $device->{bridge_id});
			$bridge = _public_bridge($state->{bridges}[$i]) if defined $i;
		}
		push @device_rows, {
			id          => $device->{id},
			name        => $device->{name},
			role        => $device->{role},
			address     => $device->{address} || '',
			profile     => $device->{profile} || '',
			bridge_id   => $device->{bridge_id} || '',
			bridge_name => $bridge ? $bridge->{name} : '',
			bridge_sync => $device->{bridge_sync} || 'local',
		};
	}

	my @bridges = map { _public_bridge($_) } @{ $state->{bridges} || [] };
	return {
		bridges => \@bridges,
		devices => \@device_rows,
		links   => \@links,
	};
}

1;

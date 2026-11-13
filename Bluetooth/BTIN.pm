package Plugins::Bluetooth::BTIN;

use strict;
use base qw(Slim::Player::Pipeline);

use Slim::Utils::Log;
use Slim::Utils::Prefs;

Slim::Player::ProtocolHandlers->registerHandler('btin', __PACKAGE__);

my $log = logger('plugin.bluetooth');

# Kilobytes of audio the player must hold before it starts. A live source
# cannot read ahead, so the stock remote threshold (up to 255 KB, about
# three seconds of FLAC) stays as permanent delay against the picture.
sub bufferThreshold { 32 }

sub isRemote { 1 }

sub new {
	my $class = shift;
	my $args  = shift;
	my $transcoder = $args->{'transcoder'};
	my $url        = $args->{'url'};
	my $client     = $args->{'client'};

	my $device = $url;
	$device =~ s/^btin://;

	Slim::Music::Info::setContentType($url, 'btin');
	my $quality = preferences('server')->client($client)->get('lameQuality');
	my $command = Slim::Player::TranscodingHelper::tokenizeConvertCommand2(
		$transcoder, $device, $url, 1, $quality
	);
	$log->info("bluetooth input command=$command");

	my $self = $class->SUPER::new(undef, $command);
	${*$self}{'contentType'} = $transcoder->{'streamformat'};
	return $self;
}

sub canHandleTranscode { 1 }

sub getStreamBitrate { 256_000 }

sub isAudioURL { 1 }

sub canDirectStream { 0 }

sub contentType {
	my $self = shift;
	return ${*$self}{'contentType'};
}

my %by_mac;

# AVRCP track for one Fire TV, keyed by MAC. Empty titles are ignored so a
# gap between Spotify tracks does not wipe the name that is already showing.
sub remember {
	my ($class, $mac, $meta) = @_;
	$mac = uc($mac || '');
	return 0 unless $mac =~ /^(?:[0-9A-F]{2}:){5}[0-9A-F]{2}$/;
	return 0 unless ref $meta eq 'HASH' && ($meta->{title} || '') ne '';
	my $next = {
		title    => $meta->{title},
		artist   => $meta->{artist} || '',
		album    => $meta->{album} || '',
		duration => $meta->{duration} || 0,
	};
	my $prev = $by_mac{$mac} || {};
	my $same = ($prev->{title} || '') eq $next->{title}
		&& ($prev->{artist} || '') eq $next->{artist}
		&& ($prev->{album} || '') eq $next->{album}
		&& ($prev->{duration} || 0) == $next->{duration};
	$by_mac{$mac} = $next;
	return $same ? 0 : 1;
}

sub recall {
	my ($class, $mac) = @_;
	return $by_mac{uc($mac || '')} || {};
}

sub getMetadataFor {
	my ($class, $client, $url, $forceCurrent) = @_;
	my $mac = '';
	$mac = uc($1) if defined $url && $url =~ /DEV=([^,;\s]+)/i;
	my $meta = $class->recall($mac);
	my $out = {
		bitrate => 'AAC',
		type    => 'Bluetooth',
	};
	$out->{title} = $meta->{title} if $meta->{title};
	$out->{artist} = $meta->{artist} if $meta->{artist};
	$out->{album} = $meta->{album} if $meta->{album};
	$out->{duration} = $meta->{duration} if $meta->{duration};
	return $out;
}

1;

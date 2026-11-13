#!/usr/local/bin/python3.11
"""Write Fire TV AVRCP tracks to /tmp/lyrion-bt-meta.json.

This process polls BlueZ. Lyrion only reads the file, so a slow Bluetooth
reply cannot freeze the server.
"""

import json
import os
import time

PATH = "/tmp/lyrion-bt-meta.json"
PID_PATH = "/tmp/lyrion-bt-meta.pid"
WANT_PATH = "/tmp/lyrion-bt-volume-want.json"


def text(value):
    if value is None:
        return ""
    if isinstance(value, (bytes, bytearray)):
        return value.decode("utf-8", "replace").strip()
    if isinstance(value, str):
        return value.strip()
    if isinstance(value, (list, tuple)):
        parts = [text(item) for item in value]
        return ", ".join(part for part in parts if part)
    return str(value).strip()


def duration_ms(value):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return 0
    # 2^32-1 is BlueZ for "no duration", which Prime Video sends.
    if number <= 0 or number >= 4_000_000_000:
        return 0
    return number


def position_ms(value):
    try:
        number = int(value)
    except (TypeError, ValueError):
        return 0
    if number <= 0 or number >= 4_000_000_000:
        return 0
    return number


def address_from_path(path):
    name = str(path or "").rstrip("/").split("/")[-1]
    if name.startswith("dev_"):
        name = name[4:]
    hexes = name.replace("_", "").replace(":", "")
    if len(hexes) != 12:
        return ""
    return ":".join(hexes[i:i + 2] for i in range(0, 12, 2)).upper()


def payload(address, track, status, position=0):
    track = track or {}
    return {
        "title": text(track.get("Title")),
        "artist": text(track.get("Artist")),
        "album": text(track.get("Album")),
        "duration_ms": duration_ms(track.get("Duration")),
        "position_ms": position_ms(position),
        "status": text(status),
        "address": address,
    }


def changed(previous, current):
    if not current.get("title"):
        return False
    keys = ("title", "artist", "album", "duration_ms")
    return any((previous or {}).get(key) != current.get(key) for key in keys)


def position_moved(previous, current):
    if not current.get("title"):
        return False
    previous_ms = int((previous or {}).get("position_ms") or 0)
    current_ms = int(current.get("position_ms") or 0)
    return abs(previous_ms - current_ms) >= 2000


def volume_pct(values):
    levels = []
    for value in values or []:
        try:
            number = int(value)
        except (TypeError, ValueError):
            continue
        if 0 <= number <= 127:
            levels.append(number)
    if not levels:
        return None
    return int(round(sum(levels) / len(levels) * 100 / 127))


def volume_level(pct):
    pct = max(0, min(100, int(pct)))
    return int(round(pct * 127 / 100))


def volume_moved(previous, current):
    if current.get("volume") is None:
        return False
    if (previous or {}).get("volume") is None:
        return True
    return abs(int(previous["volume"]) - int(current["volume"])) >= 2


def write_snapshot(snapshot):
    temporary = PATH + ".next"
    with open(temporary, "w", encoding="utf-8") as handle:
        json.dump(snapshot, handle, ensure_ascii=False)
        handle.write("\n")
    os.replace(temporary, PATH)


def read_players(bus):
    import dbus

    root = bus.get_object("org.bluez", "/")
    manager = dbus.Interface(root, "org.freedesktop.DBus.ObjectManager")
    found = []
    for path, interfaces in manager.GetManagedObjects().items():
        player = interfaces.get("org.bluez.MediaPlayer1")
        if not player:
            continue
        address = address_from_path(player.get("Device") or path)
        if address:
            found.append((str(path), address))
    return found


def sink_path(address):
    hexes = address.replace(":", "_")
    return "/org/bluealsa/hci0/dev_%s/a2dpsnk/source" % hexes


def read_volume(bus, address):
    import dbus

    obj = bus.get_object("org.bluealsa", sink_path(address))
    props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
    pcm = props.GetAll("org.bluealsa.PCM1")
    # Soft volume stays off. The stream remains full scale and the platine
    # volume is the only loudness control, so the two knobs are not stacked.
    return volume_pct(pcm.get("Volume")), max(int(pcm.get("Channels") or 0), 1)


def set_volume(bus, address, pct):
    import dbus

    path = sink_path(address)
    obj = bus.get_object("org.bluealsa", path)
    props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
    _, channels = read_volume(bus, address)
    level = dbus.Byte(volume_level(pct))
    props.Set(
        "org.bluealsa.PCM1",
        "Volume",
        dbus.Array([level] * channels, signature="y"),
    )


def apply_wanted(bus):
    try:
        with open(WANT_PATH, encoding="utf-8") as handle:
            data = json.load(handle)
    except FileNotFoundError:
        return
    except Exception as error:
        print("volume want unreadable: %s" % error, flush=True)
        return
    address = str(data.get("address") or "").upper()
    volume = data.get("volume")
    if not address or volume is None:
        return
    try:
        set_volume(bus, address, int(volume))
        os.remove(WANT_PATH)
    except Exception as error:
        print("volume set failed: %s" % error, flush=True)


def read_player(bus, path, address):
    import dbus

    obj = bus.get_object("org.bluez", path)
    props = dbus.Interface(obj, "org.freedesktop.DBus.Properties")
    player = props.GetAll("org.bluez.MediaPlayer1")
    return payload(address, player.get("Track"), player.get("Status"), player.get("Position"))


def main():
    import dbus

    with open(PID_PATH, "w", encoding="utf-8") as handle:
        handle.write(str(os.getpid()))
    bus = dbus.SystemBus()
    last = {}
    while True:
        apply_wanted(bus)
        snapshot = {}
        try:
            for path, address in read_players(bus):
                row = read_player(bus, path, address)
                try:
                    volume, _channels = read_volume(bus, address)
                except Exception:
                    volume = None
                if volume is not None:
                    row["volume"] = volume
                previous = last.get(address)
                if (
                    changed(previous, row)
                    or position_moved(previous, row)
                    or volume_moved(previous, row)
                    or (row.get("title") and address not in last)
                ):
                    snapshot[address] = row
                elif address in last:
                    snapshot[address] = last[address]
        except Exception as error:
            print("meta read failed: %s" % error, flush=True)
            time.sleep(2)
            continue
        if snapshot != last and any(row.get("title") for row in snapshot.values()):
            write_snapshot(snapshot)
            last = snapshot
        time.sleep(1)


if __name__ == "__main__":
    main()

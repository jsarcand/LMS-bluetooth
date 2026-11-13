#!/usr/bin/env python3
import importlib.util
import pathlib
import unittest

PATH = pathlib.Path(__file__).resolve().parents[1] / "Bluetooth" / "bt-meta.py"
spec = importlib.util.spec_from_file_location("bt_meta", PATH)
meta = importlib.util.module_from_spec(spec)
spec.loader.exec_module(meta)


class TrackPayloadTest(unittest.TestCase):
    def test_spotify_track_becomes_one_row(self):
        row = meta.payload(
            "68:13:F3:FB:82:EA",
            {
                "Title": "Release from silence",
                "Artist": ["Patrick Buote"],
                "Album": "Release from silence",
                "Duration": 137642,
            },
            "playing",
            73852,
        )
        self.assertEqual(row["title"], "Release from silence")
        self.assertEqual(row["artist"], "Patrick Buote")
        self.assertEqual(row["album"], "Release from silence")
        self.assertEqual(row["duration_ms"], 137642)
        self.assertEqual(row["position_ms"], 73852)

    def test_unknown_duration_is_dropped(self):
        row = meta.payload("68:13:F3:FB:82:EA", {"Title": "PrimeVideo", "Duration": 4294967295}, "playing", 6014408)
        self.assertEqual(row["duration_ms"], 0)
        self.assertEqual(row["position_ms"], 6014408)

    def test_bluetooth_volume_maps_onto_the_platine(self):
        self.assertEqual(meta.volume_pct([127, 127]), 100)
        self.assertEqual(meta.volume_pct([0, 0]), 0)
        self.assertEqual(meta.volume_pct([64]), 50)
        self.assertEqual(meta.volume_level(100), 127)
        self.assertEqual(meta.volume_level(50), 64)
        self.assertEqual(meta.volume_level(0), 0)

    def test_volume_change_is_noticed(self):
        quiet = {"title": "Song", "volume": 40}
        loud = {"title": "Song", "volume": 55}
        self.assertTrue(meta.volume_moved(quiet, loud))
        self.assertFalse(meta.volume_moved(loud, dict(loud)))

    def test_position_moves_when_two_seconds_pass(self):
        first = meta.payload("68:13:F3:FB:82:EA", {"Title": "Release from silence", "Duration": 137642}, "playing", 73852)
        later = meta.payload("68:13:F3:FB:82:EA", {"Title": "Release from silence", "Duration": 137642}, "playing", 76000)
        self.assertFalse(meta.changed(first, later))
        self.assertTrue(meta.position_moved(first, later))

    def test_empty_title_does_not_count_as_a_change(self):
        current = meta.payload("68:13:F3:FB:82:EA", {"Title": "Release from silence", "Artist": "Patrick Buote"}, "playing")
        gap = meta.payload("68:13:F3:FB:82:EA", {}, "paused")
        self.assertFalse(meta.changed(current, gap))

    def test_new_title_counts_as_a_change(self):
        first = meta.payload("68:13:F3:FB:82:EA", {"Title": "Release from silence"}, "playing")
        second = meta.payload("68:13:F3:FB:82:EA", {"Title": "Next song", "Artist": "Someone"}, "playing")
        self.assertTrue(meta.changed(first, second))

    def test_address_comes_from_the_bluez_path(self):
        self.assertEqual(
            meta.address_from_path("/org/bluez/hci0/dev_68_13_F3_FB_82_EA"),
            "68:13:F3:FB:82:EA",
        )


if __name__ == "__main__":
    unittest.main()

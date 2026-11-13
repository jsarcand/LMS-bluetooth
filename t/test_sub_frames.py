"""Frame codec for the MartinLogan helper. Does not open Bluetooth."""
import importlib.util
import unittest
from pathlib import Path


def load_helper():
    path = Path(__file__).resolve().parents[1] / "Bluetooth" / "sub-ble.py"
    spec = importlib.util.spec_from_file_location("sub_ble_frames", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


H = load_helper()


class Frames(unittest.TestCase):
    def test_night_mode_frame(self):
        self.assertEqual(H.encode_setting("mode", "night"), "LMD2;")
        parsed = H.parse_frame("LMD2;")
        self.assertEqual(parsed["value"], "night")
        self.assertTrue(parsed["ok"])

    def test_negative_level(self):
        self.assertEqual(H.encode_setting("level", -10), "VOL-10;")
        self.assertEqual(H.parse_frame("VOL-10;")["value"], -10)

    def test_other_fields(self):
        self.assertEqual(H.encode_setting("phase", 180), "PHA180;")
        self.assertEqual(H.encode_setting("polarity", "inverted"), "POL1;")
        self.assertEqual(H.encode_setting("lowpass", 80), "LPF80;")
        self.assertEqual(H.parse_frame("POL0;")["value"], "normal")

    def test_bare_semicolon(self):
        parsed = H.parse_frame(";")
        self.assertTrue(parsed["bare"])
        self.assertNotIn("token", parsed)

    def test_rejects_out_of_range_and_unknown(self):
        for setting, value in (("level", -41), ("level", 13), ("phase", 181), ("lowpass", 34), ("mode", "party")):
            with self.assertRaises(ValueError):
                H.encode_setting(setting, value)
        self.assertFalse(H.parse_frame("LPF200;")["ok"])
        self.assertFalse(H.parse_frame("LMD9;")["ok"])
        self.assertFalse(H.parse_frame("IDS1.1.360;")["ok"])
        self.assertIsNone(H.parse_frame("VOL-10"))
        with self.assertRaises(ValueError):
            H.encode_setting("lbs", 1)


if __name__ == "__main__":
    unittest.main()

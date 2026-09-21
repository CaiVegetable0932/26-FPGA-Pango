"""Test device binding without opening any physical capture device."""
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

SPEC = importlib.util.spec_from_file_location("hdmi_diag", Path(__file__).resolve().parents[1] / "src/hdmi_diag_capture.py")
CAPTURE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(CAPTURE)


class DeviceIdentityTests(unittest.TestCase):
    def select(self, name="Hagibis", path="@device:pnp:vid_1de1&pid_f105", count=1):
        """Emulate the enumeration child output; no DirectShow open occurs."""
        with tempfile.TemporaryDirectory() as folder:
            root = Path(folder)
            (root / "device_enumeration.json").write_text(json.dumps({
                "unique_hagibis": count == 1,
                "hagibis_matches": [{"FriendlyName": name, "MonikerDisplayName": path}] * count
            }), encoding="utf-8")
            with patch.object(CAPTURE.subprocess, "run"):
                return CAPTURE.verified_device(root)

    def test_expected_device(self):
        self.assertEqual(self.select()["FriendlyName"], "Hagibis")

    def test_webcam_rejected(self):
        with self.assertRaises(RuntimeError):
            self.select(name="USB2.0 FHD UVC WebCam")

    def test_wrong_usb_id_rejected(self):
        with self.assertRaises(RuntimeError):
            self.select(path="@device:pnp:vid_3277&pid_0051")

    def test_missing_or_ambiguous_rejected(self):
        for count in (0, 2):
            with self.assertRaises(RuntimeError):
                self.select(count=count)


if __name__ == "__main__":
    unittest.main()

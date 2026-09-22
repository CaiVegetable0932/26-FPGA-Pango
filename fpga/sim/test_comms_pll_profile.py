"""Prevent recurrence of the cold-boot GPLL bandwidth configuration mistake.

Checks native generated parameters as well as the source profile. This static
test does not replace PLL model simulation, timing analysis or hardware lock.
"""
import copy
import importlib.util
import json
from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("prepare_ips", ROOT / "scripts/prepare_ips.py")
PREPARE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PREPARE)


class CommsClockProfile(unittest.TestCase):
    """Validate the board profile and both persisted/native parameter forms."""

    def setUp(self):
        catalog = json.loads((ROOT / "config/ip_catalog.json").read_text(encoding="utf-8"))
        self.clock = next(ip["clocks"] for ip in catalog["ips"] if ip["name"] == "comms_pll")

    def test_generated_bandwidth_and_frequency(self):
        values = PREPARE.configure_pll({}, self.clock)
        self.assertEqual(values["BANDWIDTH"], "HIGH")
        self.assertEqual(values["BANDWIDTH_advancedPage"], "HIGH")
        pfd = float(values["CLKIN_FREQ"]) / int(values["STATIC_RATIOI"])
        vco = pfd * int(values["STATIC_RATIOM"]) * float(values["STATIC_RATIO7"])
        self.assertEqual(vco, self.clock["vco_mhz"])
        self.assertEqual(vco / float(values["STATIC_RATIO0"]), 125)
        native = (ROOT / "ip/comms_pll/comms_pll.v").read_text(encoding="utf-8")
        self.assertRegex(native, r'localparam\s+BANDWIDTH\s*=\s*"HIGH"')

    def test_bad_bandwidth_rejected(self):
        # Reproduce the exact old profile, which generated without warnings
        # despite violating the manual's PFD/bandwidth operating requirement.
        bad = copy.deepcopy(self.clock)
        bad["bandwidth"] = "OPTIMIZED"
        with self.assertRaisesRegex(ValueError, "Illegal GPLL"):
            PREPARE.configure_pll({}, bad)

    def test_board_led_polarity(self):
        # The MINI V1.3 schematic uses active-high LEDs; a reset-held design
        # must not light every status indicator as if all statuses were true.
        top = (ROOT / "rtl/board/mini_comms_bringup.v").read_text(encoding="utf-8")
        assignment = re.search(r"assign led\s*=(.*?);", top).group(1)
        self.assertNotIn("~", assignment)


if __name__ == "__main__":
    unittest.main()

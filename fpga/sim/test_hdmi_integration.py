"""Offline source-closure guards for the integrated HDMI path, not board tests."""
import hashlib
from pathlib import Path
import re
import unittest

FPGA = Path(__file__).resolve().parents[1]


class IntegrationTests(unittest.TestCase):
    def test_both_projects_use_shared_transmitter(self):
        """Prevent a diagnostic-only import or regression to the old serializer."""
        for name in ("pango_video_top", "mini_camera_diag"):
            project = (FPGA / f"project/{name}/{name}.tcl").read_text(encoding="utf-8")
            sources = re.findall(r"^add_design \[file join \$fpga_root (.+)\]", project, re.M)
            self.assertIn("rtl hdmi hdmi_tx_rgb.v", sources)
            self.assertIn("rtl hdmi hdmi_tx_oserdes.v", sources)
            self.assertIn("ip hdmi_tx_pll clk_hdmi.v", sources)
            self.assertFalse(any("tmds_serializer" in s or "rgb2tmds" in s for s in sources))
            for source in sources:
                self.assertTrue(FPGA.joinpath(*source.split()).is_file(), source)

    def test_real_camera_scanout_is_preserved(self):
        """Camera pixels must still come from the frame pool, never color bars."""
        top = (FPGA / "rtl/mini_camera_diag/vendor/Top.v").read_text(encoding="utf-8")
        self.assertIn("hdmi_tx_rgb u_hdmi_tx", top)
        self.assertIn(".rgb565(vout_data_0)", top)
        # A failed capture has a clearly marked diagnostic raster, never substituted camera data.
        self.assertIn("display_valid_sync ? camera_rgb888 : diagnostic_rgb", top)
        self.assertIn("mini_diag_raster u_diag_raster", top)
        self.assertIn("mini_frame_pool u_frame_pool", top)
        self.assertNotIn("hdmi_720p_diagnostic", top)

    def test_verified_pll_source(self):
        """The board PLL copy must not silently drift back to the failed clock IP."""
        digest = hashlib.sha256((FPGA / "ip/hdmi_tx_pll/clk_hdmi.v").read_bytes()).hexdigest()
        self.assertEqual(digest, "b65ab143b4a61fb4aafdba60c99850b919f90c445c61624e0a9cce0289b7599e")

    def test_tmds_pins_and_voltage(self):
        """Both physical names and electrical mode are part of the link contract."""
        text = (FPGA / "constraints/board_pins.fdc").read_text(encoding="utf-8")
        pins = {"hdmi_clk_p":"N21", "hdmi_clk_n":"N22", "hdmi_data_p[0]":"R25",
                "hdmi_data_n[0]":"P25", "hdmi_data_p[1]":"P23", "hdmi_data_n[1]":"P24",
                "hdmi_data_p[2]":"N23", "hdmi_data_n[2]":"N24"}
        for port, pin in pins.items():
            for key, value in (("PAP_IO_LOC", pin), ("PAP_IO_VCCIO", "3.3"), ("PAP_IO_STANDARD", "TMDS")):
                self.assertIn(f"define_attribute {{p:{port}}} {{{key}}} {{{value}}}", text)


if __name__ == "__main__":
    unittest.main()

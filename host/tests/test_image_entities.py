"""Fixed body vectors and invalid whole-draft guards for image controls."""
import struct
import unittest

from pango_video.image_entities import camera_config, isp_color, tone_config, tone_lut


class ImageEntityTests(unittest.TestCase):
    def test_frozen_tone_vector(self):
        # This literal is independent of struct.pack's field choices.
        expected = bytes.fromhex("010307046090100007000000" + "00" * 20)
        self.assertEqual(tone_config(mode=1, curve=3, lut_version=7), expected)
        self.assertEqual(len(tone_lut(gamma=0.7)), 256)
        self.assertEqual(tone_lut(gamma=0.7)[81], 114)
        self.assertEqual(tone_lut(gamma=1.3)[64], 42)

    def test_monotonic_and_policy_validation(self):
        with self.assertRaises(ValueError):
            tone_lut([255] + [0] * 255)
        with self.assertRaises(ValueError):
            tone_config(mode=2, curve=3, lut_version=7)
        with self.assertRaises(ValueError):
            tone_config(mode=2, curve=1, allowed_mask=5)

    def test_ccm_body_and_absolute_row_bound(self):
        body = isp_color(ccm_enabled=True, ccm=(0, 0, 16384, 0, 16384, 0, 16384, 0, 0))
        self.assertEqual(len(body), 64)
        self.assertEqual(body[:16].hex(), "00000000001000100010001001000000")
        self.assertEqual(struct.unpack_from("<9i", body, 16), (0, 0, 16384, 0, 16384, 0, 16384, 0, 0))
        with self.assertRaises(ValueError):
            isp_color(ccm=(131071, 131071, 0, 0, 16384, 0, 0, 0, 16384))
        with self.assertRaises(ValueError):
            isp_color(wb_mode=1, awb_step=257)

    def test_camera_limits_and_measured_150hz(self):
        self.assertEqual(len(camera_config()), 48)
        self.assertEqual(struct.unpack_from("<I", camera_config(), 4)[0], 10752)
        self.assertEqual(camera_config(mode=2)[0], 2)
        with self.assertRaises(ValueError):
            camera_config(mode=3)
        with self.assertRaises(ValueError):
            camera_config(exposure=17857)
        with self.assertRaises(ValueError):
            camera_config(flicker=1)
        # Synthetic calibration demonstrates conversion only, not real board timing.
        body = camera_config(flicker=1, line_time_ns=30000, period150_code=3556,
                             exposure=7112, exposure_min=3556, exposure_max=14224,
                             timing_calibration_id=123)
        self.assertEqual(len(body), 48)


if __name__ == "__main__":
    unittest.main()

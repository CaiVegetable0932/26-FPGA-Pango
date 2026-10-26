"""Fixed bytes, rejected domains and honest source/display control readback."""
import struct
import unittest

from pango_video.fpga_rgb_control import affine_enable, affine_read_page, affine_state, geometry, mode
from pango_video.fpga_rgb_control import reference_entity, begin_reference, entity_chunk, commit_entity


class AffineControlTests(unittest.TestCase):
    def test_toggle_fixed_payload(self):
        """The handoff's exact OFF/ON byte examples remain stable."""
        self.assertEqual(affine_enable(False, 1, 7)[8:-2].hex(),
                         '000000000100000007000000')
        self.assertEqual(affine_enable(True, 2, 7)[8:-2].hex(),
                         '010000000200000007000000')
        self.assertEqual(affine_read_page(3)[8:-2], b'\x0a\x00\x03\x00')

    def test_reject_invalid_control(self):
        """Do not coerce UI strings, booleans as versions or unsupported modes."""
        for args in [('false', 1, 7), (2, 1, 7), (False, 0, 7),
                     (True, 2**31, 7), (True, True, 7), (True, 1, 0)]:
            with self.assertRaises(ValueError):
                affine_enable(*args)
        with self.assertRaises(ValueError):
            mode(2, 1)

    def test_projective_rejected(self):
        """A valid CRC must not legitimize a non-affine third row."""
        from pango_video.fpga_rgb_control import COEFFICIENT_NAMES
        coeff = dict.fromkeys(COEFFICIENT_NAMES, 0)
        coeff.update(fx=65536, fy=65536, a22=1 << 26)
        self.assertEqual(len(geometry(coeff, 2, 1)), 90)
        for name, value in [('a20', 1), ('a21', -1), ('a22', 0)]:
            with self.assertRaises(ValueError):
                geometry(dict(coeff, **{name: value}), 2, 1)

    def test_source_is_distinct_from_display(self):
        """Queued, source-applied and display-adopted are separate states."""
        record = bytearray(96)
        struct.pack_into('<HH', record, 0, 1, 10)
        record[4] = 1 | 4  # Requested ON; source still OFF, display unverified.
        struct.pack_into('<4I', record, 8, 2, 7, 1, 3)
        struct.pack_into('<QQ', record, 24, 99, 21)
        state = affine_state(record)
        self.assertTrue(state['pending'])
        self.assertFalse(state['applied_enable'])
        self.assertFalse(state['display_known'])
        self.assertFalse(state['hdmi_capture_source_verified'])
        self.assertEqual(state['source_frame_id'], '21')
        record[95] = 1
        with self.assertRaises(ValueError):
            affine_state(record)

    def test_reference_compiles_normalized_rays(self):
        """Independent integer expected values match the RTL test's 35x33 view."""
        data = reference_entity(32, 32, 17, 16, 35, 33, 1)
        self.assertEqual(len(data), 64)
        self.assertEqual(struct.unpack_from('<6i', data, 16),
                         (2097152, 0, -35651584, 0, 2097152, -33554432))
        self.assertEqual(data[40:50].hex(), '23002100010000000100')
        self.assertEqual(begin_reference(data, 23, 2, 7)[8:28].hex(),
                         '0900010017000000020000000700000040000000')
        self.assertEqual(len(entity_chunk(23, 0, data)), 82)
        self.assertEqual(commit_entity(23, data)[8:12], b'\x17\0\0\0')
        for args in [(0, 32, 17, 16), (float('nan'), 32, 17, 16),
                     (1, 1, 0, 0), (32, 32, 9000, 16)]:
            with self.assertRaises(ValueError):
                reference_entity(*args)


if __name__ == '__main__':
    unittest.main()

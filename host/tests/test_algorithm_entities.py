"""Wire boundaries, paged status, inverse-view math and rejected drafts."""
import struct
import unittest

from pango_video.affine_draft import compile_draft
from pango_video.fpga_entities import encode_entity, begin_entity, read_entity
from pango_video.fpga_rgb_control import COEFFICIENT_NAMES, reference_entity


class EntityTests(unittest.TestCase):
    def test_tone_wire_and_full_lut(self):
        tone = encode_entity(1, dict(mode=1, curve=3, lut_version=17))
        self.assertEqual(tone, bytes.fromhex('010307046090100011000000') + bytes(20))
        lut = encode_entity(2, dict(gamma=1))
        self.assertEqual(lut, bytes(range(256)))
        wire = begin_entity(2, lut, 9, 2, 3)
        self.assertEqual(struct.unpack_from('<HHIIIHH', wire, 8), (2, 1, 9, 2, 3, 256, 0))
        with self.assertRaises(ValueError):
            encode_entity(2, dict(values=list(reversed(range(256)))))

    def test_colour_limits_not_just_wire_width(self):
        with self.assertRaises(ValueError):
            encode_entity(3, dict(ccm=[100000,100000,0,0,16384,0,0,0,16384]))
        with self.assertRaises(ValueError):
            encode_entity(3, dict(wb_mode=1, awb_step=300))
        body = encode_entity(3, dict(ccm_enabled=True, ccm=[16384,4096,0,0,16384,0,0,0,16384]))
        self.assertEqual(len(body), 64)
        self.assertEqual(struct.unpack_from('<i', body, 20)[0], 4096)

    def test_camera_rejects_unmeasured_flicker_and_unknown_mode(self):
        with self.assertRaises(ValueError):
            encode_entity(7, dict(mode=3))
        with self.assertRaises(ValueError):
            encode_entity(7, dict(flicker=1))
        self.assertEqual(encode_entity(7,dict(mode=2))[0],2)
        body = encode_entity(7, dict(mode=0, exposure=8000, gain=32))
        self.assertEqual(len(body),48)
        self.assertEqual(struct.unpack_from('<IH',body,4),(8000,32))
        record = struct.pack('<HHIIHBBQQ',1,7,2,3,48,5,0,4,5)+body+bytes(16)
        class Uart:
            def exchange(self, command, payload):
                page=payload[2]
                return bytes([0,command,page,24])+record[page*24:(page+1)*24]+b'AFG1'
        self.assertTrue(read_entity(Uart(),7)['exposure_binding_unverified'])

    def test_twelve_page_readback_keeps_large_identity(self):
        record = struct.pack('<HHIIHBBQQ', 1, 2, 7, 8, 256, 3, 0, 2**60+1, 2**61+3) + bytes(range(256))
        class Uart:
            def exchange(self, command, payload):
                kind,page,reserved=struct.unpack('<HBB',payload)
                self.last=(kind,page,reserved)
                return bytes([0,command,page,24])+record[page*24:(page+1)*24]+b'AFG1'
        uart=Uart(); status=read_entity(uart,2)
        self.assertEqual(uart.last,(2,11,0))
        self.assertEqual(status['source_frame_id'],str(2**61+3))
        self.assertTrue(status['pending'])
        self.assertEqual(bytes.fromhex(status['body_hex']),bytes(range(256)))

    def test_affine_translation_is_inverse_and_preserves_lens(self):
        body=reference_entity(fx=800,fy=800,cx=960,cy=540,width=1920,height=1080,calibration_id=1)
        ref=dict(width=1920,height=1080,coefficients=list(struct.unpack_from('<6i',body,16)))
        geo=dict(zip(COEFFICIENT_NAMES, ref['coefficients']+[0,0,0,0,800*65536,800*65536,960*65536,540*65536,0,0,1<<26]))
        same=compile_draft(ref,geo)
        self.assertEqual(same['coefficients'],geo)
        moved=compile_draft(ref,geo,translate_x=80)
        self.assertAlmostEqual((moved['coefficients']['a02']-geo['a02'])/(1<<26),-.1,places=5)
        self.assertEqual(moved['coefficients']['fx'],geo['fx'])
        self.assertEqual(len(moved['preview_mask']),2304)
        with self.assertRaises(ValueError):
            compile_draft(ref,geo,scale=0)


if __name__ == '__main__':
    unittest.main()

"""Offline camera commissioning identity/byte-order/rejection regression."""
import unittest
from pango_video.raw8_boot import crc16, metadata


class Raw8BootTests(unittest.TestCase):
    def setUp(self):
        self.args = [0x0102030405060708, '02:00:00:00:00:01', '02:00:00:00:00:02', '192.168.1.50', '192.168.1.100']

    def test_wire_and_preview_identity(self):
        """Assert exact same vector as RTL and keep camera provenance unverified."""
        boot, receiver = metadata(*self.args)
        wire = bytes.fromhex(boot['command_hex'])
        self.assertEqual(crc16(b'123456789'), 0x29b1)
        self.assertEqual(len(wire), 42)
        self.assertEqual(wire[3], 0x71)
        self.assertEqual(wire[8:-2].hex(), '0807060504030201020000000001020000000002c0a80132c0a8016451c350c3')
        self.assertEqual(int.from_bytes(wire[-2:], 'little'), crc16(wire[2:-2]))
        self.assertEqual(receiver['stream_epoch'], boot['epoch'])
        self.assertEqual(receiver['source_mode'], 'hardware_unverified')
        self.assertEqual(receiver['bayer_code'], 4)
        self.assertIsNone(boot['hdmi_source_frame_id'])

    def test_rejected_peers(self):
        """Malformed/zero/multicast peers may not create a usable boot vector."""
        for index, bad in ((0, 0), (1, '00:00:00:00:00:00'), (2, 'ff:ff:ff:ff:ff:ff'), (3, '0.1.1.1'), (4, '239.1.1.1')):
            args = self.args.copy()
            args[index] = bad
            with self.assertRaises(ValueError):
                metadata(*args)


if __name__ == '__main__':
    unittest.main()

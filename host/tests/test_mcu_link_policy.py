"""Verify grant persistence and independent on-wire field/CRC decoding."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
import zlib
from pango_video.mcu_link_policy import reserve_sessions, policy_body, upload, read_policy_page
from pango_video.raw8_boot import crc16


class PolicyTests(unittest.TestCase):
    def test_persistence_and_fail_closed(self):
        """A new caller skips the entire earlier grant, not just used IDs."""
        build = Path(__file__).resolve().parents[1] / 'build/mcu_link_policy_tests'
        build.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=build) as directory:
            path = Path(directory) / 'sessions.json'
            self.assertEqual(reserve_sessions(path, 3), (1, 3))
            self.assertEqual(reserve_sessions(path, 2), (4, 5))
            lock = path.with_suffix('.json.lock')
            lock.write_text('')
            with self.assertRaises(FileExistsError):
                reserve_sessions(path)
            lock.unlink()
            path.write_text(json.dumps({'schema': 1, 'last_reserved': 0xffffffff}))
            with self.assertRaises(ValueError):
                reserve_sessions(path, 1)
            self.assertEqual(json.loads(path.read_text())['last_reserved'], 0xffffffff)
            path.write_text('{}')
            with self.assertRaises(ValueError):
                reserve_sessions(path)

    def test_wire_and_evidence(self):
        """Check exact body offsets, outer CRC16, upload CRC32 and page bounds."""
        body = policy_body(enabled=True, first_session=100, last_session=110,
                           approved=True, config_version=2, boot_id=11, config_crc32=123,
                           timing_valid=True, capture_error_us=900, evidence_id=7)
        self.assertEqual(len(body), 64)
        self.assertEqual(struct.unpack_from('<IIIQIII', body, 4), (100, 110, 2, 11, 123, 900, 7))
        self.assertEqual(body[36:], bytes(28))
        packets = upload(body, version=1, entity_id=7, transaction=23)
        for packet in packets:
            self.assertEqual(crc16(packet[2:-2]), int.from_bytes(packet[-2:], 'little'))
        self.assertEqual(struct.unpack_from('<HHIIIHHI', packets[0], 8),
                         (12, 1, 23, 1, 7, 64, 0, zlib.crc32(body)))
        self.assertEqual(packets[1][16:-2], body)
        self.assertEqual(read_policy_page(7)[8:-2], b'\x0c\x00\x07\x00')
        with self.assertRaises(ValueError):
            read_policy_page(8)
        with self.assertRaises(ValueError):
            policy_body(enabled=True, first_session=1, last_session=2, approved=True)
        with self.assertRaises(ValueError):
            policy_body(enabled=True, first_session=1, last_session=2, timing_valid=True)


if __name__ == '__main__':
    unittest.main()

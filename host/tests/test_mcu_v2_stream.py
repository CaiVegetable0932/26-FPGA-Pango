"""Offline host/FPGA shared vector and deadline/source validation regression."""
import json
from pathlib import Path
import struct
import sys
import unittest

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / "src"))
import mcu_pose_v2 as protocol


class StreamTests(unittest.TestCase):
    def setUp(self):
        """Use firmware's actual immutable frame, not a duplicated field layout."""
        self.vector = bytes.fromhex(json.loads((HOST.parent / "mcu/tests/vectors.json").read_text())["STATE"])

    def test_shared_errors_fragmentation(self):
        """All shared rescan vectors are decoded under one-byte fragmentation."""
        folder = HOST.parent / "fpga/sim/vectors/network_control"
        for name in ("state", "nested_bad_crc", "bad_length_then_state", "bad_version_then_state"):
            decoder = protocol.StreamDecoder()
            data = bytes.fromhex((folder / (name+".hex")).read_text())
            result = []
            for index, byte in enumerate(data):
                result.extend(decoder.feed(bytes([byte]), index*22))
            self.assertEqual(result, [self.vector], name)
            self.assertLessEqual(decoder.stats["peak_bytes"], 2048)

    def test_absolute_deadline_and_overflow(self):
        """Trickle bytes never renew a partial candidate's absolute deadline."""
        decoder = protocol.StreamDecoder()
        self.assertEqual(decoder.feed(self.vector[:2], 0), [])
        self.assertEqual(decoder.feed(self.vector[2:4], 29999), [])
        decoder.feed(b"", 30000)
        self.assertEqual(decoder.stats["timeout"], 1)
        self.assertEqual(decoder.feed(self.vector, 31000), [self.vector])
        self.assertEqual(decoder.feed(b"\x33"*2049, 32000), [])
        self.assertEqual(decoder.stats["overflow"], 1)
        self.assertEqual(decoder.feed(self.vector, 33000), [self.vector])

    def test_validity_and_source(self):
        """Legal V2 sources retain normalized/relative semantics and null q_wc."""
        payload = bytearray(protocol.decode(self.vector)[2])
        self.assertIsNone(protocol.state(payload)["q_wc"])
        for offset, value in ((90, 0x3F), (91, 0x0F), (92, 4), (93, 4)):
            bad = payload.copy()
            bad[offset] = value
            with self.assertRaises(ValueError):
                protocol.state(bad)
        bad = payload.copy()
        struct.pack_into("<i", bad, 40, 100000001)
        with self.assertRaises(ValueError):
            protocol.state(bad)


if __name__ == "__main__":
    unittest.main()

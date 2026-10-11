"""Compare C firmware vectors with the independent standard-library codec."""
import binascii
import json
from pathlib import Path
import struct
import sys
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import mcu_pose_v2 as protocol


class Interoperability(unittest.TestCase):
    def test_vectors(self):
        path = Path(__file__).resolve().parents[2] / "mcu/tests/vectors.json"
        vectors = json.loads(path.read_text(encoding="utf-8"))
        self.assertEqual(binascii.crc_hqx(b"123456789", 0xFFFF), 0x29B1)
        expected = {"GET_INFO": (0x40, 0), "OPEN": (0x41, 16), "STATE": (0x81, 96),
                    "MOVE_ABS": (0x46, 48), "EVENT": (0x90, 40), "SYNC_REPLY": (0x82, 40)}
        for name, hex_frame in vectors.items():
            frame = bytes.fromhex(hex_frame)
            cmd, seq, payload = protocol.decode(frame)
            self.assertEqual((cmd, len(payload)), expected[name])
            self.assertEqual(protocol.encode(cmd, seq, payload), frame)
            with self.assertRaises(ValueError):
                protocol.decode(frame[:-1] + bytes([frame[-1] ^ 1]))
        data = protocol.state(protocol.decode(bytes.fromhex(vectors["STATE"]))[2])
        self.assertEqual(data["xyz_normalized_micro"], [1000000, 2000000, 3000000])
        self.assertEqual((data["pitch_mdeg"], data["yaw_mdeg"]), (10000, -20000))
        self.assertEqual(data["servo_tick_us"], 999000)
        payload = bytearray(protocol.decode(bytes.fromhex(vectors["STATE"]))[2])
        struct.pack_into("<I", payload, 20, 0)
        self.assertIsNone(protocol.state(payload)["pitch_mdeg"])
        self.assertEqual(protocol.state(payload)["xyz_normalized_micro"], [None] * 3)


if __name__ == "__main__":
    unittest.main()

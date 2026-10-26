"""Exercise telemetry validation using in-memory sample cells, not camera evidence."""
import importlib.util
from pathlib import Path
import unittest

spec = importlib.util.spec_from_file_location(
    "dvp_decoder", Path(__file__).resolve().parents[1] / "src/decode_dvp_diagnostic.py")
decoder = importlib.util.module_from_spec(spec)
spec.loader.exec_module(decoder)


class DiagnosticTests(unittest.TestCase):
    """Reject black, ambiguous, wrong-schema and reserved-field inputs."""

    @staticmethod
    def paint_sample(data, x, y, color):
        """Populate only the decoder's 5x5 sampling region in a test buffer."""
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                start = ((y + dy) * 1280 + x + dx) * 3
                data[start:start + 3] = bytes(color)

    def fixture(self, payload="d64101a70006000302d0000a000b0a0000010101"):
        """Construct deterministic protocol samples independent of image files."""
        data = bytearray(1280 * 720 * 3)
        self.paint_sample(data, 640, 40, (255, 0, 255))
        self.paint_sample(data, 640, 680, (0, 255, 255))
        value = int(payload, 16)
        for index in range(160):
            level = 235 if value & (1 << (159 - index)) else 16
            self.paint_sample(data, 160 + 64 * (index % 16),
                              176 + 32 * (index // 16), (level,) * 3)
        return data

    def test_valid_is_not_camera(self):
        result = decoder.decode(self.fixture())
        self.assertEqual(result["first_bad_bytes"], 6)
        self.assertEqual(result["last_frame_rows"], 720)
        self.assertEqual(result["reason_name"], "short_line")
        self.assertFalse(result["camera_image_verified"])

    def test_black_and_wrong_size_rejected(self):
        for data in (b"", bytes(1280 * 720 * 3)):
            with self.assertRaises(ValueError):
                decoder.decode(data)

    def test_wrong_magic_and_reserved_flags_rejected(self):
        for payload in ("004101a70006000302d0000a000b0a0000010101",
                        "d64101a70006000302d0000a000b0a0000010103"):
            with self.assertRaises(ValueError):
                decoder.decode(self.fixture(payload))

    def test_ambiguous_cell_rejected(self):
        data = self.fixture()
        self.paint_sample(data, 160, 176, (128, 128, 128))
        with self.assertRaises(ValueError):
            decoder.decode(data)


if __name__ == "__main__":
    unittest.main()

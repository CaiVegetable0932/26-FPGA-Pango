"""Synthetic UART tests: no board, network, camera or Flash is opened."""
import importlib.util
import json
from pathlib import Path
import struct
import sys
import unittest

from pango_video.geometry_control import GeometryClient, GeometryError, GeometryProfile

ROOT = Path(__file__).resolve().parents[2]
PRESET = json.loads((ROOT/"host/config/calibration/fisheye-user-reviewed-20261002.json").read_text(encoding="utf-8"))


class FakeUart:
    """A session-bound device simulator, deliberately distinct from real UART I/O."""
    def __init__(self, *, supported=True, activate=True, fail=False):
        self.supported, self.activate, self.fail = supported, activate, fail
        self.version = self.shadow = 0
        self.words = [0]*14
        self.calls = []
        self.pending = False
        self.header = 0

    def exchange(self, command, payload=b""):
        """Record complete payloads and produce the documented 32-byte response."""
        self.calls.append((command, payload))
        result = bytearray(32)
        result[1] = command
        result[2] = 1
        struct.pack_into("<QI", result, 4, 123, 1)
        if command == 1:
            struct.pack_into("<I", result, 24, 0x80 if self.supported else 0)
        elif command == 0x30:
            self.shadow, model, enhance, width, height, reserved = struct.unpack_from("<IBBHHH", payload, 12)
            assert (width, height, reserved) == (1920, 1080, 0)
            self.header = model | (enhance << 2)
        elif command == 0x31:
            version, index, value = struct.unpack_from("<IIi", payload, 12)
            assert version == self.shadow
            self.words[index] = value
        elif command == 0x32:
            self.pending = True
        elif command == 0x33:
            if self.pending and self.activate and not self.fail:
                self.version = self.shadow
                self.pending = False
            struct.pack_into("<IQ", result, 20, self.version, 42 if self.version else 0)
        elif command == 0x34:
            index, bank = struct.unpack_from("<II", payload, 12)
            value = (self.words[index] & 0xffffffff) if index < 14 else self.header | (0x10 if self.pending else 0) | (0x20 if self.fail else 0)
            struct.pack_into("<III", result, 20, index, value, self.shadow if not bank else self.version)
        else:
            raise AssertionError("unexpected mutation")
        return bytes(result)


class GeometryControlTests(unittest.TestCase):
    """Verify exact coefficients, no legacy writes, retry and pending failures."""
    def test_matches_independent_fpga_encoder(self):
        # Purpose: compare separate host implementation against FPGA model at
        # test time only; production host never imports the FPGA development zone.
        spec = importlib.util.spec_from_file_location("test_fisheye_reference", ROOT/"fpga/model/fisheye_geometry_reference.py")
        module = importlib.util.module_from_spec(spec)
        sys.modules[spec.name] = module
        spec.loader.exec_module(module)
        try:
            for rotation in (0, -13, 27):
                self.assertEqual(GeometryProfile.from_preset(PRESET, rotation_deg=rotation).words,
                                 module.Lens(rotation_deg=rotation).words())
        finally:
            del sys.modules[spec.name]

    def test_upload_exact_word_and_active_readback(self):
        uart = FakeUart()
        profile = GeometryProfile.from_preset(PRESET)
        result = GeometryClient(uart).upload(profile)
        self.assertEqual(result["version"], 1)
        self.assertEqual(result["applied_source_frame_id"], 42)
        self.assertFalse(result["hardware_image_verified"])
        self.assertEqual(uart.words, list(profile.words))
        self.assertEqual(sum(cmd == 0x31 for cmd, _ in uart.calls), 14)
        # A retry must verify the active profile, without replaying its writes.
        uart.calls.clear()
        GeometryClient(uart).upload(profile, version=1)
        self.assertFalse(any(cmd in (0x30, 0x31, 0x32) for cmd, _ in uart.calls))

    def test_legacy_firmware_rejected_before_mutation(self):
        uart = FakeUart(supported=False)
        with self.assertRaises(GeometryError):
            GeometryClient(uart)
        self.assertEqual([cmd for cmd, _ in uart.calls], [1])

    def test_pending_timeout_not_claimed_as_success_and_resume(self):
        uart = FakeUart(activate=False)
        times = iter((0, .2))
        client = GeometryClient(uart, clock=lambda: next(times), sleep=lambda _: None)
        profile = GeometryProfile.from_preset(PRESET)
        with self.assertRaisesRegex(GeometryError, "尚未激活"):
            client.upload(profile, timeout=.1)
        uart.calls.clear()
        uart.activate = True
        GeometryClient(uart).upload(profile, version=1)
        self.assertFalse(any(cmd in (0x30, 0x31) for cmd, _ in uart.calls))

    def test_failed_table_and_active_conflict(self):
        uart = FakeUart(fail=True)
        with self.assertRaisesRegex(GeometryError, "构建失败"):
            GeometryClient(uart).upload(GeometryProfile.from_preset(PRESET))
        uart = FakeUart()
        client = GeometryClient(uart)
        profile = GeometryProfile.from_preset(PRESET)
        client.upload(profile)
        uart.words[0] += 1
        with self.assertRaisesRegex(GeometryError, "活动参数不一致"):
            client.upload(profile, version=1)

    def test_invalid_values_rejected_without_quantizing_nan(self):
        for name, value in (("fx", 0), ("k1", float("nan")), ("output_fov_deg", 200), ("cy", 5000)):
            preset = dict(PRESET["parameters"], **{name: value})
            with self.assertRaises(GeometryError):
                GeometryProfile.from_preset(preset)

    def test_explicit_invalid_word_rejected_before_begin(self):
        uart = FakeUart()
        profile = GeometryProfile(words=(0,)*13+(1 << 31,))
        with self.assertRaises(GeometryError):
            GeometryClient(uart).upload(profile)
        self.assertFalse(any(cmd in (0x30, 0x31, 0x32) for cmd, _ in uart.calls))


if __name__ == "__main__":
    unittest.main()

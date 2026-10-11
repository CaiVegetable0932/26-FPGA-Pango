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
    def test_performance_counts_physical_dvp_independently_of_results(self):
        # The input monitor includes rejected VSYNC intervals. Keep its 16-bit
        # counter, geometry and overflow data independent of result publication.
        class ChainUart(FakeUart):
            format_version = 1
            def exchange(self,command,payload=b''):
                if command in (7,8):
                    self.calls.append((command,payload))
                    reply=bytearray(32);reply[1:3]=bytes((command,1))
                    struct.pack_into('<QI',reply,4,123,1)
                    if command==7:
                        struct.pack_into('<5HBB',reply,20,65535,1080,1920,1920,0,3,self.format_version)
                    else:
                        struct.pack_into('<III',reply,20,123456,7,2)
                    return bytes(reply)
                reply=bytearray(super().exchange(command,payload))
                if command==1:struct.pack_into('<I',reply,24,0xc0)
                return bytes(reply)
        uart=ChainUart();result=GeometryClient(uart).performance()
        self.assertEqual(result['dvp_frame_count'],65535)
        self.assertEqual(result['dvp_low_lines'],1080)
        self.assertEqual(result['dvp_min_width'],1920)
        self.assertEqual(result['capture_rejected'],7)
        self.assertEqual(result['capture_overflows'],2)
        self.assertIsNotNone(result['dvp_counter_time'])
        self.assertTrue(all(command in (1,7,8,0x34) for command,_ in uart.calls))
        uart.format_version=2
        with self.assertRaisesRegex(GeometryError,'快照版本'):
            GeometryClient(uart).performance()

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

    def test_performance_reads_do_not_invent_a_completed_frame_on_tearing(self):
        # Simulate publication while UART reads the independent telemetry words.
        # The rate counter remains usable; a torn 64-bit identity must be null.
        class PerformanceUart(FakeUart):
            def __init__(self, moving=False):
                super().__init__()
                self.moving, self.count_reads = moving, 0

            def exchange(self, command, payload=b""):
                if command != 0x34:
                    return super().exchange(command, payload)
                self.calls.append((command, payload))
                index, bank = struct.unpack_from("<II", payload, 12)
                assert bank == 1
                if index == 22:
                    self.count_reads += 1
                values = {18:12345,19:800,20:3,21:2 << 9,22:100,
                          23:7,24:42,25:1,32:123,33:0}
                value = values[index] + int(index == 22 and self.moving and self.count_reads > 1)
                result = bytearray(32)
                result[1] = command
                struct.pack_into("<QI", result, 4, 123, 1)
                struct.pack_into("<III", result, 20, index, value, 7)
                return bytes(result)

        for moving in (False, True):
            uart = PerformanceUart(moving)
            result = GeometryClient(uart).performance()
            self.assertEqual(result["result_published"], 100)
            self.assertEqual(result["running_frame_cycles"], 12345)
            self.assertEqual(result["fault_bits"], 0)
            self.assertEqual(result["process_state"], 2)
            self.assertEqual(result["completed_identity_coherent"], not moving)
            self.assertEqual(result["completed_source_frame_id"], None if moving else str((1 << 32)+42))
            self.assertFalse(result["hardware_image_verified"])
            self.assertTrue(all(cmd in (1, 0x34) for cmd, _ in uart.calls))


if __name__ == "__main__":
    unittest.main()

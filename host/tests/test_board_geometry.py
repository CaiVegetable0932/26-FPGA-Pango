"""Offline view/API contracts with fake UART; no camera, PDS or board access."""
import http.client
import json
from pathlib import Path
import struct
import tempfile
import threading
from types import SimpleNamespace
import unittest

from pango_video.board_view import BoardViewClient
from pango_video.geometry_control import GeometryError, GeometryProfile
from pango_video.web_server import LocalServer
from test_geometry_control import FakeUart, PRESET


class ViewUart(FakeUart):
    """Firmware-shaped responses with controllable tearing, NACK and activation."""
    def __init__(self):
        super().__init__()
        self.view_caps = True
        self.view_revision, self.flags, self.diameter, self.generation = 0, 0, 10, 1
        self.moving = self.pending_view = self.reject = False
        self.closed = 0
        self.bad_mask = False
        self.marker_status = 1
        self.bad_version = False
        self.open_check = lambda: None

    def close(self):
        self.closed += 1

    def exchange(self, command, payload=b""):
        self.open_check()
        if command not in (0x34, 0x35) or (command == 0x34 and struct.unpack_from("<I", payload, 16)[0] != 2):
            result = bytearray(super().exchange(command, payload))
            if command == 1 and self.view_caps:
                struct.pack_into("<I", result, 24, 0x180)
            return bytes(result)
        self.calls.append((command, payload))
        assert payload[:12] == struct.pack("<QI", 123, 1)
        result = bytearray(32)
        result[1:3] = bytes((command, 1))
        struct.pack_into("<QI", result, 4, 123, 1)
        if command == 0x35:
            revision, flags, diameter = struct.unpack_from("<III", payload, 12)
            assert len(payload) == 24
            if self.reject:
                result[0] = 6
            elif not self.pending_view:
                self.view_revision, self.flags, self.diameter = revision, flags, diameter
                self.generation += 1
            struct.pack_into("<III", result, 20, revision, self.view_revision, self.flags | (self.diameter << 8))
        else:
            index, bank = struct.unpack_from("<II", payload, 12)
            if self.moving:
                self.generation += 1
            header = [0x4d4b5231, self.view_revision, self.flags | self.diameter << 8,
                      self.version, 1, self.generation, self.marker_status]
            if index < 7:
                value = header[index]
            else:
                marker, field = divmod(index-16, 5)
                value = [((marker+20) << 16) | marker+10, (-8192)&0xffffffff, 12288,
                         0xff3864, int(marker == 0 and not self.bad_mask)][field]
            struct.pack_into("<III", result, 20, index, value, self.version+int(self.bad_version))
        return bytes(result)


class BoardViewTests(unittest.TestCase):
    """Verify binary layouts and refusal to turn partial/unstable ACKs into success."""
    def test_view_exact_bytes_signed_metadata_and_identity(self):
        uart = ViewUart()
        result = BoardViewClient(uart).configure(mode="original", markers=True, diameter=32)
        self.assertEqual([p for c, p in uart.calls if c == 0x35], [struct.pack("<QIIII", 123, 1, 1, 3, 32)])
        self.assertEqual(result["points"][0], dict(id=1, source=[10, 20], destination=[-2, 3], color="#ff3864", visible=True))
        self.assertEqual(result["applied_revision"], 1)
        self.assertIsNone(result["source_frame_id"])
        self.assertEqual(result["pairing_status"], "unverified")
        self.assertFalse(result["hardware_image_verified"])

    def test_old_firmware_has_no_view_writes(self):
        uart = ViewUart()
        uart.view_caps = False
        with self.assertRaisesRegex(GeometryError, "0x100"):
            BoardViewClient(uart)
        self.assertEqual([c for c, _ in uart.calls], [1])

    def test_tearing_mask_and_nack_fail(self):
        for field in ("bad_mask", "reject", "bad_version"):
            uart = ViewUart()
            setattr(uart, field, True)
            with self.subTest(field=field), self.assertRaises(GeometryError):
                BoardViewClient(uart).configure(mode="corrected", markers=True)

    def test_unmarked_view_can_verify_mode_with_marker_mapping_failure(self):
        # An out-of-domain edge marker must not invalidate unmarked HDMI mode
        # or silently authorize the failed coordinate table.
        uart = ViewUart()
        uart.marker_status = 3
        client = BoardViewClient(uart)
        result = client.configure(mode="corrected", markers=False)
        self.assertTrue(result["view_verified"])
        self.assertFalse(result["metadata_verified"])
        self.assertEqual(result["mode"], "corrected")
        self.assertEqual(result["points"], [])
        self.assertIsNotNone(result["marker_error"])
        self.assertFalse(result["hardware_image_verified"])
        with self.assertRaises(GeometryError):
            client.markers()
        with self.assertRaises(GeometryError):
            client.configure(mode="corrected", markers=True)

    def test_view_header_rejects_tearing_lut_model_and_unknown_status(self):
        # Mode-only reads retain identity, readiness and core lens checks.
        for status in (0, 5, 9, 0x80000001):
            uart = ViewUart()
            uart.marker_status = status
            with self.subTest(status=status), self.assertRaises(GeometryError):
                BoardViewClient(uart).view_status()
        for field in ("moving", "bad_version"):
            uart = ViewUart()
            setattr(uart, field, True)
            with self.subTest(field=field), self.assertRaises(GeometryError):
                BoardViewClient(uart).view_status()

    def test_reset_error_status_and_generation_tearing_are_fail_closed(self):
        # Distinguish declared LUT/model/map errors from uninitialized display
        # state; none can be shown as a valid coordinate table.
        for status in (0, 3, 5, 9, 0x80000001):
            uart = ViewUart()
            uart.marker_status = status
            with self.subTest(status=status), self.assertRaises(GeometryError):
                BoardViewClient(uart).markers()
        for field, value in (("moving", True), ("generation", 0)):
            uart = ViewUart()
            setattr(uart, field, value)
            with self.subTest(field=field), self.assertRaises(GeometryError):
                BoardViewClient(uart).markers()

    def test_view_and_parameter_versions_are_distinct(self):
        uart = ViewUart()
        uart.version, uart.view_revision = 23, 7
        result = BoardViewClient(uart).markers()
        self.assertEqual((result["displayed_param_version"], result["revision"]), (23, 7))

    def test_pending_timeout_not_success(self):
        uart = ViewUart()
        uart.pending_view = True
        times = iter((0, 1))
        with self.assertRaisesRegex(GeometryError, "尚未应用"):
            BoardViewClient(uart, clock=lambda:next(times), sleep=lambda _:None).configure(
                mode="original", markers=False, timeout=.1)

    def test_invalid_fields_never_write(self):
        for data in (dict(mode="warp", markers=True), dict(mode="original", markers=1),
                     dict(mode="original", markers=True, diameter=33),
                     dict(mode="original", markers=True, revision=0)):
            uart = ViewUart()
            with self.subTest(data=data), self.assertRaises(GeometryError):
                BoardViewClient(uart).configure(**data)
            self.assertFalse(any(c == 0x35 for c, _ in uart.calls))

    def test_half_pixel_scaling_matches_canonical_source_point_center(self):
        # At the optical-axis output center sourcePoint returns the scaled K
        # principal point; non-native dimensions expose the previous half-pixel error.
        params = dict(PRESET["parameters"], reference_width=960, reference_height=540,
                      fx=385, fy=376, cx=472.25, cy=276.25)
        profile = GeometryProfile.from_preset(params)
        self.assertEqual(profile.words[10:14], tuple(round(v*65536) for v in (770, 752, 945, 553)))


class BoardGeometryApiTests(unittest.TestCase):
    """Exercise HTTP handlers, real BoardLink mutex and fake serial together."""
    def setUp(self):
        build = Path(__file__).resolve().parents[1]/"build"
        build.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="board-view-test-", dir=build)
        session = SimpleNamespace(root=Path(self.temp.name), status=lambda:dict(signal="live",
            config=dict(source_mode="hardware_unverified", stream_epoch="123")))
        self.server = LocalServer(0, session)
        self.link = self.server.board_link
        self.uart = ViewUart()
        self.link.profile = dict(port="fake", serial_number="board")
        self.link.state.update(phase="ready", epoch="123", session_id=1)
        self.link.ports = lambda:[dict(port="renumbered", serial="board")]
        self.link.uart = lambda port:self.uart
        # Every exchange, including CAPS/readback, must hold the actual link mutex.
        self.uart.open_check = lambda:self.assertTrue(self.link.uart_lock.locked())
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs=dict(poll_interval=.01), daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.temp.cleanup()

    def call(self, method, route, data=None, *, token=True):
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=5)
        headers = {"Content-Type":"application/json", "X-Pango-Token":self.server.token if token else ""}
        connection.request(method, route, None if data is None else json.dumps(data), headers)
        response = connection.getresponse()
        result = json.loads(response.read())
        connection.close()
        return response.status, result

    def test_routes_use_one_session_no_restart_and_token(self):
        self.assertEqual(self.call("POST", "/api/board/view", {}, token=False)[0], 403)
        self.assertEqual(self.uart.calls, [])
        code, result = self.call("POST", "/api/board/geometry", dict(preset=PRESET))
        self.assertEqual(code, 200, result)
        self.assertTrue(result["parameters_verified"])
        self.assertEqual(self.call("GET", "/api/board/geometry")[1]["version"], 1)
        code, result = self.call("POST", "/api/board/view", dict(mode="original", markers=True))
        self.assertEqual(code, 200, result)
        self.assertEqual(result["displayed_param_version"], 1)
        self.assertEqual(self.call("GET", "/api/board/markers")[1]["revision"], 1)
        self.assertFalse(any(c in (2, 0x71) for c, _ in self.uart.calls))
        self.assertEqual(self.uart.closed, 4)
        self.assertFalse(self.link.uart_lock.locked())

    def test_busy_unknown_fields_epoch_and_old_firmware_fail(self):
        with self.link.uart_lock:
            self.assertEqual(self.call("POST", "/api/board/view", dict(mode="original", markers=True))[0], 409)
        self.assertEqual(self.uart.calls, [])
        self.assertEqual(self.call("POST", "/api/board/view", dict(mode="original", markers=True, flags=8))[0], 409)
        self.link.state["session_id"] = 2
        self.assertNotEqual(self.call("GET", "/api/board/markers")[0], 200)
        self.assertFalse(self.link.uart_lock.locked())
        self.link.state["session_id"] = 1
        self.uart.view_caps = False
        code, result = self.call("POST", "/api/board/view", dict(mode="original", markers=True))
        self.assertNotEqual(code, 200)
        self.assertIn("0x100", result["error"])

    def test_unconfigured_board_does_not_open_hardware(self):
        # Unconfigured mode queries also cannot open a physical UART.
        self.link.state.update(phase="idle")
        self.assertNotEqual(self.call("GET", "/api/board/view")[0], 200)
        self.assertEqual(self.uart.calls, [])
        self.link.state.update(phase="idle")
        code, result = self.call("GET", "/api/board/markers")
        self.assertNotEqual(code, 200)
        self.assertIn("启动", result["error"])
        self.assertEqual(self.uart.calls, [])

    def test_view_header_route_keeps_marker_failure_explicit(self):
        # Mode proof uses the live UART lock; strict coordinates still reject
        # the real RGB33 edge-marker failure shape and never restart the stream.
        self.uart.marker_status = 3
        code, result = self.call("GET", "/api/board/view")
        self.assertEqual(code, 200, result)
        self.assertTrue(result["view_verified"])
        self.assertFalse(result["metadata_verified"])
        self.assertEqual(result["points"], [])
        self.assertIsNotNone(result["marker_error"])
        self.assertNotEqual(self.call("GET", "/api/board/markers")[0], 200)
        self.assertFalse(self.link.uart_lock.locked())
        self.assertFalse(any(c in (2, 0x71, 0x35) for c, _ in self.uart.calls))

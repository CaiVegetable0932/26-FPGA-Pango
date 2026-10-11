"""Synthetic power/session recovery; no physical UART, camera, OS or Flash access."""
import http.client
import json
from pathlib import Path
import struct
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from pango_video.board_autoload import BoardAutoLoader, DEFAULTS
from pango_video.board_link import BoardLink, atomic_json
from pango_video.cli import HOST_ROOT
from pango_video.geometry_control import GeometryProfile
from pango_video.web_server import LocalServer
from pango_video.web_session import SessionError
from test_board_geometry import ViewUart
from test_board_link import Session


class PowerUart(ViewUart):
    """Combine boot commissioning with the existing geometry/view UART simulator."""
    def __init__(self, events):
        super().__init__()
        self.events, self.records, self.wire_calls = events, [], []
        self.powered = True
        self.epoch = self.session = 0
        self.capabilities = 0x180
        self.flags = 1
        self.on_command = lambda command:None

    def reset(self):
        """Model a new volatile FPGA boot, retaining the same USB bridge identity."""
        self.epoch = self.session = self.version = self.shadow = 0
        self.words, self.header, self.pending = [0]*14, 0, False
        self.view_revision, self.flags, self.generation = 0, 1, 1

    def exchange(self, command, payload=b""):
        """Use dynamic real contexts while delegating geometry to the golden fake."""
        if not self.powered:
            raise SessionError("UART 2 秒内无有效回复：模拟 FPGA 未上电")
        self.wire_calls.append((command, payload))
        self.records.append(dict(command=command, payload=payload.hex()))
        self.on_command(command)
        if command in (1, 2, 3, 0x71):
            result = bytearray(32)
            result[1] = command
            if command == 1:
                if not self.epoch:
                    result[0], result[20:24] = 6, b"RAW8"
                else:
                    result[2] = int(bool(self.session))
                    struct.pack_into("<I", result, 24, self.capabilities)
            elif command == 0x71:
                assert not self.epoch, "warm boot must never be recommissioned"
                assert "bind" in self.events, "receiver must precede RAW8 boot"
                self.epoch = int.from_bytes(payload[:8], "little")
                result[20:24] = b"RAW8"
            elif command == 2:
                self.session = int.from_bytes(payload[8:12], "little")
            else:
                struct.pack_into("<I", result, 20, 256 | 512 | 2 | 4)
            struct.pack_into("<QI", result, 4, self.epoch, self.session)
            return bytes(result)
        assert payload[:12] == struct.pack("<QI", self.epoch, self.session)
        normalized = struct.pack("<QI", 123, 1) + payload[12:]
        result = bytearray(super().exchange(command, normalized))
        struct.pack_into("<QI", result, 4, self.epoch, self.session)
        return bytes(result)


class AutoRecoveryTests(unittest.TestCase):
    """Run the actual commissioning/uploader against a controlled fake power cycle."""
    def setUp(self):
        build = HOST_ROOT / "build"
        build.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="autoload-test-", dir=build)
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.events, self.now = [], 0
        self.session = Session(self.root, self.events)
        self.board = PowerUart(self.events)
        self.cards = [dict(name="ethernet", ip="192.168.80.2", prefix=24, mac="02:11:22:33:44:55")]
        self.ports = [dict(port="CP2102", serial="unit1")]
        self.profile = dict(port="CP2102", serial_number="unit1", interface="ethernet",
                            source_ip="192.168.80.3", source_mac="02:00:00:00:00:01", auto_start=True)
        # Explicit UTF-8 keeps the same Chinese preset valid on Windows and Jetson.
        self.preset = json.loads((HOST_ROOT / "config/calibration/fpga-fisheye-rgb33-20261010.json").read_text(encoding="utf-8"))
        atomic_json(self.root / DEFAULTS["preset_path"], self.preset)
        atomic_json(self.root / "config/board-link.json", self.profile)
        self.link, self.auto = self.make_pair()
        self.addCleanup(lambda:self.auto.close())

    def make_pair(self):
        """A new coordinator shares only persisted endpoints, not Python restore caches."""
        link = BoardLink(self.session, inventory=lambda:self.cards, ports=lambda:self.ports,
                         uart=lambda port:self.board)
        return link, BoardAutoLoader(link, clock=lambda:self.now)

    def enable(self, **changes):
        """Persist opt-in with the same production validation path as the HTTP UI."""
        self.auto.configure(dict(DEFAULTS, enabled=True, **changes))

    def connect(self):
        """Wait only for the fake startup worker; no wall-clock camera wait is used."""
        self.auto.tick()
        if self.link.thread:
            self.link.thread.join(3)
            self.assertFalse(self.link.thread.is_alive())
        self.now += 31
        self.auto.tick()

    def commands(self):
        """Inspect actual context-bearing wire requests, not normalized golden inputs."""
        return [command for command, _ in self.board.wire_calls]

    def test_cold_boot_upload_and_hdmi_confirmation_keep_source_unverified(self):
        self.enable()
        self.connect()
        state = self.auto.status()
        self.assertEqual(state["phase"], "ready", state)
        self.assertEqual(self.commands().count(0x71), 1)
        self.assertEqual(self.commands().count(0x31), 14)
        self.assertEqual((state["active_version"], state["displayed_version"]), (1, 1))
        self.assertEqual(self.board.words, list(GeometryProfile.from_preset(self.preset).words))
        self.assertIsNone(state["source_frame_id"])
        self.assertEqual(state["pairing_status"], "unverified")
        self.assertFalse(state["hardware_image_verified"])
        record = json.loads(self.auto.report.read_text(encoding="utf-8").splitlines()[-1])
        self.assertTrue(record["uploaded"])
        self.assertEqual(len(record["words"]), 14)
        self.assertTrue(record["uart"])

    def test_default_watch_only_connects_never_uploads_parameters(self):
        self.connect()
        self.assertEqual(self.auto.status()["phase"], "disabled")
        self.assertNotIn(0x30, self.commands())
        self.assertNotIn(0x35, self.commands())

    def test_host_first_board_later_and_present_bridge_are_not_false_power_proof(self):
        self.enable()
        self.board.powered = False
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "error")
        self.assertEqual(self.board.epoch, 0)
        self.assertFalse(self.commands())
        self.board.powered = True
        self.now += 31
        self.connect()
        self.assertEqual(self.auto.status()["phase"], "ready")

    def test_warm_host_restart_compares_words_and_does_not_reupload_or_reboot(self):
        self.enable()
        self.connect()
        epoch, version = self.board.epoch, self.board.version
        self.auto.close()
        self.link, self.auto = self.make_pair()
        self.board.wire_calls.clear()
        self.connect()
        self.assertEqual(self.auto.status()["phase"], "ready")
        self.assertEqual((self.board.epoch, self.board.version), (epoch, version))
        self.assertFalse(any(c in (0x71, 0x30, 0x31, 0x32, 0x35) for c in self.commands()))
        self.assertFalse(self.auto.status()["uploaded"])

    def test_repeated_polls_are_read_only_until_a_power_cycle(self):
        self.enable()
        self.connect()
        first = self.board.epoch
        self.board.wire_calls.clear()
        for _ in range(4):
            self.auto.tick()
        self.assertEqual(self.commands(), [1]*4)
        self.board.reset()
        self.session.live = False
        self.connect()
        self.assertNotEqual(first, self.board.epoch)
        self.assertEqual(self.commands().count(0x31), 14)
        self.assertEqual(self.auto.status()["phase"], "ready")

    def test_transient_disconnect_revokes_stale_proof_then_readbacks_without_upload(self):
        # A powered USB bridge is not proof after UART loss; the same warm FPGA
        # can recover by readback, without a second boot or parameter upload.
        self.enable()
        self.connect()
        self.board.powered = False
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "error")
        self.assertIsNone(self.auto.status()["active_version"])
        self.assertIsNone(self.auto.status()["displayed_version"])
        self.board.powered = True
        self.board.wire_calls.clear()
        self.now += 31
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "ready")
        self.assertFalse(any(c in (0x71, 0x30, 0x31, 0x32, 0x35) for c in self.commands()))

    def test_background_thread_restores_without_a_browser_or_http_request(self):
        # Drive only the daemon's wake signal; never call tick or visit the page.
        self.enable()
        self.auto.start()
        deadline = time.monotonic() + 3
        while self.auto.status()["phase"] != "ready" and time.monotonic() < deadline:
            self.auto.wake.set()
            time.sleep(.01)
        self.assertEqual(self.auto.status()["phase"], "ready", self.auto.status())
        self.auto.close()
        self.assertFalse(self.auto.thread.is_alive())

    def test_manual_controls_are_preserved_until_new_boot_or_explicit_setting_save(self):
        self.enable()
        self.connect()
        self.auto.manual_override()
        self.board.words[0] += 1
        self.board.flags = 1
        self.board.wire_calls.clear()
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "manual")
        self.assertEqual(self.commands(), [1])
        self.board.reset()
        self.connect()
        self.assertEqual(self.auto.status()["phase"], "ready")

    def test_stop_revokes_mid_upload_before_commit_and_does_not_autorestart(self):
        self.enable()
        self.auto.tick()
        self.link.thread.join(3)
        self.board.on_command = lambda c:self.auto.pause() if c == 0x31 else None
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "paused")
        self.assertNotIn(0x32, self.commands())
        self.assertEqual(self.board.version, 0)
        self.board.wire_calls.clear()
        self.auto.tick()
        self.assertFalse(self.commands())

    def test_busy_uart_does_not_interleave_or_count_as_failed_restore(self):
        self.enable()
        with self.link.uart_lock:
            self.auto.tick()
        self.assertFalse(self.commands())
        self.assertEqual(self.auto.status()["retries"], 0)

    def test_camera_wait_and_nonphysical_receiver_are_not_replaced(self):
        self.enable()
        self.connect()
        self.auto.applied = None
        self.session.live = False
        self.link.state["board"] = dict(sensor_ready=False, frame_published=False)
        self.board.wire_calls.clear()
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "waiting")
        self.assertEqual(self.commands(), [1])
        self.session.live = True
        self.session.config["source_mode"] = "mock"
        self.board.wire_calls.clear()
        self.auto.tick()
        self.assertFalse(self.commands())
        self.assertTrue(self.session.live)

    def test_unknown_warm_endpoints_back_off_without_board_writes(self):
        self.enable()
        self.board.epoch, self.board.session = 999, 1
        self.auto.tick()
        self.link.thread.join(3)
        self.auto.tick()
        state = self.auto.status()
        self.assertEqual(state["phase"], "error")
        self.assertEqual(state["retries"], 1)
        self.assertGreater(state["retry_in_seconds"], 0)
        self.assertNotIn(0x71, self.commands())
        self.assertNotIn(0x30, self.commands())
        calls = len(self.commands())
        self.auto.tick()
        self.assertEqual(len(self.commands()), calls)

    def test_configuration_validates_path_types_model_and_ranges_before_any_write(self):
        for change in (dict(preset_path="../outside.json"), dict(preset_path="/tmp/x.json"),
                       dict(preset_path="config/board-link.json"), dict(enabled=1),
                       dict(mode="fish"), dict(diameter=True), dict(rotation_deg=float("nan")), dict(unknown=1)):
            with self.subTest(change=change), self.assertRaises((ValueError, OSError)):
                self.auto.configure(dict(DEFAULTS, **change))
        self.assertFalse(self.commands())
        self.assertFalse(self.auto.path.exists())
        atomic_json(self.root / DEFAULTS["preset_path"], dict(parameters=dict(model="pinhole")))
        with self.assertRaises(ValueError):
            self.enable()
        self.assertFalse(self.commands())

    def test_old_firmware_and_parameter_tamper_never_issue_geometry_writes(self):
        self.enable()
        self.auto.tick()
        self.link.thread.join(3)
        self.board.capabilities = 0
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "error")
        self.assertNotIn(0x30, self.commands())
        self.now += 31
        self.board.capabilities = 0x180
        (self.root / DEFAULTS["preset_path"]).write_text("broken", encoding="utf-8")
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "error")
        self.assertNotIn(0x30, self.commands())

    def test_unmarked_mode_preserves_fd3335ab_marker_failure_behavior(self):
        self.enable()
        self.board.marker_status = 3
        self.connect()
        self.assertEqual(self.auto.status()["phase"], "ready")
        self.assertEqual(self.board.flags, 0)

    def test_bad_display_version_is_not_ready_even_after_parameter_activation(self):
        self.enable()
        self.auto.tick()
        self.link.thread.join(3)
        self.board.bad_version = True
        self.auto.tick()
        self.assertEqual(self.auto.status()["phase"], "error")
        self.assertEqual(self.auto.status()["active_version"], 1)
        self.assertIsNone(self.auto.status()["displayed_version"])

    def test_settings_persist_and_readonly_preset_import_never_opens_uart(self):
        self.enable(mode="original", rotation_deg=3)
        value = self.auto.preset()
        self.assertEqual(value["preset"]["parameters"], self.preset["parameters"])
        self.assertFalse(self.commands())
        _, second = self.make_pair()
        self.assertEqual(second.settings["rotation_deg"], 3)
        self.assertEqual(second.settings["mode"], "original")
        self.assertFalse(second.paused)


class AutoRecoveryHTTPTests(unittest.TestCase):
    """Token-protected settings and server lifecycle in an isolated empty checkout."""
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(prefix="autoload-http-", dir=HOST_ROOT / "build")
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name)
        self.session = Session(self.root, [])
        # Presets have an explicit UTF-8 encoding, independent of the OS locale.
        preset = json.loads((HOST_ROOT / "config/calibration/fpga-fisheye-rgb33-20261010.json").read_text(encoding="utf-8"))
        atomic_json(self.root / DEFAULTS["preset_path"], preset)
        self.server = LocalServer(0, self.session)
        # No saved port exists: enabling must not discover/choose a real board.
        self.server.board_link.ports = lambda:[]
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs=dict(poll_interval=.01), daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(3)
        self.assertFalse(self.server.board_autoload.thread.is_alive())

    def call(self, method, data=None, *, token=True, route="/api/board/autoload"):
        """Exercise actual loopback security and JSON handlers, not a router mock."""
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            headers = {"Content-Type":"application/json"}
            if token:
                headers["X-Pango-Token"] = self.server.token
            connection.request(method, route, None if data is None else json.dumps(data), headers)
            response = connection.getresponse()
            return response.status, json.loads(response.read())
        finally:
            connection.close()

    def test_settings_require_token_and_expose_truthful_unapplied_state(self):
        self.assertEqual(self.call("POST", dict(DEFAULTS, enabled=True), token=False)[0], 403)
        code, result = self.call("POST", dict(DEFAULTS, enabled=True))
        self.assertEqual(code, 200)
        self.assertTrue(result["settings"]["enabled"])
        self.assertIsNone(result["active_version"])
        self.assertFalse(result["hardware_image_verified"])
        self.assertEqual(self.call("POST", dict(DEFAULTS, preset_path="../bad.json"))[0], 409)

    def test_preset_get_and_disabled_status_are_read_only(self):
        code, result = self.call("GET")
        self.assertEqual(code, 200)
        self.assertFalse(result["settings"]["enabled"])
        code, result = self.call("GET", route="/api/board/autoload/preset")
        self.assertEqual(code, 200)
        self.assertEqual(result["preset"]["parameters"]["output_fov_deg"], 100)
        self.assertFalse(result["uploaded"])


if __name__ == "__main__":
    unittest.main()

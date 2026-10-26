"""Exercise commissioning order/recovery with synthetic UART and UDP owners."""
import json
from pathlib import Path
import struct
import tempfile
import unittest
from types import SimpleNamespace
from unittest.mock import patch

from pango_video.board_link import BoardLink, Uart, interfaces
from pango_video.raw8_boot import crc16
from pango_video.web_session import SessionError


class Session:
    """Stand-in records ownership order; it never opens a real network socket."""
    def __init__(self, root, events):
        self.root, self.events = Path(root), events
        self.live = False
        self.bind_error = False

    def start(self, **kwargs):
        if self.bind_error:
            raise SessionError("UDP bind failed")
        self.events.append("bind")
        self.config = kwargs["config"]
        assert kwargs["auto_mock"] is False
        self.live = True

    def stop(self):
        self.events.append("stop")
        self.live = False

    def status(self):
        return dict(signal="live" if self.live else "stopped", config=getattr(self, "config", {}))


class FakeBoard:
    """Model the RTL's cold RAW8 NACK, immutable boot and live session replies."""
    def __init__(self, events):
        self.events, self.records = events, []
        self.epoch = self.session = 0
        self.lose_ack = False
        self.closed = False

    def close(self):
        self.closed = True

    def exchange(self, command, payload=b""):
        self.events.append(command)
        result = bytearray(32)
        result[1] = command
        if not self.epoch and command == 1:
            result[0] = 6
            result[20:24] = b"RAW8"
            return result
        if command == 0x71:
            assert not self.epoch, "must never commission a warm board"
            assert "bind" in self.events, "receiver must open first"
            self.epoch = int.from_bytes(payload[:8], "little")
            result[20:24] = b"RAW8"
            if self.lose_ack:
                self.lose_ack = False
                raise SessionError("lost ACK")
        elif command == 2:
            self.session = int.from_bytes(payload[8:12], "little")
        elif command == 3:
            result[20:24] = struct.pack("<I", 256 | 512)
        result[4:12] = struct.pack("<Q", self.epoch)
        result[12:16] = struct.pack("<I", self.session)
        return result


class BoardLinkTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.events = []
        self.session = Session(self.tmp.name, self.events)
        self.board = FakeBoard(self.events)
        self.cards = [dict(name="ethernet", ip="192.168.80.2", prefix=24, mac="02:11:22:33:44:55")]
        self.link = self.make_link()
        self.profile = dict(port="CP2102", interface="ethernet", source_ip="192.168.80.3",
                            source_mac="02:00:00:00:00:01", auto_start=True)

    def make_link(self):
        return BoardLink(self.session, inventory=lambda:self.cards,
                         ports=lambda:[dict(port="CP2102")], uart=lambda port:self.board)

    def run_link(self, profile=None):
        self.link.start(profile or self.profile)
        self.link.thread.join(3)
        self.assertFalse(self.link.thread.is_alive())
        return self.link.status()

    def test_cold_boot_order_and_fresh_epoch(self):
        result = self.run_link()
        self.assertEqual(result["phase"], "ready")
        self.assertLess(self.events.index("bind"), self.events.index(0x71))
        self.assertEqual(self.session.config["stream_epoch"], self.board.epoch)
        first = self.board.epoch
        self.board.epoch = self.board.session = 0
        self.run_link()
        self.assertNotEqual(first, self.board.epoch)
        self.assertTrue(self.board.closed)

    def test_warm_host_restart_reuses_epoch_without_recommissioning(self):
        self.run_link()
        epoch = self.board.epoch
        self.events.clear()
        self.link = self.make_link()
        self.assertEqual(self.run_link()["phase"], "ready")
        self.assertNotIn(0x71, self.events)
        self.assertEqual(self.board.epoch, epoch)

    def test_lost_boot_ack_recovers_saved_intent(self):
        self.board.lose_ack = True
        self.assertEqual(self.run_link()["phase"], "error")
        epoch = self.board.epoch
        self.events.clear()
        self.assertEqual(self.run_link()["phase"], "ready")
        self.assertEqual(self.board.epoch, epoch)
        self.assertNotIn(0x71, self.events)

    def test_warm_endpoint_change_requires_cold_boot(self):
        self.run_link()
        self.events.clear()
        changed = dict(self.profile, source_ip="192.168.80.4")
        self.assertEqual(self.run_link(changed)["phase"], "error")
        self.assertNotIn(0x71, self.events)

    def test_ethernet_defaults_replace_bad_preferences_and_reuse_warm_epoch(self):
        """Reset repairs saved host parameters without recommissioning the FPGA."""
        self.run_link()
        epoch = self.board.epoch
        self.link.profile.update(interface="wrong", source_ip="10.0.0.3", source_mac="bad",
                                 peer_port=12345, source_port=23456)
        self.events.clear()
        self.link.reset_ethernet()
        self.link.thread.join(3)
        self.assertEqual(self.link.status()["phase"], "ready")
        self.assertEqual(self.board.epoch, epoch)
        self.assertNotIn(0x71, self.events)
        self.assertEqual(self.link.profile["interface"], "ethernet")
        self.assertEqual(self.link.profile["source_ip"], "192.168.80.3")
        self.assertEqual(self.link.profile["peer_port"], 50000)
        self.assertEqual(self.link.profile["source_port"], 50001)
        self.assertTrue(self.link.profile["auto_start"])
        self.assertEqual(json.loads(self.link.path.read_text()), self.link.profile)

    def test_ethernet_reset_missing_or_ambiguous_defaults_keeps_live_receiver(self):
        """Discovery errors must not stop an already functioning stream."""
        self.run_link()
        saved = self.link.path.read_text()
        for cards in ([], self.cards * 2, [dict(self.cards[0], prefix=32)]):
            self.cards = cards
            self.events.clear()
            with self.assertRaises(SessionError):
                self.link.reset_ethernet()
            self.assertTrue(self.session.live)
            self.assertEqual(self.events, [])
            self.assertEqual(self.link.path.read_text(), saved)

    def test_ethernet_reset_respects_immutable_foreign_endpoints(self):
        """A warm board using other addresses is not silently overwritten."""
        self.run_link(dict(self.profile, source_ip="192.168.80.4"))
        boot = self.link.boot_path.read_text()
        self.events.clear()
        self.link.reset_ethernet()
        self.link.thread.join(3)
        self.assertEqual(self.link.status()["phase"], "error")
        self.assertTrue(self.session.live)
        self.assertNotIn("stop", self.events)
        self.assertNotIn(0x71, self.events)
        self.assertEqual(self.link.boot_path.read_text(), boot)
        self.assertEqual(self.link.profile["source_ip"], "192.168.80.4")

    def test_ethernet_reset_follows_saved_serial_and_blocks_busy_or_missing_board(self):
        """USB renumbering cannot select a different CP2102 or race startup."""
        self.link.ports = lambda:[dict(port="CP2102", serial="unit1")]
        self.run_link()
        self.events.clear()
        self.link.ports = lambda:[dict(port="other", serial="unit2")]
        with self.assertRaises(SessionError):
            self.link.reset_ethernet()
        self.assertEqual(self.events, [])
        self.link.ports = lambda:[dict(port="other", serial="unit2"), dict(port="renumbered", serial="unit1")]
        self.link.reset_ethernet()
        self.link.thread.join(3)
        self.assertEqual(self.link.profile["port"], "renumbered")
        self.assertEqual(self.link.status()["phase"], "ready")
        self.link.thread = SimpleNamespace(is_alive=lambda:True)
        with self.assertRaises(SessionError):
            self.link.reset_ethernet()

    def test_unknown_warm_epoch_does_not_send_boot(self):
        self.board.epoch = 123
        self.assertEqual(self.run_link()["phase"], "error")
        self.assertNotIn(0x71, self.events)

    def test_bad_network_prevents_uart_and_port_conflict_prevents_boot(self):
        result = self.run_link(dict(self.profile, source_ip="10.0.0.3"))
        self.assertEqual(result["phase"], "error")
        self.assertEqual(self.events, [])
        self.session.bind_error = True
        self.assertEqual(self.run_link()["phase"], "error")
        self.assertNotIn(0x71, self.events)

    def test_stale_ready_is_not_live(self):
        self.run_link()
        self.session.live = False
        self.assertEqual(self.link.status()["phase"], "waiting")
        self.link.stop()
        self.assertEqual(self.link.status()["phase"], "stopped")

    def test_mock_receiver_cannot_make_board_ready(self):
        """A later explicit mock run must not inherit physical readiness."""
        self.run_link()
        self.session.config["source_mode"] = "mock"
        self.assertEqual(self.link.status()["phase"], "waiting")

    def test_serial_renumber_uses_saved_unique_usb_identity(self):
        """Host restart can find the same CP2102 at a different OS port name."""
        self.link.ports = lambda:[dict(port="CP2102", serial="unit1")]
        self.run_link()
        self.link = self.make_link()
        self.link.ports = lambda:[dict(port="/dev/ttyUSB1", serial="unit1")]
        self.link.start()
        self.link.thread.join(3)
        self.assertEqual(self.link.status()["phase"], "ready")
        self.assertEqual(self.link.profile["port"], "/dev/ttyUSB1")

    def test_uart_crc_resynchronizes_and_matches_sequence(self):
        """A corrupt/stale reply cannot supply a false boot acknowledgement."""
        class Wire:
            def reset_input_buffer(inner): pass
            def write(inner, wire):
                self.assertEqual(crc16(wire[2:-2]), int.from_bytes(wire[-2:], "little"))
                reply = bytearray(32)
                reply[1] = wire[3]
                body = b"\x01\x80" + wire[4:6] + b"\x20\x00" + reply
                good = b"\x55\xaa" + body + struct.pack("<H", crc16(body))
                stale = bytearray(good)
                stale[4] ^= 1
                inner.buffer = b"noise" + stale + good
            def read(inner, count):
                out, inner.buffer = inner.buffer[:7], inner.buffer[7:]
                return out
        uart = Uart.__new__(Uart)
        uart.link, uart.sequence, uart.records = Wire(), 0, []
        self.assertEqual(uart.exchange(1)[1], 1)
        self.assertEqual(len(uart.records), 1)


class LinuxInterfaceTests(unittest.TestCase):
    def test_actual_mac_and_ipv4_survive_family_filtering(self):
        """Keep a real NIC's IPv4/MAC pair while excluding loopback and IPv6.

        Model iproute2's observed Jetson behavior: -4 removes MAC fields, so
        the previous invocation returns no usable physical interfaces.
        """
        rows = [dict(ifname="lo", address="00:00:00:00:00:00",
                     addr_info=[dict(family="inet", local="127.0.0.1", prefixlen=8)]),
                dict(ifname="enP8p1s0", address="3c:6d:66:b5:44:6b", addr_info=[
                    dict(family="inet", local="192.168.80.2", prefixlen=24),
                    dict(family="inet6", local="fe80::1", prefixlen=64)])]

        def ip_output(command, **kwargs):
            output = [dict(row) for row in rows]
            if "-4" in command:
                for row in output:
                    row.pop("address", None)
            return SimpleNamespace(stdout=json.dumps(output))

        with patch("pango_video.board_link.sys.platform", "linux"), patch(
                "pango_video.board_link.subprocess.run", side_effect=ip_output):
            self.assertEqual(interfaces(), [dict(name="enP8p1s0", ip="192.168.80.2",
                                                prefix=24, mac="3c:6d:66:b5:44:6b")])


if __name__ == "__main__":
    unittest.main()

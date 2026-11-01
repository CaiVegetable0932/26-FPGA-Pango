"""Exercise V2 handshake, actual payload layouts, context and motion rejection."""
import struct
import sys
from types import SimpleNamespace
import unittest
from unittest.mock import patch
import mcu_pose_v2 as wire
from pango_video.mcu_control import MCUControl


class Device:
    """In-memory firmware peer; packet boundaries intentionally split on reads."""
    def __init__(self, **options):
        self.output = bytearray()
        self.requests = []
        self.reject = False
        self.bad_context = False
        self.packets = []
        self.defer_zero = False
        self.busy_status = False

    def write(self, packet):
        cmd, seq, payload = wire.decode(packet)
        self.requests.append((cmd, payload))
        self.packets.append(packet)
        session = 0 if cmd == 0x40 else struct.unpack_from('<I', payload, 0 if cmd == 0x41 else 8)[0]
        data = b''
        if cmd == 0x40:
            data = bytearray(48)
            struct.pack_into('<Q', data, 0, 99)
            struct.pack_into('<H', data, 14, 0x4d32)
        elif cmd == 0x41:
            data = struct.pack('<II', 1, 7)
        elif cmd == 0x43:
            data = struct.pack('<HH', 0, 0)
        elif cmd == 0x44:
            data = bytearray(96)
            struct.pack_into('<QIIII', data, 0, 42, session, 1, 1, 0x58)
            struct.pack_into('<ii', data, 52, 1234, -5678)
            struct.pack_into('<I', data, 80, 7)
        elif cmd in (0x46, 0x48):
            data = payload[12:16]
        elif cmd == 0x4a:
            if self.defer_zero:
                return
            data = struct.pack('<Iii', 2, 0, 0)
        elif cmd == 0x49:
            data = payload[12:16]
        result = 7 if self.reject and cmd == 0x46 else 1 if cmd in (0x46, 0x48) else 0
        if cmd == 0x44 and self.busy_status:
            result = 2
        body = struct.pack('<QIBBH', 43 if self.bad_context else 42, session, cmd, result, 0)
        self.output.extend(wire.encode(0x80, seq, body + (b'' if result == 7 else data)))

    def read(self, size):
        data = bytes(self.output[:7]);del self.output[:7]
        return data

    def close(self):
        pass


class MCUChecks(unittest.TestCase):
    def setUp(self):
        self.device = Device()
        self.control = MCUControl(lambda **options: self.device)
        self.control.connect('test-mcu')
        self.control.stop.set()
        self.control.thread.join(1)

    def tearDown(self):
        self.control.close()

    def test_feedback_and_motion_wire_layout(self):
        self.assertEqual(self.control.status()['angles'], dict(pitch=1.234, yaw=-5.678))
        self.control.action('move', dict(pitch=12, yaw=-60))
        cmd, payload = self.device.requests[-1]
        self.assertEqual((cmd, len(payload)), (0x46, 48))
        self.assertEqual(payload[16:20], b'\x18\0\0\0')
        self.assertEqual(struct.unpack_from('<5i', payload, 20), (0, 0, 0, 12000, -60000))
        self.assertEqual(struct.unpack_from('<I', payload, 12)[0], 8)
        self.control.action('home', {})
        self.assertEqual((self.device.requests[-1][0], len(self.device.requests[-1][1])), (0x48, 20))

    def test_three_degree_targets_preserve_fine_feedback(self):
        """Check every allowed target on the wire, then read non-grid feedback."""
        for target in range(-60, 61, 3):
            self.control.action('move', dict(pitch=target, yaw=-target))
            payload = self.device.requests[-1][1]
            self.assertEqual(struct.unpack_from('<ii', payload, 32), (target * 1000, -target * 1000))
        state = self.control.action('read', {})
        self.assertEqual(state['angles'], dict(pitch=1.234, yaw=-5.678))
        self.assertEqual((state['state']['pitch_mdeg'], state['state']['yaw_mdeg']), (1234, -5678))

    def test_invalid_and_rejected_targets_never_report_success(self):
        count = len(self.device.requests)
        # Reject off-grid inputs on either axis before serial writes or motion IDs.
        motion = self.control.motion
        for value in (61, float('nan'), True, '1', 1, -2, 12.345, 3.0001, -0.001):
            for axis in ('pitch', 'yaw'):
                with self.assertRaises(ValueError):
                    self.control.action('move', dict(dict(pitch=0, yaw=0), **{axis:value}))
        self.assertEqual(len(self.device.requests), count)
        self.assertEqual(self.control.motion, motion)
        self.device.reject = True
        with self.assertRaisesRegex(ValueError, 'NOT_READY'):
            self.control.action('move', dict(pitch=3, yaw=6))

    def test_wrong_context_is_rejected(self):
        self.device.bad_context = True
        self.control.query_after = 0
        with self.assertRaisesRegex(ValueError, '身份'):
            self.control.action('read', {})

    def test_fpga_port_cannot_be_opened_as_mcu(self):
        other = MCUControl(lambda **options: self.fail('must not open serial'))
        with self.assertRaisesRegex(ValueError, 'FPGA'):
            other.connect('/dev/ttyUSB0', '/dev/ttyUSB0')

    def test_zero_is_async_and_blocks_competing_motion(self):
        """The HTTP-facing operation returns pending, then consumes its final seq."""
        state = self.control.action('zero', {})
        self.assertEqual(state['zero_operation']['status'], 'pending')
        for action in ('zero', 'home', 'move'):
            with self.assertRaisesRegex(ValueError, '正在登记'):
                self.control.action(action, dict(pitch=0, yaw=0))
        self.control._poll_once()
        self.assertEqual(self.control.status()['zero_operation']['status'], 'completed')
        self.assertIn(0x4c, [cmd for cmd, _ in self.device.requests])

    def test_zero_retry_reuses_sequence_and_expires_as_unknown(self):
        """Lost replies must not turn into a new calibration transaction."""
        self.device.defer_zero = True
        self.control.action('zero', {})
        original = self.device.packets[-1]
        pending = self.control.zero_pending
        with patch('pango_video.mcu_control.time.monotonic', return_value=pending['sent'] + .6):
            self.control._poll_once()
        self.assertEqual(self.device.packets[-2], original)
        self.assertEqual(len([p for p in self.device.packets if wire.decode(p)[0] == 0x4a]), 2)
        with patch('pango_video.mcu_control.time.monotonic', return_value=pending['started'] + 17):
            self.control._advance_zero()
        self.assertEqual(self.control.status()['zero_operation']['status'], 'unknown')
        self.assertTrue(self.control.status()['connected'])

    def test_zero_rejection_and_disconnect_are_not_success(self):
        """Delayed rejection stays visible and disconnect preserves uncertainty."""
        self.device.defer_zero = True
        self.control.action('zero', {})
        seq = self.control.zero_pending['seq']
        self.device.output.extend(wire.encode(0x80, seq,
            struct.pack('<QIBBH', 42, self.control.session, 0x4a, 7, 0)))
        self.control._poll_once()
        self.assertEqual(self.control.status()['zero_operation']['status'], 'failed')
        self.assertIn('NOT_READY', self.control.status()['zero_operation']['message'])
        self.control.action('zero', {})
        self.control.close()
        self.assertEqual(self.control.status()['zero_operation']['status'], 'unknown')

    def event(self, event_id, motion=0, kind=2, result=0, session=None):
        """Build firmware EVENT fields independently from the host decoder."""
        body = struct.pack('<QIIQIHHIHBB', 42,
            self.control.session if session is None else session, event_id, 1000000,
            motion, kind, result, 1, 0, 24, 0)
        return wire.encode(0x90, event_id, body)

    def test_events_are_validated_deduplicated_and_acknowledged(self):
        self.control.action('move', dict(pitch=3, yaw=-3))
        motion = self.control.motion
        event = self.event(5, motion)
        self.device.output.extend(self.event(4, motion, session=self.control.session ^ 1))
        self.device.output.extend(event[:-1] + bytes([event[-1] ^ 1]))
        self.device.output.extend(event + event)
        self.control._poll_once()
        self.assertEqual(self.control.event_acked, 5)
        self.assertEqual(self.control.status()['last_command']['status'], 'completed')
        ack = [p for cmd, p in self.device.requests if cmd == 0x49]
        self.assertEqual(len(ack), 1)
        self.assertEqual(struct.unpack_from('<I', ack[0], 12)[0], 5)

    def test_old_and_failed_events_do_not_report_new_motion_success(self):
        self.control.action('move', dict(pitch=3, yaw=-3))
        motion = self.control.motion
        self.device.output.extend(self.event(8, motion - 1))
        self.control._poll_once()
        self.assertEqual(self.control.status()['last_command']['status'], 'accepted')
        self.device.output.extend(self.event(9, motion, kind=5, result=1))
        self.control._poll_once()
        self.assertEqual(self.control.status()['last_command']['status'], 'failed')
        self.assertEqual(self.control.event_acked, 9)

    def test_manual_reads_are_coalesced_and_busy_does_not_disconnect(self):
        count = len(self.device.requests)
        self.control.action('read', {})
        self.assertEqual(len(self.device.requests), count)
        self.control.query_after = 0
        self.device.busy_status = True
        self.control._poll_once()
        self.assertTrue(self.control.status()['connected'])
        # A BUSY response must not refresh the timestamp of cached feedback.
        before = self.control.snapshot['_received']
        self.control.action('read', {})
        self.assertEqual(self.control.snapshot['_received'], before)

    def test_modem_lines_are_disabled_before_open(self):
        """Match the tool's serial-open behavior without touching real hardware."""
        opened = []
        class Port(Device):
            def __init__(self, **options):
                super().__init__(**options)
                self.initial_port = options['port']
            def open(self):
                opened.append((self.initial_port, self.port, self.dtr, self.rts))
        other = MCUControl()
        with patch.dict(sys.modules, {'serial': SimpleNamespace(Serial=Port)}):
            try:
                other.connect('simulated-modem-lines')
            finally:
                other.close()
        self.assertEqual(opened, [(None, 'simulated-modem-lines', False, False)])


if __name__ == '__main__':
    unittest.main()

"""Protocol session tests with a byte-level, read-only-until-command board."""
import struct
import threading
import unittest
from unittest.mock import patch
from types import SimpleNamespace

from pango_video.fpga_algorithms import AlgorithmControls, AlgorithmUart
from pango_video.fpga_rgb_control import command
from pango_video.web_session import SessionError


class FakeUart:
    """Return documented wire payloads and retain each sequence for assertions."""
    calls = []

    def __init__(self, port):
        self.sequence = 0
        self.closed = False
        self.record = bytearray(96)
        struct.pack_into('<HH', self.record, 0, 1, 10)
        struct.pack_into('<4I', self.record, 8, 2, 7, 1, 2)

    def close(self):
        self.closed = True

    def exchange(self, cmd, payload):
        self.sequence += 1
        self.calls.append((cmd, payload, self.sequence))
        reply = bytearray(32)
        reply[1] = cmd
        if cmd == 0xA0:
            reply[3] = 24
            reply[4:8] = reply[28:32] = b'AFG1'
            struct.pack_into('<HHI', reply, 8, 1, 1, 1)
        elif cmd == 0xA4:
            page = payload[2]
            reply[2:4] = bytes([page, 24])
            reply[4:28] = self.record[page*24:(page+1)*24]
            reply[28:32] = b'AFG1'
        elif cmd == 0xA6:
            self.record[4] = payload[0] | 4
            self.record[20:24] = payload[4:8]
        elif cmd == 0x95:
            page = payload[0]
            geo = bytearray(96)
            struct.pack_into('<III', geo, 64, 1 << 26, 8, 7)
            reply[2:4] = bytes([page, 24])
            reply[4:28] = geo[page*24:(page+1)*24]
            reply[28:32] = b'RGB1'
        return bytes(reply)


class AlgorithmSessionTests(unittest.TestCase):
    def setUp(self):
        FakeUart.calls = []
        self.board = SimpleNamespace(lock=threading.RLock(), state={'busy': False},
                                     profile={'port': 'test'})
        self.service = AlgorithmControls(self.board, FakeUart)

    def test_connect_never_restores_a_switch(self):
        result = self.service.execute({'action': 'read'})
        self.assertFalse(result['queued'])
        self.assertFalse(result['state']['applied_enable'])
        self.assertNotIn(0xA6, [x[0] for x in FakeUart.calls])

    def test_toggle_uses_readback_version_and_remains_pending(self):
        result = self.service.execute({'action': 'affine', 'enabled': True})
        request = next(x for x in FakeUart.calls if x[0] == 0xA6)
        self.assertEqual(request[1], bytes.fromhex('010000000300000007000000'))
        self.assertTrue(result['queued'])
        self.assertTrue(result['state']['pending'])
        self.assertFalse(result['state']['applied_enable'])
        first_last = FakeUart.calls[-1][2]
        self.service.execute({'action': 'read'})
        self.assertGreater(FakeUart.calls[-1][2], first_last)

    def test_commissioning_owns_the_port(self):
        self.board.state['busy'] = True
        with self.assertRaises(SessionError):
            self.service.execute({'action': 'read'})
        self.assertEqual(FakeUart.calls, [])

    def test_unsupported_lens_model_cannot_be_submitted(self):
        with self.assertRaises(SessionError):
            self.service.execute({'action': 'geometry', 'model': 'fisheye'})
        self.assertNotIn(0x94, [x[0] for x in FakeUart.calls])

    def test_generic_lut_upload_is_four_chunks_and_does_not_enable_tone(self):
        """Exercise service routing against the real documented long record."""
        class EntityUart(FakeUart):
            def exchange(self, cmd, payload):
                if cmd == 0xA4 and payload[:2] == b'\x02\0':
                    self.sequence += 1
                    self.calls.append((cmd, payload, self.sequence))
                    page = payload[2]
                    record = struct.pack('<HHIIHBBQQ', 1, 2, 3, 9, 256, 1, 0, 1, 12) + bytes(range(256))
                    return bytes([0, cmd, page, 24]) + record[page*24:(page+1)*24] + b'AFG1'
                result = bytearray(super().exchange(cmd, payload))
                if cmd == 0xA0:
                    struct.pack_into('<I', result, 16, 1 << 2)
                return bytes(result)
        service = AlgorithmControls(self.board, EntityUart)
        result = service.execute(dict(action='entity_write', kind=2, draft={'gamma': 1}, entity_id=4))
        chunks = [payload for cmd, payload, _ in FakeUart.calls if cmd == 0xA2]
        self.assertEqual([struct.unpack_from('<H', chunk, 4)[0] for chunk in chunks], [0,64,128,192])
        self.assertEqual(b''.join(chunk[8:] for chunk in chunks), bytes(range(256)))
        self.assertTrue(result['queued'])
        self.assertNotIn(0x92, [x[0] for x in FakeUart.calls])
        self.assertEqual(result['entity']['version'], 3)  # ACK is not applied.

    def test_unsupported_entity_cannot_start_upload(self):
        with self.assertRaises(SessionError):
            self.service.execute(dict(action='entity_write', kind=7, draft={}, entity_id=1))
        self.assertNotIn(0xA1, [x[0] for x in FakeUart.calls])

    def test_compact_firmware_keeps_dynamic_writes_without_body_echo(self):
        """Negotiate summaries, use device version, and keep ACK distinct from applied."""
        class SummaryUart(FakeUart):
            def exchange(self, cmd, payload):
                if cmd==0xA4 and payload[:2]==b'\x01\0':
                    self.sequence+=1;self.calls.append((cmd,payload,self.sequence))
                    page=payload[2]
                    record=struct.pack('<HHIIHBBQQ',2,1,3,9,0,1,0,1,12)+bytes(16)
                    return bytes([0,cmd,page,24])+record[page*24:(page+1)*24]+b'AFG1'
                reply=bytearray(super().exchange(cmd,payload))
                if cmd==0xA0:
                    struct.pack_into('<I',reply,12,9)
                    struct.pack_into('<I',reply,16,(1<<1)|(1<<9)|(1<<10))
                return bytes(reply)
        result=AlgorithmControls(self.board,SummaryUart).execute(dict(action='entity_write',kind=1,
            draft={'mode':1,'curve':1},entity_id=4))
        begin=next(data for cmd,data,_ in FakeUart.calls if cmd==0xA1)
        self.assertEqual(struct.unpack_from('<I',begin,8)[0],4)
        self.assertTrue(result['queued'])
        self.assertEqual(result['entity']['version'],3)
        self.assertIsNone(result['entity']['values'])
        self.assertFalse(result['features']['mcu_auto_pose'])
        self.assertFalse(result['features']['entity_body_readback'])
        self.assertEqual([data[2] for cmd,data,_ in FakeUart.calls if cmd==0xA4 and data[:2]==b'\x01\0'],[0,1,0,1])

    def test_runtime_actions_route_without_entity_kind_or_draft(self):
        """UI button payloads must reach A5, then read independent action state."""
        class ActionUart(FakeUart):
            def exchange(self, cmd, payload):
                if cmd == 0xA4 and payload[:2] == b'\x0b\0':
                    self.sequence += 1
                    self.calls.append((cmd, payload, self.sequence))
                    page = payload[2]
                    record = bytearray(168)
                    struct.pack_into('<HHIIHBBQQ', record, 0, 1, 11, 1, 1, 128, 0, 0, 0, 0)
                    record[32+88] = 1
                    return bytes([0, cmd, page, 24]) + record[page*24:(page+1)*24] + b'AFG1'
                reply = bytearray(super().exchange(cmd, payload))
                if cmd == 0xA0:
                    struct.pack_into('<I', reply, 16, (1 << 4) | (1 << 6) | (1 << 11))
                return bytes(reply)
        service = AlgorithmControls(self.board, ActionUart)
        for action, opcode in [('clear_history', 4)]:
            FakeUart.calls = []
            result = service.execute({'action': action})
            self.assertTrue(result['queued'])
            self.assertEqual([x[1] for x in FakeUart.calls if x[0] == 0xA5], [struct.pack('<HHI', opcode, 0, 0)])
            self.assertEqual(result['entity']['kind'], 11)
            self.assertNotIn(0xA1, [x[0] for x in FakeUart.calls])

    def test_removed_motion_requests_do_not_upload(self):
        """Legacy capability bits cannot authorize removed feature drafts."""
        class LegacyUart(FakeUart):
            def exchange(self, cmd, payload):
                if cmd == 0xA4 and int.from_bytes(payload[:2], 'little') in (4,5,6):
                    kind=int.from_bytes(payload[:2], 'little');page=payload[2]
                    body=bytes(16 if kind==6 else 32)
                    record=struct.pack('<HHIIHBBQQ',1,kind,0,0,len(body),0,6,0,0)+body
                    record+=bytes((-len(record))%24)
                    return bytes([0,cmd,page,24])+record[page*24:(page+1)*24]+b'AFG1'
                reply=bytearray(super().exchange(cmd,payload))
                if cmd==0xA0:struct.pack_into('<I',reply,16,(1<<4)|(1<<5)|(1<<6))
                return bytes(reply)
        service=AlgorithmControls(self.board,LegacyUart)
        for request in [dict(action='reset_motion'),dict(action='entity_write',kind=4,draft={},entity_id=1),
                        dict(action='entity_write',kind=5,draft={'mode':2},entity_id=1),
                        dict(action='entity_write',kind=6,draft={'enabled':1},entity_id=1)]:
            FakeUart.calls=[]
            with self.assertRaises(SessionError):service.execute(request)
            self.assertFalse(any(cmd in (0xA1,0xA2,0xA3,0xA5) for cmd,_,_ in FakeUart.calls))
        result=service.execute({'action':'read'})
        self.assertFalse(result['kind_mask'] & (1<<4))
        self.assertFalse(result['features']['history_completion'])

    def test_uart_rejects_corrupt_stale_and_nak(self):
        """Real reply parser must skip corrupt and wrong-sequence responses."""
        payload = bytes([0, 0xA0]) + bytes(30)
        good = command(0x80, payload, 1)
        bad = good[:-1] + bytes([good[-1] ^ 1])

        class Link:
            def __init__(self):
                self.data = bytearray(bad + command(0x80, payload, 99) + good)
                self.written = []

            def write(self, wire):
                self.written.append(wire)

            def read(self, count):
                result = self.data[:count]
                del self.data[:count]
                return bytes(result)

        uart = object.__new__(AlgorithmUart)
        uart.link, uart.sequence, uart.records = Link(), 0, []
        self.assertEqual(uart.exchange(0xA0, b'\0'), payload)
        self.assertEqual(len(uart.link.written), 1)

    def test_timeout_retry_keeps_sequence_and_bytes(self):
        """A lost ACK cannot turn a retry into a second control transaction."""
        payload = bytes([0, 0xA6, 2]) + bytes(29)
        uart = object.__new__(AlgorithmUart)
        uart.sequence, uart.records = 0, []
        written = []
        uart.link = SimpleNamespace(write=written.append, read=lambda _: command(0x80, payload, 1))
        with patch('pango_video.fpga_algorithms.time.monotonic', side_effect=[0, 3, 3, 3]):
            self.assertEqual(uart.exchange(0xA6, bytes.fromhex('010000000300000007000000')), payload)
        self.assertEqual(len(written), 2)
        self.assertEqual(written[0], written[1])

    def test_lost_chunk_ack_retries_before_device_staging_expires(self):
        """Model the actual 2 s staging expiry and a lost first A2 response."""
        clock = [0.0]
        writes = []
        frontier = [0]
        class Link:
            def write(self, packet):
                writes.append(packet)
                if len(writes) == 1:
                    frontier[0] = 64
            def read(self, count):
                clock[0] += .1
                if len(writes) == 1:
                    return b''
                code = 11 if clock[0] >= 2 else 0
                return command(0x81 if code else 0x80, bytes([code,0xA2])+bytes(30), 1)
        uart=object.__new__(AlgorithmUart)
        uart.link,uart.sequence,uart.records=Link(),0,[]
        with patch('pango_video.fpga_algorithms.time.monotonic',side_effect=lambda:clock[0]):
            uart.exchange(0xA2,bytes.fromhex('0900000000004000')+bytes(64))
        self.assertLess(clock[0],2)
        self.assertEqual(writes[0],writes[1])
        self.assertEqual(frontier[0],64)


if __name__ == '__main__':
    unittest.main()

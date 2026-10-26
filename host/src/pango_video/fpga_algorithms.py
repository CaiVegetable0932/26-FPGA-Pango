"""Board algorithm controls over the existing PC UART, independent of video.

Every operation starts by negotiating capability and reading actual state.
Opening this page never restores a remembered switch or submits geometry.
"""
import struct
import time
import secrets

from .board_link import Uart
from .fpga_rgb_control import (COEFFICIENT_NAMES, affine_enable, affine_state,
                               command, geometry, reply, reference_entity,
                               begin_reference, entity_chunk, commit_entity)
from .web_session import SessionError
from .affine_draft import compile_draft
from .fpga_entities import ENTITY_LENGTHS, encode_entity, begin_entity, read_entity


class AlgorithmUart(Uart):
    """Retry only the exact wire packet, retaining its sequence and payload."""
    def exchange(self, command_id, payload=b''):
        self.sequence = self.sequence % 65535 + 1
        wire = command(command_id, payload, self.sequence)
        pending = bytearray()
        for attempt in range(2):
            self.link.write(wire)
            # Retry well before the FPGA 2-second staging idle expiry. A max
            # chunk takes <8 ms on 115200 baud; reads are bounded to 100 ms.
            deadline = time.monotonic() + 0.5
            while time.monotonic() < deadline:
                pending.extend(self.link.read(42))
                while len(pending) >= 42:
                    candidate = bytes(pending[:42])
                    try:
                        result = reply(candidate)
                    except ValueError:
                        del pending[0]
                        continue
                    del pending[:42]
                    if result['sequence'] != self.sequence or result['command'] != command_id:
                        continue
                    self.records.append(dict(request=wire.hex(), reply=candidate.hex(), attempt=attempt))
                    self.records[:] = self.records[-128:]
                    if not result['ok']:
                        raise SessionError(f"FPGA 拒绝命令 0x{command_id:02X}：code={result['code']}")
                    return result['payload']
        raise SessionError('FPGA 回复超时；相同序号已重试，应用状态未知，请读取实际状态')


def read_affine(uart):
    """Freeze and assemble one AFG1 record, rejecting mixed/old firmware pages."""
    record = bytearray()
    for page in range(4):
        result = uart.exchange(0xA4, struct.pack('<HBB', 10, page, 0))
        if result[1:4] != bytes([0xA4, page, 24]) or result[28:32] != b'AFG1':
            raise SessionError('AFFINE_CONTROL 分页格式不匹配')
        record.extend(result[4:28])
    return affine_state(record)


def read_geometry(uart):
    """Read the configured ON matrix separately from the selected OFF view."""
    record = bytearray()
    for page in range(4):
        result = uart.exchange(0x95, bytes([page]))
        if result[1:4] != bytes([0x95, page, 24]) or result[28:32] != b'RGB1':
            raise SessionError('几何实体分页格式不匹配')
        record.extend(result[4:28])
    return dict(coefficients=dict(zip(COEFFICIENT_NAMES, struct.unpack_from('<17i', record))),
                entity_id=int.from_bytes(record[68:72], 'little'),
                version=int.from_bytes(record[72:76], 'little'), pending=bool(record[92]))


def read_reference(uart):
    """Decode the whole fixed-schema reference plus its source-boundary record."""
    record = bytearray()
    for page in range(4):
        result = uart.exchange(0xA4, struct.pack('<HBB', 9, page, 0))
        if result[1:4] != bytes([0xA4, page, 24]) or result[28:32] != b'AFG1':
            raise SessionError('AFFINE_REFERENCE 分页格式不匹配')
        record.extend(result[4:28])
    return dict(intrinsics=[v / 65536 for v in struct.unpack_from('<4i', record)],
                coefficients=list(struct.unpack_from('<6i', record, 16)),
                width=int.from_bytes(record[40:42], 'little'), height=int.from_bytes(record[42:44], 'little'),
                calibration_id=int.from_bytes(record[44:48], 'little'),
                version=int.from_bytes(record[64:68], 'little'), entity_id=int.from_bytes(record[68:72], 'little'),
                source_epoch=str(int.from_bytes(record[72:80], 'little')),
                source_frame_id=str(int.from_bytes(record[80:88], 'little')), pending=bool(record[88]))


class AlgorithmControls:
    """Serialize runtime access with BoardLink's commissioning owner.

    Ports close after each bounded request. The sequence cursor persists across
    openings so two UI operations cannot collide with the FPGA retry record.
    """
    def __init__(self, board_link, uart=AlgorithmUart):
        self.board_link, self.uart = board_link, uart
        self.sequence = 1000

    def execute(self, data):
        """Query or submit one explicit user edit, then read actual board state."""
        action = data.get('action', 'read')
        if action == 'preview':
            return compile_draft(data['reference'], data['geometry'], **data['transform'])
        if action not in ('read', 'affine', 'geometry', 'reference', 'cancel_upload', 'entity_read', 'entity_write', 'reset_motion', 'clear_history'):
            raise SessionError('未知板端算法操作')
        with self.board_link.lock:
            if self.board_link.state.get('busy'):
                raise SessionError('板卡启动正在使用串口，请等待启动完成')
            port = data.get('port') or self.board_link.profile.get('port')
            if not isinstance(port, str) or not port:
                raise SessionError('请选择 CP2102 串口')
            uart = self.uart(port)
            uart.sequence = self.sequence
            try:
                cap = uart.exchange(0xA0, b'\0')
                if (cap[1:4] != b'\xa0\0\x18' or cap[4:8] != b'AFG1' or
                        cap[28:32] != b'AFG1' or struct.unpack_from('<HH', cap, 8) != (1, 1) or
                        not int.from_bytes(cap[12:16], 'little') & 1):
                    raise SessionError('当前位流不支持 AFG1 仿射控制')
                state = read_affine(uart)
                has_reference = bool(int.from_bytes(cap[12:16], 'little') & 4)
                kind_mask = int.from_bytes(cap[16:20], 'little')
                selected_entity = None
                queued = False
                if action == 'affine':
                    if state['pending']:
                        raise SessionError('已有开关等待源帧生效，请先刷新状态')
                    packet = affine_enable(data['enabled'], state['control_version'] + 1,
                                           state['geometry_version'])
                    uart.exchange(0xA6, packet[8:-2])
                    queued = True
                elif action == 'geometry':
                    current = read_geometry(uart)
                    if current['pending'] or state['pending']:
                        raise SessionError('已有几何或开关等待生效')
                    # A complete 17-word draft must be explicit. Do not silently
                    # truncate a fish-eye calibration to the pinhole lens model.
                    if data.get('model') != 'affine_lens':
                        raise SessionError('仅接受 affine_lens 的 k1/k2/p1/p2 模型')
                    packet = geometry(data['coefficients'], current['version'] + 1,
                                      data['entity_id'])
                    uart.exchange(0x94, packet[8:-2])
                    queued = True
                elif action == 'reference':
                    if not has_reference:
                        raise SessionError('当前位流不支持参考实体上传')
                    reference = read_reference(uart)
                    if reference['pending'] or state['pending']:
                        raise SessionError('已有参考或开关等待生效')
                    body = reference_entity(**data['reference'])
                    txid = secrets.randbelow(0x7fffffff) + 1
                    packets = [begin_reference(body, txid, reference['version'] + 1, data['entity_id']),
                               entity_chunk(txid, 0, body[:32]), entity_chunk(txid, 32, body[32:]),
                               commit_entity(txid, body)]
                    for packet in packets:
                        uart.exchange(packet[3], packet[8:-2])
                    queued = True
                elif action in ('entity_read', 'entity_write'):
                    kind = data.get('kind')
                    if type(kind) is not int or kind not in ENTITY_LENGTHS or kind == 9 or not kind_mask & (1 << kind):
                        raise SessionError('当前位流不支持此实体')
                    selected_entity = read_entity(uart, kind)
                    if action == 'entity_write':
                        if kind == 11:
                            raise SessionError('运动帧状态只读')
                        if selected_entity['pending']:
                            raise SessionError('实体仍在等待应用；LUT 需先由 TONE_CONFIG 选择并生效')
                        # Registration-dependent legacy drafts are explicit failures;
                        # retained codecs may still decode historical evidence.
                        draft = data['draft']
                        if kind == 4 or (kind == 5 and draft.get('mode') == 2) or (kind == 6 and draft.get('enabled')):
                            raise SessionError('C4 已撤销；动态裁边和未配准历史补全不可用')
                        body = encode_entity(kind, draft)
                        txid = secrets.randbelow(0x7fffffff) + 1
                        packets = [begin_entity(kind, body, txid, selected_entity['version'] + 1, data['entity_id'])]
                        packets.extend(entity_chunk(txid, offset, body[offset:offset + 64]) for offset in range(0, len(body), 64))
                        packets.append(commit_entity(txid, body))
                        for packet in packets:
                            uart.exchange(packet[3], packet[8:-2])
                        queued = True
                        selected_entity = read_entity(uart, kind)
                elif action in ('reset_motion', 'clear_history'):
                    # Discrete actions have no entity draft/kind input. Keep
                    # this dispatch separate from the generic entity validator.
                    kind = 4 if action == 'reset_motion' else 6
                    if action == 'reset_motion':
                        raise SessionError('C4 视觉参考已撤销，不支持重置')
                    if not kind_mask & (1 << kind):
                        raise SessionError('当前位流不支持此离散动作')
                    uart.exchange(0xA5, struct.pack('<HHI', 3 if kind == 4 else 4, 0, 0))
                    selected_entity = read_entity(uart, 11) if kind_mask & (1 << 11) else None
                    queued = True
                elif action == 'cancel_upload':
                    # Query the device's bounded transaction before explicit
                    # cancellation. Already committed frame entities are intact.
                    result = uart.exchange(0xA5, struct.pack('<HHI', 2, 0, 0))
                    txid = int.from_bytes(result[4:8], 'little')
                    if txid:
                        uart.exchange(0xA5, struct.pack('<HHI', 1, 0, txid))
                # Availability is explicit JSON; ACK never certifies registration.
                return dict(features={'visual_stabilization': False, 'dynamic_viewport': False,
                                      'history_completion': False, 'history_reason': 'visual_registration_removed'},
                            kind_mask=kind_mask & ~(1 << 4), entity=selected_entity, state=read_affine(uart), geometry=read_geometry(uart),
                            reference=read_reference(uart) if has_reference else None, queued=queued,
                            message='已校验并排队；以源帧和板端显示读回为准' if queued else '已读取板端实际状态')
            finally:
                self.sequence = uart.sequence
                uart.close()

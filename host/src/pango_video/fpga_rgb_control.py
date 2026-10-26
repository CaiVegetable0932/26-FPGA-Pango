"""Offline codecs for the integrated FPGA RGB control extension.

These functions produce/parse bytes only. They do not open a serial port, socket
or camera. Boot addresses use raw8_boot; this extension keeps PC V1 framing.
"""
import struct
import zlib
import math
from .raw8_boot import crc16

COEFFICIENT_NAMES = ('a00', 'a01', 'a02', 'a10', 'a11', 'a12', 'k1', 'k2',
                     'p1', 'p2', 'fx', 'fy', 'cx', 'cy', 'a20', 'a21', 'a22')


def command(command_id, payload, sequence=1):
    """Encode one PC V1 command with CRC16 over version through payload."""
    if not 0 <= sequence <= 65535 or len(payload) > 512:
        raise ValueError('sequence/payload outside wire bounds')
    body = struct.pack('<BBHH', 1, command_id, sequence, len(payload)) + payload
    return b'\x55\xaa' + body + struct.pack('<H', crc16(body))


def mode(mode, version, sequence=1):
    """Queue disabled/pre_resample; ACK does not mean applied."""
    if mode not in (0, 1) or not 1 <= version <= 0x7fffffff:
        raise ValueError('mode/version outside supported bounds')
    return command(0x92, struct.pack('<BBI', mode, 0, version), sequence)



def read_page(command_id, page, sequence=1):
    """Page zero freezes all pages; read remaining pages without interleaving."""
    limits = {0x90: 4, 0x95: 4}
    if command_id not in limits or not 0 <= page < limits[command_id]:
        raise ValueError('unknown readback/page')
    return command(command_id, bytes([page]), sequence)


def geometry(coefficients, version, entity_id, sequence=1):
    """Encode all 17 signed fixed-point words without dropping distortion terms.

    Values are integers in the RTL formats (Q26 except fx/fy/cx/cy Q16).
    The FPGA performs range, version and whole-entity CRC validation. The ID
    identifies calibration provenance, and does not certify optical accuracy.
    """
    if not 1 <= version <= 0x7fffffff or not 1 <= entity_id <= 0x7fffffff:
        raise ValueError('positive supported version/entity ID required')
    values = [coefficients[name] for name in COEFFICIENT_NAMES]
    if not all(isinstance(v, int) and -2**31 <= v < 2**31 for v in values):
        raise ValueError('signed 32-bit fixed coefficients required')
    if values[14:] != [0, 0, 1 << 26]:
        raise ValueError('affine_lens requires canonical third row (0, 0, 1<<26)')
    payload = struct.pack('<II17i', version, entity_id, *values)
    payload += struct.pack('<I', zlib.crc32(payload))
    return command(0x94, payload, sequence)


def affine_enable(enabled, control_version, geometry_version, sequence=1):
    """Queue a board transform switch; the reference retains lens and colour.

    The same sequence and payload must be reused after a reply timeout. ACK
    confirms queuing only; affine_state supplies source and display adoption.
    """
    if type(enabled) is not bool:
        raise ValueError('enabled must be boolean')
    if not all(type(v) is int and 1 <= v <= 0x7fffffff
               for v in (control_version, geometry_version)):
        raise ValueError('positive supported control/geometry version required')
    return command(0xA6, struct.pack('<B3xII', enabled, control_version,
                                   geometry_version), sequence)


def affine_read_page(page, sequence=1):
    """Read AFFINE_CONTROL kind 10/schema 1 without interleaved read commands."""
    if type(page) is not int or not 0 <= page < 4:
        raise ValueError('AFFINE_CONTROL page must be 0..3')
    return command(0xA4, struct.pack('<HBB', 10, page, 0), sequence)


def affine_state(record):
    """Decode board adoption; never infer a capture-card frame association."""
    if len(record) != 96 or struct.unpack_from('<HH', record) != (1, 10):
        raise ValueError('unsupported AFFINE_CONTROL schema')
    if record[4] & 0xf0 or any(record[5:8]) or any(record[93:]):
        raise ValueError('invalid AFFINE_CONTROL reserved fields')
    flags = record[4]
    version, geometry_version, reference_version, requested_version = struct.unpack_from('<4I', record, 8)
    epoch, frame = struct.unpack_from('<QQ', record, 24)
    display_epoch, display_frame = struct.unpack_from('<QQ', record, 64)
    dc, dg, dr = struct.unpack_from('<III', record, 80)
    if record[92] > 1:
        raise ValueError('invalid displayed enable')
    return dict(requested_enable=bool(flags & 1), applied_enable=bool(flags & 2),
                pending=bool(flags & 4), control_version=version,
                geometry_version=geometry_version, reference_version=reference_version,
                requested_version=requested_version, source_epoch=str(epoch), source_frame_id=str(frame),
                coefficients=list(struct.unpack_from('<6i', record, 40)),
                display_known=bool(flags & 8), display_epoch=str(display_epoch),
                display_frame_id=str(display_frame), display_control_version=dc,
                display_geometry_version=dg, display_reference_version=dr,
                display_enable=bool(record[92]), hdmi_capture_source_verified=False)


def reference_entity(fx, fy, cx, cy, width=1920, height=1080, calibration_id=1):
    """Compile a normalized OFF view from explicit output intrinsics.

    Quantize intrinsics first, then derive Q26 rays using exact integer ratios.
    This matches the FPGA product-residual guard and avoids a hidden second
    interpretation of rounded UI values. Pixel centres are integer u/v.
    """
    if any(type(v) not in (int, float) or not math.isfinite(v) for v in (fx, fy, cx, cy)):
        raise ValueError('finite numeric output intrinsics required')
    k = [round(v * 65536) for v in (fx, fy, cx, cy)]
    if not (0 < k[0] <= 0x20000000 and 0 < k[1] <= 0x20000000 and
            abs(k[2]) <= 0x20000000 and abs(k[3]) <= 0x20000000):
        raise ValueError('output intrinsics outside FPGA bounds')
    if (type(width) is not int or type(height) is not int or
            not 2 <= width <= 4096 or not 2 <= height <= 4096 or
            type(calibration_id) is not int or not 1 <= calibration_id <= 0x7fffffff):
        raise ValueError('invalid reference dimensions/calibration ID')

    def ratio(numerator, denominator):
        """Nearest, half away from zero, without float division at large Q."""
        q, remainder = divmod(abs(numerator), denominator)
        return (q + (2 * remainder >= denominator)) * (-1 if numerator < 0 else 1)

    a = [ratio(1 << 42, k[0]), 0, ratio(-k[2] * (1 << 26), k[0]),
         0, ratio(1 << 42, k[1]), ratio(-k[3] * (1 << 26), k[1])]
    if not (0 < a[0] <= 0x800000 and 0 < a[4] <= 0x800000 and
            abs(a[2]) <= 0x20000000 and abs(a[5]) <= 0x20000000):
        raise ValueError('reference rays outside FPGA affine bounds')
    return struct.pack('<10iHHIH14x', *k, *a, width, height, calibration_id, 1)


def begin_reference(data, txid, version, entity_id, sequence=1):
    """Begin one immutable 64-byte AFFINE_REFERENCE upload, schema 1."""
    if len(data) != 64 or not all(type(v) is int and 1 <= v <= 0x7fffffff
                                 for v in (txid, version, entity_id)):
        raise ValueError('invalid reference upload identity/length')
    return command(0xA1, struct.pack('<HHIIIHHI', 9, 1, txid, version, entity_id,
                                    len(data), 0, zlib.crc32(data)), sequence)


def entity_chunk(txid, offset, data, sequence=1):
    """Contiguous chunks carry at most 64 bytes; retry exact accepted bytes."""
    if not 1 <= txid <= 0x7fffffff or not 0 <= offset < 1024 or not 1 <= len(data) <= 64 or offset + len(data) > 1024:
        raise ValueError('entity chunk outside bounded protocol')
    return command(0xA2, struct.pack('<IHBB', txid, offset, len(data), 0) + data, sequence)


def commit_entity(txid, data, sequence=1):
    """Policy zero queues for the next source boundary, with whole-body CRC."""
    if not 1 <= txid <= 0x7fffffff:
        raise ValueError('invalid transaction ID')
    return command(0xA3, struct.pack('<IIB3x', txid, zlib.crc32(data), 0), sequence)


def reply(packet):
    """Validate the fixed 42-byte reply before exposing its status/page data."""
    if len(packet) != 42 or packet[:3] != b'\x55\xaa\x01':
        raise ValueError('invalid PC reply framing')
    _, response_id, sequence, length = struct.unpack_from('<BBHH', packet, 2)
    if response_id not in (0x80, 0x81) or length != 32:
        raise ValueError('unsupported PC reply')
    if crc16(packet[2:40]) != struct.unpack_from('<H', packet, 40)[0]:
        raise ValueError('PC reply CRC mismatch')
    payload = packet[8:40]
    return {'ok': response_id == 0x80 and payload[0] == 0,
            'sequence': sequence, 'code': payload[0], 'command': payload[1],
            'page_or_stage': payload[2], 'payload': payload}


def pages(packets, command_id):
    """Assemble an ordered frozen readback, rejecting wrong command/page/CRC."""
    count = {0x90: 4, 0x95: 4}[command_id]
    if len(packets) != count:
        raise ValueError('incomplete readback')
    data = bytearray()
    for page, packet in enumerate(packets):
        decoded = reply(packet)
        payload = decoded['payload']
        if not decoded['ok'] or decoded['command'] != command_id or payload[2:4] != bytes([page, 24]):
            raise ValueError('readback command/page mismatch')
        if payload[28:32] != b'RGB1':
            raise ValueError('unknown readback schema')
        data += payload[4:28]
    return bytes(data)



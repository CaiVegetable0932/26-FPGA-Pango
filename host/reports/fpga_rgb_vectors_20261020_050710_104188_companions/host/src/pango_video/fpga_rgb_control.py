"""Offline codecs for the integrated FPGA RGB control extension.

These functions produce/parse bytes only. They do not open a serial port, socket
or camera. Boot addresses use raw8_boot; this extension keeps PC V1 framing.
"""
import struct
import zlib
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
    """Queue disabled/pre_resample/post_resample; ACK does not mean applied."""
    if mode not in (0, 1, 2) or not 1 <= version <= 0x7fffffff:
        raise ValueError('mode/version outside supported bounds')
    return command(0x92, struct.pack('<BBI', mode, 0, version), sequence)


def snapshot(sequence=1):
    """Request one same-source S1/result pair on the next admitted capture."""
    return command(0x93, b'\x00', sequence)


def read_page(command_id, page, sequence=1):
    """Page zero freezes all pages; read remaining pages without interleaving."""
    limits = {0x90: 4, 0x95: 4, 0x96: 8, 0x97: 4}
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
    payload = struct.pack('<II17i', version, entity_id, *values)
    payload += struct.pack('<I', zlib.crc32(payload))
    return command(0x94, payload, sequence)


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
    count = {0x90: 4, 0x95: 4, 0x96: 8, 0x97: 4}[command_id]
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


def snapshot_descriptor(record):
    """Decode the retained 96-byte record, with the exact packed metadata.

    No HDMI association is inferred. These records identify FPGA snapshots;
    physical camera, optics and HDMI source identity need separate evidence.
    """
    if len(record) != 96:
        raise ValueError('snapshot descriptor requires 96 bytes')
    value = int.from_bytes(record[:77], 'little')
    fields = (('pose_status', 8), ('enhancement_stage', 8), ('stage', 8),
              ('format', 16), ('height', 16), ('width', 16), ('errors', 32),
              ('stride', 32), ('mode', 32), ('pose_entity', 32),
              ('parameter_entity', 32), ('calibration_entity', 32),
              ('enhancement_version', 32), ('geometry_version', 32),
              ('isp_version', 32), ('capture_last', 64), ('capture_first', 64),
              ('frame_id', 64), ('epoch', 64))
    result = {}
    for name, bits in fields:
        result[name] = value & ((1 << bits) - 1)
        value >>= bits
    result['descriptor_id'] = int.from_bytes(record[77:81], 'little')
    result['hdmi_source_verified'] = False
    return result

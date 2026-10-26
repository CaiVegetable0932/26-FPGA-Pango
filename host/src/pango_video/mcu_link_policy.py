"""Offline kind12 policy codec and durable session grants; never opens UART."""
import json
import os
from pathlib import Path
import struct
import zlib
from .fpga_rgb_control import command


def reserve_sessions(ledger, count=256):
    """Persist a unique range before returning it, including unused IDs.

    Use one ledger per FPGA installation and retain it across FPGA/MCU resets.
    An exclusive sidecar prevents concurrent allocators. Interrupted writes may
    waste IDs but never return an unpersisted range. A lost/rolled-back ledger
    must be recovered from archived grants before reconnecting the same MCU.
    """
    ledger = Path(ledger)
    if type(count) is not int or not 1 <= count <= 0xffffffff:
        raise ValueError('invalid grant size')
    ledger.parent.mkdir(parents=True, exist_ok=True)
    lock = ledger.with_suffix(ledger.suffix + '.lock')
    temporary = ledger.with_suffix(ledger.suffix + '.new')
    # Exclusive creation fails closed; stale locks require explicit recovery.
    fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
    os.close(fd)
    try:
        state = json.loads(ledger.read_text()) if ledger.exists() else {'schema': 1, 'last_reserved': 0}
        last = state.get('last_reserved')
        if state.get('schema') != 1 or type(last) is not int or not 0 <= last <= 0xffffffff:
            raise ValueError('invalid ledger; recover instead of resetting')
        end = last + count
        if end > 0xffffffff:
            raise ValueError('session space exhausted')
        with temporary.open('w', encoding='utf-8') as stream:
            json.dump({'schema': 1, 'last_reserved': end}, stream)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, ledger)
        return last + 1, end
    finally:
        lock.unlink()


def policy_body(*, enabled, first_session=0, last_session=0, approved=False,
                config_version=0, boot_id=0, config_crc32=0, timing_valid=False,
                capture_error_us=0, evidence_id=0):
    """Encode explicit evidence only; nonzero IDs do not certify calibration."""
    if any(type(v) is not bool for v in (enabled, approved, timing_valid)):
        raise ValueError('flags must be boolean')
    numbers = (first_session, last_session, config_version, config_crc32, capture_error_us, evidence_id)
    if any(type(v) is not int or not 0 <= v <= 0xffffffff for v in numbers):
        raise ValueError('u32 bounds')
    if type(boot_id) is not int or not 0 <= boot_id <= 0xffffffffffffffff:
        raise ValueError('u64 boot bounds')
    if enabled and not 0 < first_session <= last_session:
        raise ValueError('fresh nonzero session grant required')
    if approved and not (enabled and config_version and boot_id and evidence_id):
        raise ValueError('approval requires boot/config/evidence binding')
    if timing_valid and not (approved and capture_error_us <= 1000):
        raise ValueError('timing requires approval and measured <=1000us bound')
    return struct.pack('<BBBBIIIQIII28x', enabled, approved, timing_valid, 0,
                       first_session, last_session, config_version, boot_id,
                       config_crc32, capture_error_us, evidence_id)


def upload(body, *, version, entity_id, transaction, sequence=1):
    """Return BEGIN/one CHUNK/COMMIT; transport must wait/check each ACK.

    Retrying these exact frames preserves the same transaction and grant.
    A transport timeout never authorizes a new range or approval automatically.
    """
    if len(body) != 64 or not 1 <= sequence <= 65533:
        raise ValueError('policy size/sequence')
    if any(type(v) is not int or not 1 <= v <= 0x7fffffff for v in (version, entity_id)):
        raise ValueError('version/entity bounds')
    if type(transaction) is not int or not 1 <= transaction <= 0xffffffff:
        raise ValueError('transaction bounds')
    crc = zlib.crc32(body)
    return (
        command(0xA1, struct.pack('<HHIIIHHI', 12, 1, transaction, version, entity_id, 64, 0, crc), sequence),
        command(0xA2, struct.pack('<IHBB', transaction, 0, 64, 0) + body, sequence + 1),
        command(0xA3, struct.pack('<III', transaction, crc, 0), sequence + 2),
    )


def read_policy_page(page, sequence=1):
    """Read eight consecutive frozen pages after page0; do not interleave."""
    if type(page) is not int or not 0 <= page < 8:
        raise ValueError('kind12 page outside 0..7')
    return command(0xA4, struct.pack('<HBB', 12, page, 0), sequence)

"""Decode read-only board MOTION_FRAME records; never infer HDMI capture IDs."""
from __future__ import annotations

import struct
from dataclasses import dataclass

# Schema-1 enum extension for the C4 withdrawal; old records retain raw values.
VISUAL_DISABLED = 8


@dataclass(frozen=True)
class RuntimeActionStatus:
    """Action state uses its own source boundary, independent of the last job."""
    pending_mask: int
    last_action: int
    applied_epoch: int
    applied_frame_id: int
    applied_sequence: int


@dataclass(frozen=True)
class MotionFrame:
    """An actual board processing job, which may still be awaiting HDMI scanout."""
    epoch: int
    frame_id: int
    matrix_q26: tuple[int, ...]
    pose_status: int
    visual_status: int
    history_applied: bool
    missed_results: int
    history_epoch: int
    history_frame_id: int
    historical_pixels: int
    invalid_pixels: int
    current_pixels: int
    registration_version: int
    stabilization_version: int
    viewport_version: int
    completion_version: int
    pose_version: int
    geometry_version: int
    isp_version: int
    failed: bool
    runtime_action: RuntimeActionStatus


def decode_runtime_action_status(record: bytes) -> RuntimeActionStatus:
    """Read actions even before a complete processing job makes flags.active=1."""
    if len(record)!=160 or struct.unpack_from("<HH",record)!=(1,11):
        raise ValueError("unsupported MOTION_FRAME action record")
    body=record[32:]
    pending,action=struct.unpack_from("<BB",body,88)
    if pending & ~3 or action not in (0,3,4) or any(body[90:96]) or any(body[114:]):
        raise ValueError("invalid action status or reserved MOTION_FRAME data")
    epoch,frame,sequence=struct.unpack_from("<QQH",body,96)
    return RuntimeActionStatus(pending,action,epoch,frame,sequence)


def decode_motion_frame(record: bytes) -> MotionFrame | None:
    """Decode the 32-byte read header plus 128-byte schema-1 motion body.

    Flags report a board job; this is not a source identity on an HDMI capture
    callback. Zero active-valid returns None rather than inventing frame zero.
    """
    if len(record) != 160:
        raise ValueError("MOTION_FRAME record must be 160 bytes")
    schema, kind, version, entity_id, length, flags, error = struct.unpack_from("<HHIIHBB", record)
    if (schema, kind, version, entity_id, length)!=(1,11,1,1,128) or flags & ~3:
        raise ValueError("unsupported MOTION_FRAME record layout")
    actions=decode_runtime_action_status(record)
    if not flags & 1:
        return None
    epoch, frame = struct.unpack_from("<QQ", record, 16)
    body=record[32:]
    matrix=struct.unpack_from("<6i", body)
    pose, visual, history, reserved=struct.unpack_from("<4B",body,24)
    if history>1 or reserved:
        raise ValueError("invalid history flag or reserved MOTION_FRAME data")
    missed,he,hf=struct.unpack_from("<IQQ",body,28)
    numbers=struct.unpack_from("<10I",body,48)
    # Disabled visual registration cannot certify history or an applied C4 version.
    if visual == VISUAL_DISABLED and (history or numbers[0] or numbers[3] or numbers[4]):
        raise ValueError("disabled C4 record claims registered history or visual version")
    return MotionFrame(epoch,frame,matrix,pose,visual,bool(history),missed,he,hf,*numbers,bool(error),actions)

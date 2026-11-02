"""Independent MCU_POSE_V2 byte codec for firmware interoperability checks.

The manual-control payloads below mirror the firmware gateway
(`firmware/longmenjia/Core/Src/f4_link.c`) and the field tool `cal3.c`, so the
PC side never re-derives axis order, masks or fixed-point scales on its own.
"""
from __future__ import annotations

import binascii
import struct

# 掩码位：bit0=X、bit1=Y、bit2=Z（固件逻辑轴 1/2/3）、bit3=pitch、bit4=yaw。
MASK_X, MASK_Y, MASK_Z = 0x01, 0x02, 0x04
MASK_PITCH, MASK_YAW = 0x08, 0x10
GANTRY_MASK = MASK_X | MASK_Y | MASK_Z
GIMBAL_MASK = MASK_PITCH | MASK_YAW
ALL_MASK = GANTRY_MASK | GIMBAL_MASK
# 行程定点：0..100% 行程按 ×1e6 下发，固件按 0..100000000 校验。
TRAVEL_MICRO = 100_000_000
ANGLE_LIMIT_MDEG = 60_000


def encode(cmd: int, seq: int, payload: bytes = b"") -> bytes:
    if len(payload) > 1024 or not 0 <= cmd <= 255 or not 0 <= seq <= 65535:
        raise ValueError("frame field out of range")
    body = struct.pack("<BBHH", 2, cmd, seq, len(payload)) + payload
    return b"\x55\xaa" + body + struct.pack("<H", binascii.crc_hqx(body, 0xFFFF))


def decode(frame: bytes) -> tuple[int, int, bytes]:
    if len(frame) < 10 or frame[:2] != b"\x55\xaa":
        raise ValueError("invalid header")
    version, cmd, seq, length = struct.unpack_from("<BBHH", frame, 2)
    if version != 2 or length > 1024 or len(frame) != length + 10:
        raise ValueError("invalid version or exact length")
    expected = binascii.crc_hqx(frame[2:-2], 0xFFFF)
    if struct.unpack_from("<H", frame, len(frame) - 2)[0] != expected:
        raise ValueError("CRC mismatch")
    return cmd, seq, frame[8:-2]


def context(boot_id: int, session_id: int) -> bytes:
    if not boot_id or not session_id:
        raise ValueError("nonzero boot and session required")
    return struct.pack("<QI", boot_id, session_id)


def state(payload: bytes) -> dict:
    if len(payload) != 96 or any(payload[68:80]):
        raise ValueError("invalid STATE layout")
    boot, session, config, sample, flags = struct.unpack_from("<QIIII", payload)
    xyz = struct.unpack_from("<iii", payload, 40)
    angles = struct.unpack_from("<ii", payload, 52)
    return {
        "boot_id": boot, "session_id": session, "config_version": config,
        "sample_seq": sample, "status_flags": flags,
        "xyz_normalized_micro": [v if flags & (1 << i) else None for i, v in enumerate(xyz)],
        "pitch_mdeg": angles[0] if flags & 8 else None,
        "yaw_mdeg": angles[1] if flags & 16 else None,
        "imu_tick_us": struct.unpack_from("<Q", payload, 24)[0],
        "xyz_tick_us": struct.unpack_from("<Q", payload, 32)[0],
        "servo_tick_us": struct.unpack_from("<Q", payload, 60)[0],
        "motion_id": struct.unpack_from("<I", payload, 80)[0],
        "latest_event_id": struct.unpack_from("<I", payload, 84)[0],
        "xyz_source": payload[90], "angle_source": payload[91],
        "motion_state": payload[92], "pose_quality": payload[93],
        "fault_code": struct.unpack_from("<H", payload, 94)[0],
        "pose_representation": "gimbal_pitch_yaw", "q_wc": None,
    }


def move_body(motion_id: int, mask: int, targets, rpm=(0, 0, 0, 0)) -> bytes:
    """MOVE_ABS(0x46) 请求体，即 12 字节会话上下文之后的 36 字节。

    targets 必须是固件轴序 (轴1, 轴2, 轴3, pitch_mdeg, yaw_mdeg)：轴 1/2/3 对应
    现场 X / Z（双电机）/ Y（伸缩），前三个为 0..100% 行程的 ×1e6 定点，后两个
    为毫度。rpm 为每轴 0..60，未参与运动的轴填 0。固件要求 mask 非零且不超过
    0x1F、保留字段为零。
    """
    if not isinstance(motion_id, int) or not 0 < motion_id <= 0xFFFFFFFF:
        raise ValueError("MOVE_ABS 运动编号无效")
    if not isinstance(mask, int) or not 0 < mask <= ALL_MASK:
        raise ValueError("MOVE_ABS mask 超出 X/Y/Z/pitch/yaw 范围")
    if len(targets) != 5 or len(rpm) != 4:
        raise ValueError("MOVE_ABS 需要 5 个目标值和 4 个速度字段")
    for index, value in enumerate(targets):
        low, high = (0, TRAVEL_MICRO) if index < 3 else (-ANGLE_LIMIT_MDEG, ANGLE_LIMIT_MDEG)
        if not isinstance(value, int) or isinstance(value, bool) or not low <= value <= high:
            raise ValueError("MOVE_ABS 目标值超出固件允许范围")
    for value in rpm:
        if not isinstance(value, int) or isinstance(value, bool) or not 0 <= value <= 60:
            raise ValueError("MOVE_ABS 速度必须为 0..60 RPM")
    return (struct.pack("<IB3x", motion_id, mask)
            + struct.pack("<5i", *targets)
            + struct.pack("<4H", *rpm))


def home_body(motion_id: int, mask: int = GIMBAL_MASK) -> bytes:
    """HOME(0x48) 请求体：12 字节的会话上下文之后共 8 字节。

    固件只接受 mask=0x18（仅云台两轴），长度必须是 20 字节整包，
    写成 MOVE_ABS 的 48 字节会得到 BAD_LENGTH。
    """
    if not isinstance(motion_id, int) or not 0 < motion_id <= 0xFFFFFFFF:
        raise ValueError("HOME 运动编号无效")
    if mask != GIMBAL_MASK:
        raise ValueError("HOME 只支持云台两轴 mask=0x18")
    return struct.pack("<IB3x", motion_id, mask)


def confirm_body(mask: int = GANTRY_MASK) -> bytes:
    """CONFIRM_MANUAL_ZERO(0x51) 请求体：会话上下文之后 4 字节。

    语义是把“当前物理位置”声明为三轴零点，不重新测量位置；复位或人工
    搬动机构后必须先确认零点，否则后续绝对坐标整体偏移。
    """
    if not isinstance(mask, int) or not 0 < mask <= GANTRY_MASK:
        raise ValueError("零点确认只支持 X/Y/Z 掩码")
    return struct.pack("<B3x", mask)


def legacy_body(motion_id: int, text: str) -> bytes:
    """LEGACY(0x50) 请求体：会话上下文之后 = 运动编号 + 1..95 个可打印 ASCII。

    仅用于固件没有结构化命令的动作（当前只有急停 `stop 3`）。固件会拒绝
    含控制字符或长度超过 95 的文本，并按“结果=4”回报。
    """
    if not isinstance(motion_id, int) or not 0 < motion_id <= 0xFFFFFFFF:
        raise ValueError("LEGACY 运动编号无效")
    if not isinstance(text, str):
        raise ValueError("LEGACY 文本必须是字符串")
    raw = text.encode("ascii", "strict")
    if not 1 <= len(raw) <= 95:
        raise ValueError("LEGACY 文本必须为 1..95 字节")
    if any(byte < 0x20 or byte > 0x7E for byte in raw):
        raise ValueError("LEGACY 文本只能包含可打印 ASCII")
    return struct.pack("<I", motion_id) + raw


def notice(payload: bytes) -> dict:
    """Decode NOTICE(0x91): boot 8 + session 4 + 文本，文本为网关的异步回报。

    当前只有 LEGACY 文本命令会产生通知（例如标定时的圈数回报）；本工具
    只用它核对急停结果，因此只做会话归属校验和去尾空白。
    """
    if len(payload) < 12:
        raise ValueError("NOTICE 长度错误")
    boot, session = struct.unpack_from("<QI", payload)
    return {"boot_id": boot, "session_id": session,
            "text": payload[12:].decode("ascii", "replace").rstrip("\r\n\t ")}

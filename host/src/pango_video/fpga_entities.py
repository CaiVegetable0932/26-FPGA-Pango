"""Schema-1 algorithm entity codecs; complete drafts, never per-field writes.

Quantized values are explicit in the advanced editor. These codecs validate
wire domains; calibration/source IDs do not certify a physical calibration.
"""
import struct
import zlib

from .fpga_rgb_control import command
from .image_entities import tone_config, tone_lut, isp_color, camera_config

ENTITY_LENGTHS = {1: 32, 2: 256, 3: 64, 4: 32, 5: 32, 6: 16, 7: 48, 8: 128, 9: 64, 11: 128}
ENTITY_NAMES = {1: 'TONE_CONFIG', 2: 'TONE_LUT', 3: 'ISP_COLOR', 4: 'STABILIZATION',
                5: 'VIEWPORT', 6: 'COMPLETION', 7: 'CAMERA_CONFIG', 11: 'MOTION_FRAME', 8: 'POSE_AFFINE_CALIBRATION', 9: 'AFFINE_REFERENCE'}


def _integer(value, low, high, name):
    """Do not silently coerce booleans, floats or strings to wire integers."""
    if type(value) is not int or not low <= value <= high:
        raise ValueError(f'{name} must be an integer in {low}..{high}')
    return value


def encode_entity(kind, draft):
    """Pack one complete schema using the frozen ENTITY_CONTROL.md layout."""
    if kind not in ENTITY_LENGTHS or kind in (9, 11):
        raise ValueError('use the dedicated reference compiler for kind 9')
    body = bytearray(ENTITY_LENGTHS[kind])

    def put(offset, name, fmt='I', low=0, high=0xffffffff):
        struct.pack_into('<' + fmt, body, offset, _integer(draft[name], low, high, name))

    def byte(offset, name, high=255):
        put(offset, name, 'B', 0, high)

    def word(offset, name):
        put(offset, name, 'H', 0, 65535)

    def signed(offset, name):
        put(offset, name, 'i', -(1 << 31), (1 << 31) - 1)

    def array(offset, name, count, fmt, low, high):
        values = draft[name]
        if not isinstance(values, list) or len(values) != count:
            raise ValueError(f'{name} needs {count} values')
        struct.pack_into('<' + fmt * count, body, offset,
                         *[_integer(v, low, high, name) for v in values])

    if kind == 1:
        return tone_config(**draft)
    elif kind == 2:
        return tone_lut(**draft)
    elif kind == 3:
        return isp_color(**draft)
    elif kind == 4:
        byte(0, 'enabled', 1); byte(1, 'smooth_shift', 8); byte(2, 'search_radius', 4)
        word(4, 'min_texture'); word(6, 'min_confidence')
        signed(8, 'max_translation_q16'); signed(12, 'max_rotation_q26'); signed(16, 'max_scale_delta_q26')
        put(20, 'calibration_id'); put(24, 'match_error_limit')
    elif kind == 5:
        byte(0, 'mode', 2)
        for offset, name in [(4, 'fixed_zoom_q16'), (8, 'max_zoom_q16'), (12, 'step_q16'),
                             (16, 'hysteresis_q16'), (20, 'min_area_q16'), (24, 'calibration_id')]:
            put(offset, name)
    elif kind == 6:
        byte(0, 'enabled', 1); byte(1, 'max_age')
        word(2, 'min_confidence'); word(4, 'max_luma_delta'); put(8, 'registration_version')
    elif kind == 7:
        return camera_config(**draft)
    elif kind == 8:
        byte(0, 'enabled', 1); put(4, 'calibration_id')
        for offset, name in [(8, 'reference_pitch_mdeg'), (12, 'reference_yaw_mdeg'),
                             (16, 'pitch_min_mdeg'), (20, 'pitch_max_mdeg'),
                             (24, 'yaw_min_mdeg'), (28, 'yaw_max_mdeg')]:
            signed(offset, name)
        for offset, name in [(32, 'max_model_error_q16'), (36, 'max_time_error_us'),
                             (40, 'model_source_id'), (44, 'expected_mcu_config')]:
            put(offset, name)
        for offset, name in [(48, 'reference_q26'), (72, 'j_pitch_q26'), (96, 'j_yaw_q26')]:
            array(offset, name, 6, 'i', -(1 << 31), (1 << 31) - 1)
    return bytes(body)


def begin_entity(kind, data, txid, version, entity_id, sequence=1):
    """Validate the schema length before creating a UART upload transaction."""
    if kind not in ENTITY_LENGTHS or kind == 11 or len(data) != ENTITY_LENGTHS[kind]:
        raise ValueError('unsupported entity kind/body length')
    for name, value in [('txid', txid), ('version', version), ('entity_id', entity_id)]:
        _integer(value, 1, 0x7fffffff, name)
    return command(0xA1, struct.pack('<HHIIIHHI', kind, 1, txid, version, entity_id,
                                    len(data), 0, zlib.crc32(data)), sequence)


def decode_entity(kind, body):
    """Expose actual values in the same units as editable complete drafts."""
    def scalar(offset, fmt='I'):
        return struct.unpack_from('<'+fmt, body, offset)[0]
    def array(offset, count, fmt='i'):
        return list(struct.unpack_from('<'+fmt*count, body, offset))
    if kind == 1:
        names=('mode','curve','allowed_mask','hysteresis','low','high','hold_frames','lut_version')
        return dict(zip(names,struct.unpack_from('<6BHI',body)))
    if kind == 2:
        return dict(values=list(body))
    if kind == 3:
        return dict(black_level=array(0,4,'B'),channel_gain=array(4,4,'H'),
                    ccm_enabled=bool(body[12]),wb_mode=body[13],ccm=array(16,9),
                    calibration_id=scalar(52),awb_min=scalar(56,'H'),awb_max=scalar(58,'H'),
                    awb_step=scalar(60,'H'),awb_hold_frames=scalar(62,'H'))
    layouts={
        4:[(0,'enabled','B'),(1,'smooth_shift','B'),(2,'search_radius','B'),(4,'min_texture','H'),(6,'min_confidence','H'),
           (8,'max_translation_q16','i'),(12,'max_rotation_q26','i'),(16,'max_scale_delta_q26','i'),(20,'calibration_id','I'),(24,'match_error_limit','I')],
        5:[(0,'mode','B'),(4,'fixed_zoom_q16','I'),(8,'max_zoom_q16','I'),(12,'step_q16','I'),(16,'hysteresis_q16','I'),(20,'min_area_q16','I'),(24,'calibration_id','I')],
        6:[(0,'enabled','B'),(1,'max_age','B'),(2,'min_confidence','H'),(4,'max_luma_delta','H'),(8,'registration_version','I')],
        7:[(0,'mode','B'),(1,'flicker','B'),(2,'low','B'),(3,'high','B'),(4,'exposure','I'),(8,'gain','H'),
           (10,'gain_min','H'),(12,'gain_max','H'),(14,'gain_step','H'),(16,'exposure_min','I'),(20,'exposure_max','I'),
           (24,'exposure_step','I'),(28,'hold_frames','H'),(30,'settle_frames','H'),(32,'line_time_ns','I'),(36,'period150_code','I'),(40,'timing_calibration_id','I')],
        8:[(0,'enabled','B'),(4,'calibration_id','I'),(8,'reference_pitch_mdeg','i'),(12,'reference_yaw_mdeg','i'),
           (16,'pitch_min_mdeg','i'),(20,'pitch_max_mdeg','i'),(24,'yaw_min_mdeg','i'),(28,'yaw_max_mdeg','i'),
           (32,'max_model_error_q16','I'),(36,'max_time_error_us','I'),(40,'model_source_id','I'),(44,'expected_mcu_config','I')]
    }
    result={name:scalar(offset,fmt) for offset,name,fmt in layouts[kind]}
    if kind == 8:
        result.update(reference_q26=array(48,6),j_pitch_q26=array(72,6),j_yaw_q26=array(96,6))
    return result


def read_entity(uart, kind, *, summary=False):
    """Decode negotiated summaries without inventing unavailable body values."""
    if kind not in ENTITY_LENGTHS or kind == 9:
        raise ValueError('unsupported generic readback kind')
    size = 32 if summary else 32 + ENTITY_LENGTHS[kind]
    record = bytearray()
    for page in range((size + 23) // 24):
        response = uart.exchange(0xA4, struct.pack('<HBB', kind, page, 0))
        if response[1:4] != bytes([0xA4, page, 24]) or response[28:32] != b'AFG1':
            raise ValueError('entity readback page/schema mismatch')
        record.extend(response[4:28])
    schema, returned_kind, version, entity_id, length, flags, error, epoch, frame = struct.unpack_from('<HHIIHBBQQ', record)
    if schema != (2 if summary else 1) or returned_kind != kind or length != (0 if summary else ENTITY_LENGTHS[kind]) or flags & ~(7 if kind == 7 else 3):
        raise ValueError('entity record header mismatch')
    if any(record[size:]):
        raise ValueError('entity trailing page padding is nonzero')
    # The caller supplies a complete explicit draft when writing. Summary
    # firmware never echoes that draft as if it had been read from hardware.
    if summary:
        return dict(kind=kind,name=ENTITY_NAMES[kind],version=version,entity_id=entity_id,
                    exposure_binding_unverified=bool(flags & 4) if kind==7 else None,
                    active_valid=bool(flags & 1),pending=bool(flags & 2),error=error,
                    source_epoch=str(epoch),source_frame_id=str(frame),values=None,body_hex=None,
                    readback='summary',body_available=False)
    # Large u64 identities remain decimal strings in JSON/JavaScript. The
    # motion decoder also preserves the distinction between job and scanout.
    if kind == 11:
        from dataclasses import asdict
        from .motion_status import VISUAL_DISABLED, decode_motion_frame, decode_runtime_action_status
        motion=decode_motion_frame(bytes(record[:size]))
        decoded=asdict(motion) if motion is not None else {'runtime_action':asdict(decode_runtime_action_status(bytes(record[:size])))}
        # Keep historical raw enums, with explicit current unavailable semantics.
        if motion is not None:
            decoded['visual_state'] = 'disabled' if motion.visual_status == VISUAL_DISABLED else 'legacy_or_error'
            decoded['history_registration_available'] = False
        if decoded:
            for key in ('epoch','frame_id','history_epoch','history_frame_id','action_epoch','action_frame_id'):
                if key in decoded:decoded[key]=str(decoded[key])
            action=decoded['runtime_action']
            action['applied_epoch']=str(action['applied_epoch'])
            action['applied_frame_id']=str(action['applied_frame_id'])
    else:
        decoded=decode_entity(kind,bytes(record[32:size]))
    if kind == 6:
        decoded['registration_available'] = False
    return dict(kind=kind, name=ENTITY_NAMES[kind], version=version, entity_id=entity_id,
                exposure_binding_unverified=bool(flags & 4) if kind == 7 else None,
                active_valid=bool(flags & 1), pending=bool(flags & 2), error=error,
                source_epoch=str(epoch), source_frame_id=str(frame), values=decoded, body_hex=bytes(record[32:size]).hex())

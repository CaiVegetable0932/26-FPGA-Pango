"""Frozen schema-1 image entities for A1/A2/A3; byte zero is body byte zero.

Entity identity/version and whole-body CRC32 belong to the common upload
envelope. These builders validate whole drafts before any serial transaction.
"""
import math
import struct


def tone_config(mode=0, curve=0, allowed_mask=7, hysteresis=4, low=96,
                high=144, hold_frames=16, lut_version=0):
    """Build OFF/MANUAL/AUTO policy; curve 3 names an uploaded retained LUT."""
    if mode not in (0, 1, 2) or curve not in range(4):
        raise ValueError("unsupported tone mode or curve")
    if not 1 <= allowed_mask <= 7 or not 0 <= hysteresis <= 255:
        raise ValueError("invalid tone set or hysteresis")
    if not 0 <= low < high <= 255 or not 1 <= hold_frames <= 65535:
        raise ValueError("invalid brightness interval or hold")
    if mode == 2 and not allowed_mask & (1 << curve):
        raise ValueError("initial AUTO curve must belong to allowed set")
    if not 0 <= lut_version <= 0x7fffffff or (curve == 3 and (mode == 2 or not lut_version)):
        raise ValueError("uploaded curve requires MANUAL/OFF and a retained version")
    return struct.pack("<6BH I20x", mode, curve, allowed_mask, hysteresis,
                       low, high, hold_frames, lut_version)


def tone_lut(values=None, *, gamma=None):
    """Generate offline gamma or validate exactly 256 monotonic byte entries."""
    if gamma is not None:
        if values is not None or not math.isfinite(gamma) or not 0.1 <= gamma <= 8:
            raise ValueError("gamma must be finite in [0.1, 8]")
        values = [math.floor(255 * (i / 255) ** gamma + 0.5) for i in range(256)]
    if values is None:
        raise ValueError("supply gamma or 256 entries")
    data = bytes(values)
    if len(data) != 256 or any(a > b for a, b in zip(data, data[1:])):
        raise ValueError("LUT must contain 256 nondecreasing u8 entries")
    return data


def isp_color(black_level=(0, 0, 0, 0), channel_gain=(4096,) * 4,
              ccm=(16384, 0, 0, 0, 16384, 0, 0, 0, 16384), *,
              ccm_enabled=False, wb_mode=0, calibration_id=0,
              awb_min=2048, awb_max=8192, awb_step=16, awb_hold_frames=16):
    """Pack R/Gr/Gb/B gains, black levels and signed row-major Q14 CCM.

    The absolute row-sum limit 8.0 bounds the signed accumulator and is checked
    even when disabled, so a draft can be enabled without reinterpretation.
    """
    if len(black_level) != 4 or len(channel_gain) != 4 or len(ccm) != 9:
        raise ValueError("expected 4 black levels, 4 gains, 9 coefficients")
    if any(not isinstance(v, int) or not 0 <= v <= 255 for v in black_level):
        raise ValueError("black levels must be u8")
    if any(not isinstance(v, int) or not 1 <= v <= 65535 for v in channel_gain):
        raise ValueError("gains must be nonzero U16.12")
    if any(not isinstance(v, int) or not -131072 <= v <= 131071 for v in ccm):
        raise ValueError("CCM coefficient outside S18.14")
    if any(sum(abs(v) for v in ccm[i:i+3]) > 131072 for i in (0, 3, 6)):
        raise ValueError("absolute CCM row sum exceeds 8.0")
    if wb_mode not in (0, 1) or not 0 <= calibration_id <= 0xffffffff:
        raise ValueError("invalid WB mode or calibration ID")
    if not all(isinstance(v, int) and 0 <= v <= 65535 for v in (awb_min, awb_max, awb_step, awb_hold_frames)):
        raise ValueError("AWB limits must be u16")
    if wb_mode and (not 256 <= awb_min <= awb_max <= 65535 or
                    not 1 <= awb_step <= 256 or not awb_hold_frames or
                    any(not awb_min <= v <= awb_max for v in channel_gain)):
        raise ValueError("invalid bounded AWB limits")
    return struct.pack("<4B4HBBH9iI4H", *black_level, *channel_gain,
                       int(bool(ccm_enabled)), wb_mode, 0, *ccm, calibration_id,
                       awb_min, awb_max, awb_step, awb_hold_frames)


def camera_config(mode=0, flicker=0, low=96, high=144, exposure=10752,
                  gain=16, gain_min=16, gain_max=64, gain_step=1,
                  exposure_min=16, exposure_max=17856, exposure_step=256,
                  hold_frames=16, settle_frames=10, line_time_ns=0,
                  period150_code=0, timing_calibration_id=0):
    """Fixed exposure or bounded AE (stopped/group candidate); units are sensor line/16.

    Mode 2 uses continuous grouped writes; optical frame identity is unverified. A 150-Hz tier requires an
    explicitly supplied measured line time/calibration, never a model default.
    """
    if mode not in (0, 1, 2) or flicker not in (0, 1) or not 0 <= low < high <= 255:
        raise ValueError("invalid camera mode or target interval")
    if not 16 <= exposure_min <= exposure <= exposure_max <= 17856:
        raise ValueError("exposure exceeds the fixed VTS-minus-four-lines envelope")
    if not 16 <= gain_min <= gain <= gain_max <= 1023 or not 1 <= gain_step <= 64:
        raise ValueError("invalid sensor gain limits")
    if not 1 <= exposure_step <= 17856 or not 1 <= hold_frames <= 65535 or not 2 <= settle_frames <= 65535:
        raise ValueError("invalid AE step/hold/settle")
    if not all(isinstance(v, int) and 0 <= v <= 0xffffffff for v in (line_time_ns, period150_code, timing_calibration_id)):
        raise ValueError("timing fields must be u32")
    if flicker:
        tiers = {period150_code * n for n in range(1, 5)}
        if not 1 <= line_time_ns <= 1000000 or not 1 <= period150_code <= 17856 or not timing_calibration_id:
            raise ValueError("150 Hz requires measured timing and calibration ID")
        if not {exposure_min, exposure, exposure_max} <= tiers or abs(period150_code * line_time_ns * 150 - 16000000000) > line_time_ns * 150:
            raise ValueError("exposure tiers do not match measured 150-Hz period")
    return struct.pack("<4BI4H3I2H4I", mode, flicker, low, high, exposure,
                       gain, gain_min, gain_max, gain_step, exposure_min,
                       exposure_max, exposure_step, hold_frames, settle_frames,
                       line_time_ns, period150_code, timing_calibration_id, 0)

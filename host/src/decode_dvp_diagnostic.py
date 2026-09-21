"""Decode FPGA diagnostic-only RGB24 rasters; never certify camera imagery.

Reads saved 1280x720 RGB evidence, validates header colors, grid confidence,
magic and schema. No camera access, file modification, or image-source inference.
"""
from __future__ import annotations
import argparse
import json
from pathlib import Path


def decode(data: bytes) -> dict:
    """Read cell centers (robust to MJPEG edge ringing), reject ambiguous/non-diagnostic frames."""
    if len(data) != 1280 * 720 * 3:
        raise ValueError("Expected 1280x720 RGB24")

    def sample(x: int, y: int) -> tuple[int, int, int]:
        sums = [0, 0, 0]
        for dy in range(-2, 3):
            for dx in range(-2, 3):
                pos = ((y + dy) * 1280 + x + dx) * 3
                for c in range(3):
                    sums[c] += data[pos + c]
        return tuple(s // 25 for s in sums)

    head, foot = sample(640, 40), sample(640, 680)
    if not (head[0] > 180 and head[1] < 80 and head[2] > 180
            and foot[0] < 80 and foot[1] > 180 and foot[2] > 180):
        raise ValueError("Not the magenta/cyan FPGA diagnostic raster")
    value = 0
    for row in range(10):
        for col in range(16):
            color = sample(128 + 64 * col + 32, 160 + 32 * row + 16)
            if max(color) - min(color) > 50:
                raise ValueError("Non-gray telemetry cell")
            level = sum(color) / 3
            if 70 < level < 185:
                raise ValueError("Ambiguous telemetry cell")
            value = (value << 1) | int(level >= 185)
    payload = value.to_bytes(20, "big")
    if payload[:3] != bytes.fromhex("d64101"):
        raise ValueError("Diagnostic magic/version mismatch")
    words = [int.from_bytes(payload[i:i + 2], "big") for i in range(4, 18, 2)]
    names = ["first_bad_bytes", "first_bad_row_zero_based", "last_frame_rows",
             "good_frames_after_config", "total_frames_after_config", "last_line_bytes",
             "bad_frames_after_config"]
    result = dict(zip(names, words))
    result.update(packet_hex=payload.hex(), capture_status=payload[3],
                  first_bad_reason=payload[18], first_bad_valid=bool(payload[19] & 1),
                  source_kind="fpga_diagnostic_not_camera", camera_image_verified=False,
                  counter_saturation=any(v == 65535 for v in words))
    if payload[18] not in (0, 1, 2, 3) or payload[19] & ~1:
        raise ValueError("Invalid diagnostic fields")
    result["reason_name"] = ["none", "short_line", "long_line", "wrong_frame_height"][payload[18]]
    return result


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("rgb", type=Path)
    args = parser.parse_args()
    print(json.dumps(decode(args.rgb.read_bytes()), ensure_ascii=False, indent=2))

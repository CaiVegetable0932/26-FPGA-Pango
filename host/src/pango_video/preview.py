"""Small derived display payloads; the received full-resolution RAW stays intact."""


def preview_payload(frame, mode="raw", downscale=2):
    """Move the browser's existing 2x2 Bayer display filter before HTTP transfer.

    This is basic visualization only, never an ISP/source-stage substitution.
    Full RAW APIs and archive bytes remain unchanged. Optional NumPy failure
    falls back to the full source payload with its original metadata.
    """
    if mode not in ("raw", "gray", "color") or downscale not in (1, 2):
        raise ValueError("invalid preview mode/scale")
    h = frame.header
    if downscale == 1 or h.packet_type != 1 or h.width % 2 or h.height % 2:
        return frame.data, {}
    try:
        import numpy as np
    except ImportError:
        return frame.data, {}
    pixels = np.frombuffer(frame.data, dtype=np.uint8).reshape(h.height, h.width)
    cells = (pixels[::2, ::2], pixels[::2, 1::2], pixels[1::2, ::2], pixels[1::2, 1::2])
    if mode == "color":
        layout = {1:(0,1,2,3), 2:(1,0,3,2), 3:(2,0,3,1), 4:(3,1,2,0)}[h.bayer_code]
        green = np.add(cells[layout[1]], cells[layout[2]], dtype=np.uint16)
        np.right_shift(green, 1, out=green)
        display = np.stack((cells[layout[0]], green.astype(np.uint8), cells[layout[3]]), axis=-1)
        kind, stride = "RGB888", h.width // 2 * 3
    else:
        total = np.add(cells[0], cells[1], dtype=np.uint16)
        np.add(total, cells[2], out=total);np.add(total, cells[3], out=total)
        np.right_shift(total, 2, out=total)
        display = total.astype(np.uint8)
        kind, stride = "GRAY8", h.width // 2
    return display.tobytes(), dict(preview_width=h.width//2, preview_height=h.height//2,
        preview_pixel_format=kind, preview_row_stride=stride, preview_derivative=True)

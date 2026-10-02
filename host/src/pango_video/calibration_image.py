"""Bound PNG/JPEG dimensions before OpenCV allocates decoded image memory."""
import struct


def image_size(data):
    """Reject unknown, truncated and oversized containers before native decoding."""
    size = None
    if data.startswith(b"\x89PNG\r\n\x1a\n") and len(data) >= 24 and data[12:16] == b"IHDR":
        size = struct.unpack(">II", data[16:24])
    elif data.startswith(b"\xff\xd8"):
        pos = 2
        while pos < len(data):
            if data[pos] != 255:
                break
            while pos < len(data) and data[pos] == 255:
                pos += 1
            if pos >= len(data):
                break
            marker = data[pos]
            pos += 1
            if marker in (0xd9, 0xda) or pos + 2 > len(data):
                break
            length = int.from_bytes(data[pos:pos+2], "big")
            if length < 2 or pos + length > len(data):
                break
            if marker in (0xc0, 0xc1, 0xc2) and length >= 8:
                height, width = struct.unpack(">HH", data[pos+3:pos+7])
                size = (width, height)
                break
            pos += length
    if size is None or not all(16 <= n <= 4096 for n in size) or size[0] * size[1] > 9000000:
        raise ValueError("仅接受有效 PNG/JPEG；尺寸 16～4096，最多 900 万像素")
    return size


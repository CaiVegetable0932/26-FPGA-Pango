"""Adapt full host evidence to calibration without using downscaled previews."""
import base64
import hashlib

from .record_store import archives, safe_child, sample_metadata
# Historical PRAW TEST generator identity, retained as a source-rejection rule.
TEST_DESCRIPTOR = 0x54534554


def check_source(meta):
    """Reject known test generators and post-correction taps as camera samples."""
    if (meta.get("synthetic") is True or meta.get("source_mode") == "mock"
            or meta.get("descriptor_id") == TEST_DESCRIPTOR
            or meta.get("source_stage") in ("TEST", "MOCK")):
        raise ValueError("TEST / MOCK 合成图不能用于真实相机标定，请切换到摄像头原图")
    descriptor = meta.get("descriptor") or {}
    if not isinstance(descriptor, dict):
        raise ValueError("来源 descriptor 必须为 JSON 对象")
    if meta.get("source_stage") in ("S2", "S3") or descriptor.get("tap") in ("S2", "S3"):
        raise ValueError("请使用几何矫正前的 S0 / S1 图像，不可用 S2 / S3 重新标定镜头")


def request_from_pixels(data, meta, role, name):
    """Validate full-resolution bytes and hash before deriving calibration RGB."""
    check_source(meta)
    if meta.get("transport_complete") is not True:
        raise ValueError("图像未完整接收")
    width, height = meta.get("width"), meta.get("height")
    if (type(width) is not int or type(height) is not int
            or not (16 <= width <= 4096 and 16 <= height <= 4096)
            or width * height > 9000000):
        raise ValueError("标定图像尺寸无效")
    kind = {"RAW8": "raw8", "RGB888": "rgb"}.get(meta.get("pixel_format"))
    if kind is None:
        raise ValueError("仅支持 RAW8 / RGB888 完整原图")
    stride = width * (1 if kind == "raw8" else 3)
    if meta.get("row_stride") != stride or meta.get("frame_bytes") != stride * height or len(data) != stride * height:
        raise ValueError("原始图像字节数或行跨度不匹配")
    if hashlib.sha256(data).hexdigest() != meta.get("sha256"):
        raise ValueError("原始图像 SHA-256 校验失败")
    # Keep the source manifest as a claim; S0 debayering does not certify FPGA S1.
    return dict(kind=kind, width=width, height=height, role=role, name=name,
                bayer_code=meta.get("bayer_code"),
                metadata=meta, payload=base64.b64encode(data).decode("ascii"))


def saved_sources(root):
    """List committed host captures, keeping unsupported sources visibly disabled."""
    result = []
    for item in archives(root):
        if not item["complete"]:
            continue
        try:
            _, meta = sample_metadata(root, item["key"])
            check_source(meta)
            reason = ""
        except (OSError, ValueError, TypeError, KeyError) as error:
            reason = str(error)
        result.append(dict(item, calibration_allowed=not reason, calibration_reason=reason))
    return result


def saved_request(root, key, role):
    """Read only a committed host capture, preserving its archive key and manifest."""
    folder, meta = sample_metadata(root, key)
    path = safe_child(folder, meta["file"])
    return request_from_pixels(path.read_bytes(), dict(meta, archive_key=key, run_id=key.split("/")[0]), role, key)


def live_request(session, role):
    """Freeze the existing receiver's fresh immutable frame; never open a second UDP socket."""
    latest = session.latest()
    if latest is None:
        raise ValueError("没有1秒内的网络完整帧，请在采集工作台开始接收真实摄像头流")
    frame, info = latest
    h = frame.header
    # RAW live streams carry no retired paired RGB control descriptor.
    meta = dict(info, transport_complete=True, packet_crc32_verified=True,
                descriptor_id=h.descriptor_id, descriptor=None,
                bit_depth=h.bit_depth, sha256=hashlib.sha256(frame.data).hexdigest())
    return request_from_pixels(frame.data, meta, role, "网络完整帧 " + info["key"])

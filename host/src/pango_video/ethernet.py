"""Passive PRAW discovery on an explicit local interface and peer; no board writes."""
from collections import Counter
import socket
import time

from .protocol import FormatLimits, PacketType, ProtocolError, decode_datagram

TEST_DESCRIPTOR = 0x54534554


def source_identity(header, source_mode):
    """Preserve TEST identity in previews and evidence, not just on the settings page."""
    # Refuse retired wire types before assigning a live source identity.
    if header.packet_type != PacketType.RAW_LIVE:
        raise ProtocolError("packet_type")
    test = header.descriptor_id == TEST_DESCRIPTOR
    synthetic = test or source_mode == "mock"
    return dict(synthetic=synthetic, source_stage="TEST" if test else "MOCK" if source_mode == "mock" else "S0",
                source_label="FPGA TEST · 合成图（非摄像头）" if test else "MOCK · 本机合成" if source_mode == "mock" else "板端 RAW8 · 来源未验收")


def probe_stream(config, seconds=3.0):
    """Observe several CRC-valid distinct packets; epoch is data-plane observed.

    Never scan the LAN or learn from arbitrary senders. Source/mode/epoch changes
    during probing fail closed. Normal reception still validates every full frame.
    """
    counts = Counter()
    identity = None
    indices = set()
    started = time.monotonic()
    with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
        if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, config["receive_buffer_bytes"])
        sock.bind((config["bind_ip"], config["port"]))
        sock.settimeout(.05)
        while time.monotonic() - started < seconds:
            try:
                packet, peer = sock.recvfrom(65535)
            except socket.timeout:
                continue
            counts["datagrams"] += 1
            if peer != (config["peer_ip"], config["peer_port"]):
                counts["wrong_peer"] += 1
                continue
            try:
                decoded = decode_datagram(packet, FormatLimits(None, None))
            except ProtocolError as error:
                counts["rejected_" + error.reason] += 1
                continue
            h = decoded.header
            if h.packet_type != PacketType.RAW_LIVE:
                counts["not_live_raw"] += 1
                continue
            current = (h.stream_epoch, h.width, h.height, h.bayer_code, h.descriptor_id)
            if identity is not None and current != identity:
                raise ValueError("探测期间源代次/格式发生变化，请停止板端重配置后重试")
            identity = current
            indices.add((h.frame_id, h.packet_index))
            if len(indices) >= 3:
                updated = dict(config, source_mode="hardware_unverified", stream_epoch=h.stream_epoch,
                               width=h.width, height=h.height, bayer_code=h.bayer_code)
                return dict(config=updated, descriptor_id=h.descriptor_id,
                            epoch_origin="observed_crc_valid_udp_not_uart_readback",
                            counters=dict(counts), transport_complete=False,
                            measurement_ready=False, **source_identity(h, "hardware_unverified"))
    raise ValueError("3秒内未从指定 FPGA 收到足够的有效 PRAW 包。请检查网卡地址、端口及板端启动配置；当前通信镜像复位后不会自动发流。统计：" + str(dict(counts)))


def expected_test_pixels(frame_id, width=1920, height=1080):
    """Reference the committed comms_test_source.v moving checker/ramp pattern."""
    rows = [bytes(((x + frame_id) & 255) if ((x >> 5) ^ parity) & 1 else 0x20 for x in range(width)) for parity in (0, 1)]
    return b"".join(rows[(y >> 5) & 1] for y in range(height))

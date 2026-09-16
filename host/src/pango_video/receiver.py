"""Portable IPv4 UDP receive loop and separate bounded consumer queues."""

from collections import Counter, deque
from dataclasses import asdict
import ipaddress
import socket
import threading
import time

from .protocol import PacketType
from .reassembly import CompleteFrame, FrameAssembler


class FrameQueue:
    """Both object-count and payload-byte bounds; immutable frames cross threads."""

    def __init__(self, max_frames: int, max_bytes: int):
        if max_frames <= 0 or max_bytes <= 0:
            raise ValueError("queue limits must be positive")
        self.max_frames = max_frames
        self.max_bytes = max_bytes
        self._frames: deque[CompleteFrame] = deque()
        self._bytes = 0
        self._condition = threading.Condition()

    def offer(self, frame: CompleteFrame, *, replace_oldest: bool = False) -> tuple[bool, int]:
        size = len(frame.data)
        with self._condition:
            if size > self.max_bytes:
                return False, 0
            dropped = 0
            while len(self._frames) >= self.max_frames or self._bytes + size > self.max_bytes:
                if not replace_oldest:
                    return False, 0
                self._bytes -= len(self._frames.popleft().data)
                dropped += 1
            self._frames.append(frame)
            self._bytes += size
            self._condition.notify()
            return True, dropped

    def get(self, timeout: float = 0.0) -> CompleteFrame | None:
        deadline = time.monotonic() + timeout
        with self._condition:
            while not self._frames:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    return None
                self._condition.wait(remaining)
            frame = self._frames.popleft()
            self._bytes -= len(frame.data)
            return frame

    def status(self) -> dict:
        with self._condition:
            return {"frames": len(self._frames), "payload_bytes": self._bytes,
                    "max_frames": self.max_frames, "max_bytes": self.max_bytes}


class UDPReceiver:
    def __init__(self, assembler: FrameAssembler, *, bind: tuple[str, int], peer: tuple[str, int],
                 receive_buffer_bytes: int = 8 * 1024 * 1024, archive_every: int = 0):
        ipaddress.IPv4Address(bind[0])
        ipaddress.IPv4Address(peer[0])
        if not 0 <= bind[1] <= 65535 or not 1 <= peer[1] <= 65535:
            raise ValueError("invalid UDP endpoint")
        if receive_buffer_bytes <= 0 or archive_every < 0:
            raise ValueError("invalid receiver configuration")
        self.assembler = assembler
        self.bind, self.peer = bind, peer
        self.receive_buffer_bytes = receive_buffer_bytes
        self.archive_every = archive_every
        self.stats = Counter()
        max_raw = assembler.format_limits.max_frame_bytes
        self.live_frames = FrameQueue(2, 2 * max_raw)
        self.archive_frames = FrameQueue(4, 16 * 1024 * 1024)
        self.failures: deque[dict] = deque(maxlen=256)
        self.socket: socket.socket | None = None
        self.socket_receive_buffer_reported = 0

    def _failure(self, event: dict):
        if len(self.failures) == self.failures.maxlen:
            self.stats["failure_history_overflow"] += 1
        self.failures.append(event)

    def _drain_failures(self):
        for failure in self.assembler.drain_failures():
            self._failure(asdict(failure))

    def open(self) -> tuple[str, int]:
        if self.socket is not None:
            raise RuntimeError("receiver already open")
        sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        try:
            # Do not silently share a measurement port with another receiver.
            if hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
                sock.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
            sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, self.receive_buffer_bytes)
            self.socket_receive_buffer_reported = sock.getsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF)
            sock.bind(self.bind)
            sock.settimeout(0.01)
        except BaseException:
            sock.close()
            raise
        self.socket = sock
        return sock.getsockname()

    def close(self):
        """Call after run() returns; request stop with its threading.Event."""
        if self.socket is not None:
            self.socket.close()
            self.socket = None

    def _publish(self, frame: CompleteFrame):
        raw = frame.header.packet_type == PacketType.RAW_LIVE
        if raw:
            self.stats["live_frames_complete"] += 1
            accepted, dropped = self.live_frames.offer(frame, replace_oldest=True)
            self.stats["preview_frames_replaced"] += dropped
            if not accepted:
                self.stats["preview_frames_rejected"] += 1
        archive = not raw or (self.archive_every > 0 and
                             (self.stats["live_frames_complete"] - 1) % self.archive_every == 0)
        if archive:
            accepted, _ = self.archive_frames.offer(frame)
            if not accepted:
                self.stats["archive_frames_rejected"] += 1
                self._failure({"key": frame.header.key, "reason": "archive_queue_full"})
            else:
                self.stats["archive_frames_enqueued"] += 1

    def run(self, stop: threading.Event, *, duration: float | None = None,
            on_status=None, status_interval: float = 0.25):
        if self.socket is None:
            raise RuntimeError("call open() before run()")
        if duration is not None and duration <= 0:
            raise ValueError("duration must be positive or None")
        if status_interval <= 0:
            raise ValueError("status_interval must be positive")
        next_status = 0.0
        # Holds the largest IPv4 UDP payload plus margin. Reading only 1464 bytes
        # could truncate an oversized datagram into an apparently valid packet.
        buffer = bytearray(65535)
        deadline = None if duration is None else time.monotonic() + duration
        try:
            while not stop.is_set() and (deadline is None or time.monotonic() < deadline):
                if on_status is not None and time.monotonic() >= next_status:
                    on_status(self.status())  # Snapshot from the socket/assembler owner.
                    next_status = time.monotonic() + status_interval
                try:
                    size, peer = self.socket.recvfrom_into(buffer)
                except socket.timeout:
                    self.assembler.expire()
                    self._drain_failures()
                    continue
                except OSError:
                    self.stats["socket_errors"] += 1
                    raise
                self.stats["datagrams_received"] += 1
                self.stats["udp_payload_bytes_received"] += size
                if peer != self.peer:
                    self.stats["datagrams_wrong_peer"] += 1
                    # Foreign traffic must not prevent timeout of admitted frames.
                    self.assembler.expire()
                else:
                    frame = self.assembler.feed(memoryview(buffer)[:size])
                    if frame is not None:
                        self._publish(frame)
                self._drain_failures()
        finally:
            self.assembler.abort("stopped")
            self._drain_failures()

    def status(self) -> dict:
        """Read after run() returns, or inside the owner-thread on_status callback."""
        return {"bind": self.bind, "peer": self.peer, "counters": dict(self.stats),
                "socket_receive_buffer_requested": self.receive_buffer_bytes,
                "socket_receive_buffer_reported": self.socket_receive_buffer_reported,
                "assembly": self.assembler.status(), "preview_queue": self.live_frames.status(),
                "archive_queue": self.archive_frames.status(), "recent_failures": list(self.failures)}

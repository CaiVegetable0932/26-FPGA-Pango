"""Linux recvmmsg batching; wire validation remains in FrameAssembler.

Use glibc's public ABI through ctypes, with no driver dependency. A locally
built, hash-verified C hot path is optional; missing builds retain Python checks.
The batch holds only 256 x 2048 bytes. MSG_TRUNC preserves the original length
so an oversized datagram can never appear to be a valid 1464-byte PRAW packet.
"""
import ctypes as c
import errno
import select
import socket
import sys
import hashlib
import json
from pathlib import Path
import platform


class _Address(c.Structure):
    _fields_ = [("family", c.c_ushort), ("port", c.c_ushort),
                ("address", c.c_uint32), ("zero", c.c_ubyte * 8)]


class _Vector(c.Structure):
    _fields_ = [("base", c.c_void_p), ("length", c.c_size_t)]


class _Message(c.Structure):
    # Native alignment is essential on both Linux ARM64 and x86_64.
    _fields_ = [("name", c.c_void_p), ("name_length", c.c_uint),
                ("vectors", c.POINTER(_Vector)), ("vector_count", c.c_size_t),
                ("control", c.c_void_p), ("control_length", c.c_size_t), ("flags", c.c_int)]


class _MultiMessage(c.Structure):
    _fields_ = [("header", _Message), ("length", c.c_uint)]


class _FastResult(c.Structure):
    _fields_ = [(name, c.c_uint32) for name in ("consumed", "accepted", "duplicates",
                "retransmitted", "out_of_order", "rejected_crc", "complete", "conflict")] + [
                ("highest_index", c.c_int32), ("payload_bytes", c.c_uint64), ("complete_ns", c.c_uint64)]


def load_native(diagnostics=None):
    """Use only the current-source, current-architecture, hash-verified build."""
    # Expose why the safe reference path is selected; a present .so alone is
    # never evidence that the admitted native parser is actually active.
    report = diagnostics if diagnostics is not None else {}
    report.update(enabled=False, reason="not_loaded", machine=platform.machine(), abi=1)
    source = Path(__file__).with_name("raw_batch.c")
    folder = Path(__file__).resolve().parents[2] / "build/udp-fast"
    try:
        manifest = json.loads((folder / "manifest.json").read_text())
        target = folder / "libpango_raw_batch.so"
        report["source_sha256"] = hashlib.sha256(source.read_bytes()).hexdigest()
        report["binary_sha256"] = hashlib.sha256(target.read_bytes()).hexdigest()
        for valid, reason in ((manifest["machine"] == platform.machine(), "architecture_mismatch"),
                (manifest["abi"] == 1, "abi_mismatch"),
                (report["source_sha256"] == manifest["source_sha256"], "source_hash_mismatch"),
                (report["binary_sha256"] == manifest["binary_sha256"], "binary_hash_mismatch")):
            if not valid:
                report["reason"] = reason
                return None
        library = c.CDLL(str(target))
        function = library.pango_raw_apply
        function.argtypes = [c.POINTER(_MultiMessage), c.c_uint32, c.c_uint32,
            c.c_uint32, c.c_uint16, c.c_void_p, c.c_void_p, c.c_uint32, c.c_void_p,
            c.c_uint32, c.c_uint32, c.c_int32, c.c_uint64, c.POINTER(_FastResult)]
        function.restype = None
        report.update(enabled=True, reason="verified")
        return function
    except (OSError, ValueError, KeyError, AttributeError, TypeError) as error:
        report.update(reason="missing_build" if isinstance(error, FileNotFoundError) else "invalid_build",
                      error_type=type(error).__name__)
        return None


class LinuxDatagramBatch:
    """Borrowed packet views last until the next receive call, as recvfrom_into."""
    # At 1080p30 the FPGA sends about 44,460 datagrams/s. Drain larger queued
    # bursts after compositor/HTTP scheduling delays, amortizing ctypes/GIL
    # transitions without waiting for a full batch or increasing frame queues.
    SIZE = 256
    PAYLOAD = 2048

    def __init__(self, sock, peer):
        libc = c.CDLL(None, use_errno=True)
        self._receive = libc.recvmmsg
        self._receive.argtypes = [c.c_int, c.POINTER(_MultiMessage), c.c_uint, c.c_int, c.c_void_p]
        self._receive.restype = c.c_int
        self.fd = sock.fileno()
        self._poll = select.poll()
        self._poll.register(self.fd, select.POLLIN)
        self._addresses = (_Address * self.SIZE)()
        self._buffers = ((c.c_ubyte * self.PAYLOAD) * self.SIZE)()
        self._vectors = (_Vector * self.SIZE)()
        self._messages = (_MultiMessage * self.SIZE)()
        self._views = []
        for index in range(self.SIZE):
            self._views.append(memoryview(self._buffers[index]).cast("B"))
            self._vectors[index] = _Vector(c.addressof(self._buffers[index]), self.PAYLOAD)
            self._messages[index].header = _Message(c.addressof(self._addresses[index]),
                c.sizeof(_Address), c.pointer(self._vectors[index]), 1, None, 0, 0)
        self._peer_address = int.from_bytes(socket.inet_aton(peer[0]), sys.byteorder)
        self._peer_port = socket.htons(peer[1])
        self.native_status = {}
        self.native = load_native(self.native_status)

    def consume_raw(self, state, start, count, deadline_ns):
        """Apply consecutive valid chunks in C; borrowed bytearrays stay pinned."""
        if self.native is None or state is None or state.wire_header is None:
            return None
        # Keep pointers on the assembly, avoiding repeated ctypes exports.
        if state.native_buffers is None:
            state.native_buffers = ((c.c_ubyte * len(state.data)).from_buffer(state.data),
                                    (c.c_ubyte * len(state.seen)).from_buffer(state.seen))
        data, seen = state.native_buffers
        result = _FastResult()
        self.native(self._messages, start, count, self._peer_address, self._peer_port,
            state.wire_header, data, state.header.frame_bytes, seen, state.header.packet_count,
            state.received, state.highest_index, deadline_ns, c.byref(result))
        return result

    def receive(self):
        """Read queued bursts in one GIL-releasing syscall; wait at most 10 ms."""
        flags = socket.MSG_DONTWAIT | socket.MSG_TRUNC
        count = self._receive(self.fd, self._messages, self.SIZE, flags, None)
        if count < 0 and c.get_errno() in (errno.EAGAIN, errno.EWOULDBLOCK):
            if not self._poll.poll(10):
                return 0
            count = self._receive(self.fd, self._messages, self.SIZE, flags, None)
        if count < 0:
            error = c.get_errno()
            if error in (errno.EAGAIN, errno.EWOULDBLOCK, errno.EINTR):
                return 0
            raise OSError(error, "recvmmsg failed")
        return count

    def packet(self, index):
        """Compare binary IPv4 peer identity without formatting per-packet IPs."""
        address = self._addresses[index]
        size = self._messages[index].length
        peer_matches = (address.family == socket.AF_INET and address.address == self._peer_address
                        and address.port == self._peer_port)
        return self._views[index][:size], size, peer_matches

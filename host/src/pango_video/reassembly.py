"""Single-owner bounded frame assembly. No socket, GUI, disk or UART work here."""

from collections import Counter, deque
from dataclasses import dataclass, field
import time
from struct import Struct

from .protocol import (FormatLimits, Header, PacketType, ProtocolError,
                       decode_datagram)
from .protocol import CHUNK_BYTES, HEADER_BYTES, MAX_DATAGRAM_BYTES, packet_crc32

# Decode only varying chunk fields for the common already-admitted RAW frame.
# All immutable bytes and every packet CRC are still verified on this path.
_CHUNK_POSITION = Struct("<IH")
_CHUNK_INDEX = Struct("<H")


@dataclass(frozen=True, slots=True)
class AssemblyLimits:
    max_live_frames: int = 4
    max_buffer_bytes: int = 32 * 1024 * 1024
    live_timeout_ns: int = 100_000_000
    live_window: int = 64
    max_events: int = 128

    def __post_init__(self):
        if any(value <= 0 for value in (self.max_live_frames, self.max_buffer_bytes,
               self.live_timeout_ns, self.live_window, self.max_events)):
            raise ValueError("assembly limits must be positive")
        if self.max_live_frames > self.live_window:
            raise ValueError("live_window must cover max_live_frames")


@dataclass(frozen=True, slots=True)
class CompleteFrame:
    header: Header
    data: bytes
    first_receive_ns: int
    complete_ns: int


@dataclass(frozen=True, slots=True)
class FrameFailure:
    key: tuple[int, int, int, int]
    reason: str
    received_packets: int
    packet_count: int
    missing_ranges: tuple[tuple[int, int], ...]


@dataclass(slots=True)
class _Assembly:
    header: Header
    deadline_ns: int
    first_receive_ns: int | None = None
    data: bytearray = field(init=False)
    seen: bytearray = field(init=False)
    received: int = 0
    highest_index: int = -1
    wire_header: bytes | None = None
    native_buffers: object = None

    def __post_init__(self):
        self.data = bytearray(self.header.frame_bytes)
        self.seen = bytearray(self.header.packet_count)

    def missing_ranges(self) -> tuple[tuple[int, int], ...]:
        """(start_index, count), suitable for bounded control-plane missing reads."""
        ranges = []
        start = None
        for index, received in enumerate(self.seen):
            if not received and start is None:
                start = index
            if received and start is not None:
                ranges.append((start, index - start))
                start = None
        if start is not None:
            ranges.append((start, len(self.seen) - start))
        return tuple(ranges)


class FrameAssembler:
    def __init__(self, *, device_id: str, stream_epoch: int,
                 format_limits: FormatLimits = FormatLimits(),
                 limits: AssemblyLimits = AssemblyLimits()):
        if not device_id or type(stream_epoch) is not int or not 0 <= stream_epoch < 2**64:
            raise ValueError("device identity and a valid explicit source epoch are required")
        self.device_id = device_id
        self.stream_epoch = stream_epoch
        self.format_limits = format_limits
        self.limits = limits
        self.stats = Counter()
        self._active: dict[tuple, _Assembly] = {}
        self._terminal: dict[tuple, tuple] = {}
        self._events: deque[FrameFailure] = deque(maxlen=limits.max_events)
        self.buffer_bytes = 0
        self.live_highwater: int | None = None
        self.live_first_id: int | None = None
        self.live_observed = 0
        self._fast_live = None
        self._next_deadline_ns = 0

    @property
    def active_frames(self) -> int:
        return len(self._active)

    def drain_failures(self) -> list[FrameFailure]:
        events = list(self._events)
        self._events.clear()
        return events

    def _remove(self, key: tuple) -> _Assembly:
        state = self._active.pop(key)
        if self._fast_live is state:
            self._fast_live = None
        self.buffer_bytes -= len(state.data)
        self._terminal[state.header.identity] = state.header.key
        return state

    def _fail(self, key: tuple, reason: str):
        state = self._remove(key)
        self.stats[f"frames_failed_{reason}"] += 1
        if len(self._events) == self._events.maxlen:
            self.stats["failure_events_overflow"] += 1
        self._events.append(FrameFailure(key, reason, state.received,
                                        state.header.packet_count, state.missing_ranges()))

    def expire(self, now_ns: int | None = None):
        now = time.monotonic_ns() if now_ns is None else now_ns
        # No allocation/active-frame scan before the earliest possible expiry.
        # A removed earliest deadline may cause one harmless early rescan.
        if now < self._next_deadline_ns:
            return
        for key, state in list(self._active.items()):
            if now >= state.deadline_ns:
                self._fail(key, "timeout")
        self._next_deadline_ns = min((s.deadline_ns for s in self._active.values()), default=0)

    def abort(self, reason: str = "stopped"):
        for key in list(self._active):
            self._fail(key, reason)

    def set_live_epoch(self, epoch: int):
        """Only a confirmed control-plane source restart may call this method.

        A PC reconnect must create a new receiver session without changing FPGA
        identity. Existing live frames expire when the confirmed epoch changes.
        """
        if type(epoch) is not int or not 0 <= epoch < 2**64:
            raise ValueError("invalid stream epoch")
        if epoch == self.stream_epoch:
            return
        for key in list(self._active):
            if key[2] == PacketType.RAW_LIVE:
                self._fail(key, "epoch_change")
        self._terminal = {k: v for k, v in self._terminal.items() if k[2] != PacketType.RAW_LIVE}
        self.stream_epoch = epoch
        self.live_highwater = self.live_first_id = None
        self.live_observed = 0
        self.stats["source_epoch_changes"] += 1

    def missing_ranges(self, key: tuple) -> tuple[tuple[int, int], ...]:
        state = self._active.get(key)
        return state.missing_ranges() if state is not None else ()

    def _live_window(self, h: Header) -> bool:
        if self.live_highwater is not None and h.frame_id <= self.live_highwater - self.limits.live_window:
            self.stats["packets_stale"] += 1
            return False
        if self.live_highwater is None or h.frame_id > self.live_highwater:
            self.live_highwater = h.frame_id
            floor = h.frame_id - self.limits.live_window + 1
            for key in list(self._active):
                if key[2] == PacketType.RAW_LIVE and key[1] < floor:
                    self._fail(key, "reorder_window")
            for identity in list(self._terminal):
                if identity[2] == PacketType.RAW_LIVE and identity[1] < floor:
                    del self._terminal[identity]
        return True

    def feed(self, datagram: bytes | bytearray | memoryview,
             now_ns: int | None = None) -> CompleteFrame | None:
        now = time.monotonic_ns() if now_ns is None else now_ns
        self.expire(now)
        self.stats["datagrams"] += 1
        # A frame has 1482 packets at 1080p. Reusing its validated invariant
        # avoids 1481 frozen dataclass constructions and whole-header checks.
        # Any changed/invalid field falls back to the authoritative decoder,
        # preserving rejection reasons, conflicts, epoch and replay handling.
        state = self._fast_live
        view = memoryview(datagram)
        if state is not None and HEADER_BYTES < len(view) <= MAX_DATAGRAM_BYTES:
            template = state.wire_header
            if (view[:9] == template[:9] and view[10:44] == template[10:44]
                    and view[50:52] == template[50:52] and view[54:56] == template[54:56]
                    and view[60:64] == template[60:64]):
                index = _CHUNK_INDEX.unpack_from(view, 52)[0]
                offset, size = _CHUNK_POSITION.unpack_from(view, 44)
                flags = view[9]
                if (index < state.header.packet_count and offset == index * CHUNK_BYTES
                        and size == min(CHUNK_BYTES, state.header.frame_bytes - offset)
                        and len(view) == HEADER_BYTES + size and not flags & ~3
                        and bool(flags & 2) == (index == state.header.packet_count - 1)):
                    if packet_crc32(view) != int.from_bytes(view[56:60], "little"):
                        self.stats["packets_rejected_crc"] += 1
                        return None
                    return self._accept(state, index, offset, view[HEADER_BYTES:], flags, now, True)
        try:
            packet = decode_datagram(datagram, self.format_limits)
        except ProtocolError as error:
            self.stats[f"packets_rejected_{error.reason}"] += 1
            return None
        h = packet.header
        raw = h.packet_type == PacketType.RAW_LIVE
        if raw:
            if h.stream_epoch != self.stream_epoch:
                self.stats["packets_wrong_epoch"] += 1
                return None
            if not self._live_window(h):
                return None
        if h.identity in self._terminal:
            self.stats["packets_late_terminal"] += 1
            if self._terminal[h.identity] != h.key:
                self.stats["packets_descriptor_conflict"] += 1
            return None
        state = self._active.get(h.key)
        if state is None:
            # One live source image cannot fork into different descriptor identities.
            conflict = next((k for k in self._active if k[:3] == h.identity), None)
            if conflict is not None:
                self._fail(conflict, "metadata_conflict")
                return None
            self.live_first_id = h.frame_id if self.live_first_id is None else min(self.live_first_id, h.frame_id)
            self.live_observed += 1
            live_keys = [k for k in self._active if k[2] == PacketType.RAW_LIVE]
            if len(live_keys) >= self.limits.max_live_frames:
                self._fail(live_keys[0], "capacity")
            if self.buffer_bytes + h.frame_bytes > self.limits.max_buffer_bytes:
                self._terminal[h.identity] = h.key
                self.stats["frames_rejected_memory"] += 1
                if len(self._events) == self._events.maxlen:
                    self.stats["failure_events_overflow"] += 1
                self._events.append(FrameFailure(h.key, "memory_rejected", 0,
                                                 h.packet_count, ((0, h.packet_count),)))
                return None
            state = _Assembly(h, now + self.limits.live_timeout_ns)
            self._active[h.key] = state
            self.buffer_bytes += h.frame_bytes
            self.stats["live_frames_observed"] += 1
            self._next_deadline_ns = min(s.deadline_ns for s in self._active.values())
        if state.header.invariant != h.invariant:
            self._fail(h.key, "metadata_conflict")
            return None
        if raw:
            state.wire_header = bytes(view[:HEADER_BYTES])
            self._fast_live = state
        return self._accept(state, h.packet_index, h.payload_offset, packet.payload, h.flags, now, raw)

    def _accept(self, state, index, start, payload, flags, now, raw):
        """One common commit path keeps duplicate, ordering and evidence checks."""
        h = state.header
        end = start + len(payload)
        if state.seen[index]:
            if memoryview(state.data)[start:end] != payload:
                self._fail(h.key, "duplicate_conflict")
            else:
                self.stats["packets_duplicate"] += 1
            return None
        if state.first_receive_ns is None:
            state.first_receive_ns = now
        if index < state.highest_index:
            self.stats["packets_out_of_order"] += 1
        state.highest_index = max(state.highest_index, index)
        state.data[start:end] = payload
        state.seen[index] = 1
        state.received += 1
        self.stats["packets_accepted_unique"] += 1
        if flags & 1:
            self.stats["packets_retransmitted"] += 1
        if state.received != h.packet_count:
            return None
        state = self._remove(h.key)
        self.stats["live_frames_complete"] += 1
        self.stats["live_bytes_complete"] += h.frame_bytes
        return CompleteFrame(state.header, bytes(state.data), state.first_receive_ns,
                             now)

    def feed_batch(self, batch, start, count):
        """Native equivalent of the admitted-RAW hot path; exceptional packets
        still pass through feed(). Returns consumed datagrams, bytes and frame.
        """
        # Native execution stops at the earliest RAW deadline, matching feed().
        self.expire()
        state = self._fast_live
        result = batch.consume_raw(state, start, count, self._next_deadline_ns)
        if result is None or not result.consumed:
            return 0, 0, None
        self.stats["datagrams"] += result.consumed
        for name, value in (("packets_accepted_unique", result.accepted),
                ("packets_duplicate", result.duplicates), ("packets_retransmitted", result.retransmitted),
                ("packets_out_of_order", result.out_of_order), ("packets_rejected_crc", result.rejected_crc)):
            if value:
                self.stats[name] += value
        state.received += result.accepted
        state.highest_index = result.highest_index
        frame = None
        if result.conflict:
            self._fail(state.header.key, "duplicate_conflict")
        elif result.complete:
            self._remove(state.header.key)
            self.stats["live_frames_complete"] += 1
            self.stats["live_bytes_complete"] += state.header.frame_bytes
            frame = CompleteFrame(state.header, bytes(state.data), state.first_receive_ns,
                                  result.complete_ns)
        return result.consumed, result.payload_bytes, frame

    def status(self) -> dict:
        span = 0 if self.live_first_id is None else self.live_highwater - self.live_first_id + 1
        return {"counters": dict(self.stats), "active_frames": self.active_frames,
                "buffer_bytes": self.buffer_bytes, "stream_epoch": self.stream_epoch,
                "live_first_id": self.live_first_id, "live_highwater": self.live_highwater,
                "live_unobserved_ids_in_span": max(0, span - self.live_observed)}

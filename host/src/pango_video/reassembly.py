"""Single-owner bounded frame assembly. No socket, GUI, disk or UART work here."""

from collections import Counter, deque
from dataclasses import dataclass, field
import json
import time

from .protocol import (FormatLimits, Header, PacketType, ProtocolError,
                       decode_datagram, frame_header, validate_header)


@dataclass(frozen=True, slots=True)
class AssemblyLimits:
    max_live_frames: int = 4
    max_buffer_bytes: int = 32 * 1024 * 1024
    live_timeout_ns: int = 100_000_000
    snapshot_timeout_ns: int = 2_000_000_000
    live_window: int = 64
    max_events: int = 128

    def __post_init__(self):
        if any(value <= 0 for value in (self.max_live_frames, self.max_buffer_bytes,
               self.live_timeout_ns, self.snapshot_timeout_ns, self.live_window, self.max_events)):
            raise ValueError("assembly limits must be positive")
        if self.max_live_frames > self.live_window:
            raise ValueError("live_window must cover max_live_frames")


@dataclass(frozen=True, slots=True)
class SnapshotSpec:
    header: Header
    descriptor_json: str

    @classmethod
    def from_dict(cls, data: dict) -> "SnapshotSpec":
        """Control-adapter input after READY/readback; this does not perform a handshake.

        Keep full parameter/timestamp entities in this object. This minimal identity
        gate alone never marks a frame eligible for scientific measurements.
        """
        for name in ("device_id", "snapshot_id", "parameter_snapshot_hash"):
            if not isinstance(data.get(name), str) or not data[name]:
                raise ValueError(f"missing descriptor field: {name}")
        if data.get("tap") not in ("S1", "S2", "S3"):
            raise ValueError("snapshot tap must be S1, S2 or S3")
        if data.get("enhancement_stage") not in ("disabled", "pre_resample", "post_resample"):
            raise ValueError("invalid enhancement_stage")
        for name in ("stream_epoch", "frame_id", "width", "height", "param_version", "descriptor_id"):
            if type(data.get(name)) is not int:
                raise ValueError(f"descriptor {name} must be an integer")
        h = frame_header(stream_epoch=data["stream_epoch"], frame_id=data["frame_id"],
                         width=data["width"], height=data["height"],
                         packet_type=PacketType.SNAP_S1 if data["tap"] == "S1" else PacketType.SNAP_RESULT,
                         param_version=data["param_version"], descriptor_id=data["descriptor_id"])
        return cls(h, json.dumps(data, ensure_ascii=False, sort_keys=True, allow_nan=False))

    @property
    def descriptor(self) -> dict:
        return json.loads(self.descriptor_json)


def validate_specs(s1: SnapshotSpec, result: SnapshotSpec, device_id: str) -> None:
    if s1.header.packet_type != PacketType.SNAP_S1 or result.header.packet_type != PacketType.SNAP_RESULT:
        raise ValueError("pair must contain S1 and one result tap")
    a, b = s1.descriptor, result.descriptor
    for name in ("device_id", "snapshot_id", "stream_epoch", "frame_id", "parameter_snapshot_hash",
                 "enhancement_stage"):
        if a[name] != b[name]:
            raise ValueError(f"snapshot pair mismatch: {name}")
    if a["device_id"] != device_id:
        raise ValueError("snapshot belongs to a different device")
    # Stage-specific param_version values need not be numerically equal.


@dataclass(frozen=True, slots=True)
class CompleteFrame:
    header: Header
    data: bytes
    first_receive_ns: int
    complete_ns: int
    descriptor_json: str | None = None


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
    descriptor_json: str | None = None
    data: bytearray = field(init=False)
    seen: bytearray = field(init=False)
    received: int = 0
    highest_index: int = -1

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
        self._snapshot_keys: set[tuple] = set()
        self._events: deque[FrameFailure] = deque(maxlen=limits.max_events)
        self.buffer_bytes = 0
        self.live_highwater: int | None = None
        self.live_first_id: int | None = None
        self.live_observed = 0

    @property
    def active_frames(self) -> int:
        return len(self._active)

    def drain_failures(self) -> list[FrameFailure]:
        events = list(self._events)
        self._events.clear()
        return events

    def _remove(self, key: tuple) -> _Assembly:
        state = self._active.pop(key)
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
        for key, state in list(self._active.items()):
            if now >= state.deadline_ns:
                self._fail(key, "timeout")

    def abort(self, reason: str = "stopped"):
        for key in list(self._active):
            self._fail(key, reason)

    def set_live_epoch(self, epoch: int):
        """Only a confirmed control-plane source restart may call this method.

        A PC reconnect must create a new receiver session without changing FPGA
        identity. Pending snapshots keep their original epoch and deadline.
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

    def admit_snapshot(self, s1: SnapshotSpec, result: SnapshotSpec, now_ns: int | None = None):
        """One pair at a time. Admission starts the timeout even if every packet is lost."""
        if self._snapshot_keys:
            raise ValueError("previous snapshot must be explicitly closed first")
        validate_specs(s1, result, self.device_id)
        for spec in (s1, result):
            validate_header(spec.header, spec.header.payload_bytes, self.format_limits)
        required = s1.header.frame_bytes + result.header.frame_bytes
        if self.buffer_bytes + required > self.limits.max_buffer_bytes:
            raise ValueError("insufficient snapshot buffer budget")
        now = time.monotonic_ns() if now_ns is None else now_ns
        states = [_Assembly(spec.header, now + self.limits.snapshot_timeout_ns,
                            descriptor_json=spec.descriptor_json) for spec in (s1, result)]
        for state in states:
            self._active[state.header.key] = state
            self._snapshot_keys.add(state.header.key)
            self._terminal.pop(state.header.identity, None)
        self.buffer_bytes += required

    def close_snapshot(self):
        """Local cancellation/cleanup only; never sends a board RELEASE command."""
        for key in self._snapshot_keys:
            if key in self._active:
                self._fail(key, "snapshot_closed")
            self._terminal.pop(key[:3], None)
        self._snapshot_keys.clear()

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
        elif h.key not in self._snapshot_keys:
            self.stats["packets_unadmitted_snapshot"] += 1
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
        if state.header.invariant != h.invariant:
            self._fail(h.key, "metadata_conflict")
            return None
        index = h.packet_index
        start, end = h.payload_offset, h.payload_offset + h.payload_bytes
        if state.seen[index]:
            if memoryview(state.data)[start:end] != packet.payload:
                self._fail(h.key, "duplicate_conflict")
            else:
                self.stats["packets_duplicate"] += 1
            return None
        if state.first_receive_ns is None:
            state.first_receive_ns = now
        if index < state.highest_index:
            self.stats["packets_out_of_order"] += 1
        state.highest_index = max(state.highest_index, index)
        state.data[start:end] = packet.payload
        state.seen[index] = 1
        state.received += 1
        self.stats["packets_accepted_unique"] += 1
        if h.flags & 1:
            self.stats["packets_retransmitted"] += 1
        if state.received != h.packet_count:
            return None
        state = self._remove(h.key)
        self.stats["live_frames_complete" if raw else "snapshot_frames_complete"] += 1
        self.stats["live_bytes_complete" if raw else "snapshot_bytes_complete"] += h.frame_bytes
        return CompleteFrame(state.header, bytes(state.data), state.first_receive_ns,
                             now, state.descriptor_json)

    def status(self) -> dict:
        span = 0 if self.live_first_id is None else self.live_highwater - self.live_first_id + 1
        return {"counters": dict(self.stats), "active_frames": self.active_frames,
                "buffer_bytes": self.buffer_bytes, "stream_epoch": self.stream_epoch,
                "live_first_id": self.live_first_id, "live_highwater": self.live_highwater,
                "live_unobserved_ids_in_span": max(0, span - self.live_observed)}

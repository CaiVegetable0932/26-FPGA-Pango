"""Independently replay GMII RTL output using struct/zlib, without DUT internals."""
from __future__ import annotations

import argparse
import csv
import hashlib
import json
import struct
import zlib
from collections import Counter, deque
from dataclasses import dataclass, field
from pathlib import Path


def require(condition: bool, message: str) -> None:
    """Checks remain enabled even with Python's optimization switch."""
    if not condition:
        raise ValueError(message)


def internet_checksum(data: bytes) -> int:
    """Sum network-order words, independently of the RTL's balanced adder."""
    total = sum(struct.unpack(f"!{len(data) // 2}H", data))
    while total >> 16:
        total = (total & 0xFFFF) + (total >> 16)
    return (~total) & 0xFFFF


@dataclass
class Packet:
    """Accepted metadata and payload reconstructed only from actual handshakes."""
    length: int
    src_mac: int
    dst_mac: int
    src_ip: int
    dst_ip: int
    src_port: int
    dst_port: int
    accepted: int
    phase: int
    payload: bytearray = field(default_factory=bytearray)
    complete: int = 0
    idle: int = 0


def validate_frame(wire: bytes, packet: Packet) -> dict:
    """Check every byte, network order, unpadded lengths, padding and wire FCS."""
    require(wire[:8] == b"\x55" * 7 + b"\xd5", "preamble/SFD")
    require(len(wire) == 8 + max(60, 42 + packet.length) + 4, "wire length")
    body, fcs = wire[8:-4], wire[-4:]
    require(fcs == struct.pack("<I", zlib.crc32(body)), "Ethernet FCS or byte order")
    require(body[:6] == packet.dst_mac.to_bytes(6, "big"), "destination MAC")
    require(body[6:12] == packet.src_mac.to_bytes(6, "big"), "source MAC")
    require(body[12:14] == b"\x08\x00", "EtherType")
    ip = body[14:34]
    require(internet_checksum(ip) == 0, "IPv4 checksum")
    fields = struct.unpack("!BBHHHBBHII", ip)
    require(fields[:7] == (0x45, 0, packet.length + 28, 0, 0x4000, 64, 17),
            "IPv4 version/IHL, DSCP, length, ID, flags, TTL or protocol")
    require(fields[8:] == (packet.src_ip, packet.dst_ip), "IPv4 addresses")
    expected_header = struct.pack("!BBHHHBBHII", 0x45, 0, packet.length + 28,
                                  0, 0x4000, 64, 17, 0, packet.src_ip, packet.dst_ip)
    require(fields[7] == internet_checksum(expected_header), "IPv4 checksum byte order")
    require(struct.unpack("!HHHH", body[34:42]) ==
            (packet.src_port, packet.dst_port, packet.length + 8, 0), "UDP header")
    require(body[42:42 + packet.length] == packet.payload, "payload/packet ordering")
    padding = body[42 + packet.length:]
    require(padding == bytes(max(0, 18 - packet.length)), "zero Ethernet padding")
    return {"payload_bytes": packet.length, "wire_bytes": len(wire),
            "padding_bytes": len(padding), "fcs_hex": fcs.hex()}


def reject_corruptions(wire: bytes, packet: Packet) -> int:
    """Prove bad fields are rejected even if their Ethernet FCS is repaired."""
    variants = []
    for offset in (0, 8, 24, 42, 50, len(wire) - 1):
        corrupted = bytearray(wire)
        corrupted[offset] ^= 1
        if 8 <= offset < len(wire) - 4:
            corrupted[-4:] = struct.pack("<I", zlib.crc32(corrupted[8:-4]))
        variants.append(bytes(corrupted))
    corrupted = bytearray(wire)
    corrupted[8 + 42 + packet.length] = 1
    corrupted[-4:] = struct.pack("<I", zlib.crc32(corrupted[8:-4]))
    variants.append(bytes(corrupted))
    for number, corrupted in enumerate(variants):
        try:
            validate_frame(corrupted, packet)
        except ValueError:
            continue
        raise ValueError(f"negative checker test {number} accepted corruption")
    return len(variants)


def check_trace(trace: Path, timeout: int) -> dict:
    """Model queue ownership, receive timeout and framing on every observed edge."""
    pending, active = None, None
    queue = deque()
    wire = bytearray()
    frames, gaps = [], []
    counts, invalid_lengths = Counter(), Counter()
    last_end = None
    previous_en = False
    last_cycle = negative_checks = active_start = 0
    timeout = max(1, timeout)
    hex_fields = {"src_mac", "dst_mac", "src_ip", "dst_ip",
                  "src_port", "dst_port", "data", "tx_data"}
    with trace.open(newline="", encoding="utf-8-sig") as stream:
        for raw in csv.DictReader(stream):
            row = {key: int(value, 16 if key in hex_fields else 10)
                   for key, value in raw.items()}
            cycle = row["cycle"]
            require(cycle == last_cycle + 1, "missing or duplicate trace clocks")
            last_cycle = cycle
            require(row["tx_er"] == 0, f"cycle {cycle}: tx_er")
            if not row["reset_n"]:
                require(not any(row[key] for key in
                                ("start_ready", "payload_ready", "tx_en", "busy", "done", "error")),
                        f"cycle {cycle}: reset outputs")
                counts["reset_incomplete_receives"] += int(pending is not None)
                counts["reset_truncated_frames"] += int(active is not None)
                counts["reset_queued_packets"] += len(queue)
                pending, active, last_end = None, None, None
                queue.clear()
                wire.clear()
                previous_en = False
                continue

            # Pre-edge readiness counts a transmitting bank through its final
            # FCS. This catches bank overwrites and unintended receive stalls.
            receiving_before = pending is not None
            occupancy = len(queue) + (active is not None)
            require(row["payload_ready"] == receiving_before,
                    f"cycle {cycle}: payload ready")
            require(row["start_ready"] == (not receiving_before and occupancy < 2),
                    f"cycle {cycle}: datagram ready/ownership")
            expected_error = False
            if row["start"] and row["start_ready"]:
                counts["accepted_starts"] += 1
                if not 1 <= row["length"] <= 1464:
                    invalid_lengths[row["length"]] += 1
                    counts["invalid_length_errors"] += 1
                    expected_error = True
                else:
                    pending = Packet(**{key: row[key] for key in (
                        "length", "src_mac", "dst_mac", "src_ip", "dst_ip",
                        "src_port", "dst_port", "phase")}, accepted=cycle)

            # Reconstruct accepted input bytes, not a presumed source pattern.
            # A payload transfer cannot accompany a newly accepted start.
            if receiving_before:
                if row["valid"] and row["payload_ready"]:
                    if pending.idle == timeout - 1:
                        counts["deadline_handshakes"] += 1
                    pending.idle = 0
                    pending.payload.append(row["data"])
                    counts["overlap_cycles"] += int(bool(row["tx_en"]))
                    if len(pending.payload) == pending.length:
                        counts["simultaneous_rx_tx_completions"] += int(bool(row["done"]))
                        pending.complete = cycle
                        queue.append(pending)
                        pending = None
                else:
                    counts["receive_bubble_cycles"] += 1
                    pending.idle += 1
                    if pending.idle == timeout:
                        counts["timeout_errors"] += 1
                        counts["timeouts_during_tx"] += int(bool(row["tx_en"]))
                        pending = None
                        expected_error = True
            if row["start"] and not row["start_ready"]:
                counts["start_backpressure_cycles"] += 1
            require(row["error"] == expected_error, f"cycle {cycle}: error/timeout boundary")

            # A premature launch, missing byte, extra frame, or absent done fails
            # without looking at internal DUT state. Only reset permits truncation.
            if row["tx_en"]:
                if active is None:
                    require(not previous_en, f"cycle {cycle}: missing IFG")
                    require(bool(queue), f"cycle {cycle}: sent incomplete/unaccepted packet")
                    active = queue.popleft()
                    require(active.complete < cycle, f"cycle {cycle}: not store-and-forward")
                    active_start = cycle
                    wire.clear()
                    if last_end is not None:
                        gap = cycle - last_end - 1
                        require(gap >= 12, f"cycle {cycle}: IFG {gap} < 12")
                        gaps.append(gap)
                wire.append(row["tx_data"])
                expected_size = 8 + max(60, 42 + active.length) + 4
                require(bool(row["done"]) == (len(wire) == expected_size),
                        f"cycle {cycle}: done not exactly on final FCS")
                if row["done"]:
                    try:
                        checked = validate_frame(bytes(wire), active)
                    except ValueError as exc:
                        raise ValueError(f"frame {len(frames)}, cycle {cycle}: {exc}") from exc
                    checked.update(start_cycle=active_start, end_cycle=cycle,
                                   accepted_cycle=active.accepted,
                                   receive_complete_cycle=active.complete, phase=active.phase)
                    frames.append(checked)
                    if active.length == 1 and not negative_checks:
                        negative_checks = reject_corruptions(bytes(wire), active)
                    active = None
                    last_end = cycle
                    counts["done_pulses"] += 1
            else:
                require(active is None, f"cycle {cycle}: GMII truncated without reset")
                require(row["done"] == 0, f"cycle {cycle}: done without a frame")
            previous_en = bool(row["tx_en"])
            expected_busy = bool(pending or queue or active or
                                 (last_end is not None and cycle - last_end < 12))
            require(bool(row["busy"]) == expected_busy, f"cycle {cycle}: busy/IFG")

    # Coverage assertions prevent a vacuous PASS from a short/empty trace.
    require(pending is None and not queue and active is None, "unfinished work")
    require({1, 2, 17, 18, 19, 65, 1463, 1464}.issubset(
        {frame["payload_bytes"] for frame in frames}), "missing length boundaries")
    require(set(invalid_lengths) == {0, 1465, 65535}, "missing invalid lengths")
    require(counts["invalid_length_errors"] == 3 and counts["timeout_errors"] == 3,
            "missing invalid/timeout scenarios")
    require(counts["timeouts_during_tx"] >= 1, "missing timeout/TX independence")
    require(counts["deadline_handshakes"] >= 2, "missing deadline acceptance/restart")
    require(counts["simultaneous_rx_tx_completions"] >= 1, "missing simultaneous bank completion")
    require(counts["reset_incomplete_receives"] == 1 and
            counts["reset_truncated_frames"] == 1 and counts["reset_queued_packets"] == 1,
            "missing reset receive/TX/queued-bank coverage")
    require(counts["receive_bubble_cycles"] > 100 and counts["overlap_cycles"] > 1000 and
            counts["start_backpressure_cycles"] > 0, "missing bubbles/overlap/backpressure")

    # Measure wire intervals. RAW equivalent assumes 1400 image bytes in every
    # 1464-byte PRAW payload; this is a backend budget, not board/frame evidence.
    burst = [frame for frame in frames if frame["phase"] == 1]
    require(len(burst) == 16 and all(f["payload_bytes"] == 1464 for f in burst),
            "missing maximum-size burst")
    strides = [b["start_cycle"] - a["start_cycle"] for a, b in zip(burst, burst[1:])]
    require(set(strides) == {1530}, f"saturated frame intervals: {strides}")
    elapsed = burst[-1]["start_cycle"] - burst[0]["start_cycle"]
    udp_rate = (len(burst) - 1) * 1464 * 125_000_000 / elapsed
    raw_rate = (len(burst) - 1) * 1400 * 125_000_000 / elapsed
    inclusive = burst[-1]["end_cycle"] - burst[0]["accepted_cycle"] + 1
    return {
        "passed": True, "scope": "RTL GMII only; no PHY/RGMII/ARP/DHCP or board validation",
        "trace_sha256": hashlib.sha256(trace.read_bytes()).hexdigest(),
        "timeout_cycles": timeout, "trace_cycles": last_cycle,
        "frames_checked": len(frames), "counts": dict(counts),
        "negative_checker_tests": negative_checks,
        "minimum_ifg_cycles": min(gaps), "burst_frames": len(burst),
        "burst_start_intervals_cycles": strides, "max_payload_wire_cycles": 1518,
        "steady_udp_payload_MBps": udp_rate / 1_000_000,
        "raw_1400_equivalent_MBps": raw_rate / 1_000_000,
        "raw_1080p30_requirement_MBps": 62.208,
        "burst_with_initial_fill_cycles": inclusive,
        "burst_with_initial_fill_udp_MBps": len(burst) * 1464 * 125 / inclusive,
        "hardware_tested": False, "timing_closed": False, "frames": frames,
    }


def main() -> None:
    """Write reproducible evidence beside the trace and fail closed on mismatch."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trace", type=Path, required=True)
    parser.add_argument("--timeout-cycles", type=int, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    result = check_trace(args.trace, args.timeout_cycles)
    args.output.write_text(json.dumps(result, indent=2) + "\n", encoding="utf-8")
    print(f'ETHERNET_PYTHON_PASS frames={result["frames_checked"]} '
          f'IFG={result["minimum_ifg_cycles"]} '
          f'UDP_MBps={result["steady_udp_payload_MBps"]:.6f} '
          f'RAW1400_MBps={result["raw_1400_equivalent_MBps"]:.6f}')


if __name__ == "__main__":
    main()

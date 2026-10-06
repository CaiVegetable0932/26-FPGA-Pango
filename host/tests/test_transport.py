"""Synthetic protocol, fault-injection, loopback and evidence tests."""
from dataclasses import replace
import json
from pathlib import Path
import random
import socket
import sys
import struct
import tempfile
import threading
import unittest
from unittest.mock import patch
import zlib

from pango_video.cli import HOST_ROOT, load_config, synthetic_pixels
from pango_video.protocol import (HEADER_STRUCT, LAST_CHUNK, FormatLimits, Header,
    ProtocolError, decode_datagram, encode_packet, frame_header, packetize,
    source_stage, ENHANCED_RAW8_DESCRIPTOR, ENHANCED_RAW8_VERSION)
from pango_video.reassembly import AssemblyLimits, FrameAssembler, SnapshotSpec
from pango_video.receiver import FrameQueue, UDPReceiver
from pango_video.storage import save_frame, save_snapshot_pair

SMALL = FormatLimits(50, 40)

def packets(frame_id=7, *, epoch=1):
    return list(packetize(synthetic_pixels(2000, frame_id), stream_epoch=epoch,
        frame_id=frame_id, width=50, height=40, descriptor_id=11))

def assembler(**kwargs):
    return FrameAssembler(device_id="test-device", stream_epoch=1, format_limits=SMALL, **kwargs)

def rewrite(packet, **fields):
    """Deliberately invalid headers, but a valid CRC."""
    h = replace(Header(*HEADER_STRUCT.unpack_from(packet)), **fields, packet_crc32=0)
    out = bytearray(HEADER_STRUCT.pack(*(getattr(h, n) for n in Header.__dataclass_fields__)) + packet[64:])
    struct.pack_into("<I", out, 56, zlib.crc32(out))
    return bytes(out)

def specs(epoch=1):
    base = dict(device_id="test-device", snapshot_id="test-snap", stream_epoch=epoch,
        frame_id=7, width=50, height=40, parameter_snapshot_hash="test-entity",
        enhancement_stage="disabled")
    return (SnapshotSpec.from_dict(dict(base, tap="S1", param_version=2, descriptor_id=21)),
            SnapshotSpec.from_dict(dict(base, tap="S2", param_version=3, descriptor_id=22)))

def snapshot_packets(spec):
    h = spec.header
    return list(packetize(synthetic_pixels(6000, h.frame_id), stream_epoch=h.stream_epoch,
        frame_id=h.frame_id, width=50, height=40, packet_type=h.packet_type,
        param_version=h.param_version, descriptor_id=h.descriptor_id))

def complete_small():
    a = assembler()
    for p in packets():
        result = a.feed(p, 1000)
    return result

class ProtocolTests(unittest.TestCase):
    def test_enhanced_raw8_descriptor_preserves_wire_format_but_not_s0_identity(self):
        # Purpose: the new board curve stays one Bayer RAW8 byte per pixel;
        # provenance changes so processed evidence is not mistaken for S0.
        legacy = frame_header(stream_epoch=1, frame_id=1, width=50, height=40,
                              bayer_code=4, descriptor_id=0x38574152, param_version=1)
        enhanced = replace(legacy, descriptor_id=ENHANCED_RAW8_DESCRIPTOR,
                           param_version=ENHANCED_RAW8_VERSION)
        self.assertEqual(source_stage(legacy), "S0")
        self.assertEqual(source_stage(enhanced), "fpga_enhanced_raw8")
        self.assertEqual(enhanced.pixel_format, legacy.pixel_format)
        self.assertEqual(enhanced.frame_bytes, legacy.frame_bytes)

    def test_iso_hdlc_check(self):
        self.assertEqual(zlib.crc32(b"123456789"), 0xCBF43926)

    def test_independent_golden_vector(self):
        fixture = json.loads((HOST_ROOT / "tests/vectors/praw_v1.json").read_text(encoding="utf-8"))
        data = bytes.fromhex(fixture["datagram_hex"])
        p = decode_datagram(data, FormatLimits(4, 2))
        self.assertEqual(p.header.stream_epoch, 0x0102030405060708)
        self.assertEqual(p.header.frame_id, 0x1112131415161718)
        self.assertEqual(p.header.param_version, 0x21222324)
        self.assertEqual(p.header.descriptor_id, 0x31323334)
        self.assertEqual(bytes(p.payload), bytes(range(8)))
        self.assertEqual(encode_packet(p.header, p.payload), data)
        check = bytearray(data)
        check[56:60] = bytes(4)
        crc = 0xFFFFFFFF
        for byte in check:
            crc ^= byte
            for _ in range(8):
                crc = (crc >> 1) ^ (0xEDB88320 if crc & 1 else 0)
        self.assertEqual(crc ^ 0xFFFFFFFF, p.header.packet_crc32)

    def test_raw_1080p_exact_tail_and_full_reverse_reassembly(self):
        data = synthetic_pixels(2073600, 1)
        encoded = list(packetize(data, stream_epoch=1, frame_id=1, width=1920, height=1080))
        self.assertEqual(len(encoded), 1482)
        tail = decode_datagram(encoded[-1]).header
        self.assertEqual((tail.payload_offset, tail.payload_bytes), (2073400, 200))
        a = FrameAssembler(device_id="test-device", stream_epoch=1)
        for p in reversed(encoded):
            frame = a.feed(p, 0)
        self.assertEqual(frame.data, data)
        self.assertEqual(a.buffer_bytes, 0)

    def test_rgb_1080p_tail(self):
        h = frame_header(stream_epoch=1, frame_id=1, width=1920, height=1080, packet_type=2)
        self.assertEqual((h.frame_bytes, h.packet_count), (6220800, 4444))
        h = replace(h, packet_index=4443, payload_offset=6220200, payload_bytes=600, flags=LAST_CHUNK)
        self.assertEqual(decode_datagram(encode_packet(h, bytes(600))).header.row_stride, 5760)

    def test_bad_headers_with_correct_crc(self):
        cases = [dict(magic=b"JUNK"), dict(protocol_version=2), dict(header_bytes=65),
            dict(flags=4), dict(packet_type=9), dict(pixel_format=2), dict(bayer_code=0),
            dict(bit_depth=10), dict(width=0), dict(height=41), dict(row_stride=64),
            dict(frame_bytes=3000), dict(packet_count=3), dict(packet_index=2),
            dict(payload_offset=1), dict(payload_bytes=1399), dict(flags=LAST_CHUNK)]
        for change in cases:
            with self.subTest(change=change), self.assertRaises(ProtocolError):
                decode_datagram(rewrite(packets()[0], **change), SMALL)

    def test_truncation_extra_and_empty(self):
        for data in (b"", bytes(64), packets()[0][:-1], packets()[0]+b"x", packets()[1]+b"x"):
            with self.subTest(length=len(data)), self.assertRaises(ProtocolError):
                decode_datagram(data, SMALL)

    def test_crc_covers_header_crc_field_descriptor_payload(self):
        for offset in (12, 56, 60, 64, 1463):
            data = bytearray(packets()[0])
            data[offset] ^= 1
            with self.assertRaisesRegex(ProtocolError, "crc"):
                decode_datagram(data, SMALL)

    def test_mode_bayer_byte_and_integer_bounds(self):
        for limits in (FormatLimits(51, 40), FormatLimits(50, 40, expected_bayer_code=4),
                       FormatLimits(50, 40, max_frame_bytes=1999)):
            with self.assertRaises(ProtocolError):
                decode_datagram(packets()[0], limits)
        with self.assertRaises((ValueError, struct.error)):
            frame_header(stream_epoch=-1, frame_id=0, width=50, height=40)

    def test_view_is_readonly(self):
        self.assertTrue(decode_datagram(bytearray(packets()[0]), SMALL).payload.readonly)

    def test_random_garbage_is_bounded(self):
        rng = random.Random(912)
        for _ in range(500):
            try:
                decode_datagram(rng.randbytes(rng.randrange(1600)), SMALL)
            except ProtocolError:
                pass

class AssemblyTests(unittest.TestCase):
    @unittest.skipUnless(sys.platform.startswith("linux"), "Linux batch ABI")
    def test_native_batch_matches_reference_for_wire_errors_and_duplicate_conflicts(self):
        """C CRC/copy must agree with the reference decoder on hostile packets."""
        import ctypes
        from pango_video.linux_udp import LinuxDatagramBatch
        from pango_video.protocol import CRC_FIELD, packet_crc32
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sock:
            batch = LinuxDatagramBatch(sock, ("127.0.0.1", 1234))
            if batch.native is None:
                self.skipTest("Optional current-source native parser has not been built")
            first, last = packets()
            candidates = [last, first]
            for offset in (0,4,6,8,9,10,12,20,28,32,34,36,40,44,48,50,51,52,54,60,64):
                bad = bytearray(last);bad[offset] ^= 1
                CRC_FIELD.pack_into(bad, 56, packet_crc32(bad));candidates.append(bytes(bad))
            bad = bytearray(first);bad[-1] ^= 1;candidates.append(bytes(bad))
            bad = bytearray(first);bad[-1] ^= 1
            CRC_FIELD.pack_into(bad, 56, packet_crc32(bad));candidates.append(bytes(bad))
            for candidate in candidates:
                with self.subTest(candidate=candidate[:64].hex()):
                    cached, reference = assembler(), assembler()
                    cached.feed(first);reference.feed(first)
                    sequence = [first, candidate, last, last]
                    for index, data in enumerate(sequence):
                        ctypes.memmove(batch._buffers[index], data, len(data))
                        batch._messages[index].length = len(data)
                        address = batch._addresses[index]
                        address.family, address.port = socket.AF_INET, socket.htons(1234)
                        address.address = batch._peer_address
                    expected = []
                    for data in sequence:
                        reference._fast_live = None
                        frame = reference.feed(data)
                        if frame:expected.append((frame.header, frame.data, frame.descriptor_json))
                    actual, index = [], 0
                    while index < len(sequence):
                        consumed, _, frame = cached.feed_batch(batch, index, len(sequence)-index)
                        if not consumed:
                            frame = cached.feed(batch.packet(index)[0]);consumed = 1
                        if frame:actual.append((frame.header, frame.data, frame.descriptor_json))
                        index += consumed
                    self.assertEqual(actual, expected)
                    self.assertEqual(cached.status(), reference.status())
                    self.assertEqual(cached.drain_failures(), reference.drain_failures())

    def test_cached_raw_decoder_matches_reference_for_corrupt_and_conflicting_chunks(self):
        """The faster common path must preserve every strict wire rejection."""
        from pango_video.protocol import CRC_FIELD, packet_crc32
        first, last = packets()
        candidates = [last]
        # Mutate each wire field, repairing CRC to exercise structural checks.
        # Include a corrupt CRC and a conflicting duplicate payload separately.
        for offset in (0,4,6,8,9,10,12,20,28,32,34,36,40,44,48,50,51,52,54,60,64):
            bad = bytearray(last)
            bad[offset] ^= 1
            CRC_FIELD.pack_into(bad, 56, packet_crc32(bad))
            candidates.append(bytes(bad))
        bad = bytearray(last);bad[-1] ^= 1;candidates.append(bytes(bad))
        for candidate in candidates:
            with self.subTest(candidate=candidate[:64].hex()):
                cached, reference = assembler(), assembler()
                for packet in (first, first, candidate, last):
                    reference._fast_live = None
                    actual, expected = cached.feed(packet, 1), reference.feed(packet, 1)
                    self.assertEqual(actual, expected)
                    self.assertEqual(cached.status(), reference.status())
                    self.assertEqual(cached.drain_failures(), reference.drain_failures())

    def test_reorder_duplicate_and_owned_bytes(self):
        a = assembler()
        first, last = packets()
        a.feed(last, 0)
        a.feed(last, 1)
        buffer = bytearray(first)
        frame = a.feed(buffer, 2)
        buffer[:] = bytes(len(buffer))
        self.assertEqual(frame.data, synthetic_pixels(2000, 7))
        self.assertEqual(a.stats["packets_duplicate"], 1)
        self.assertEqual(a.stats["packets_out_of_order"], 1)

    def test_missing_never_commits_or_resurrects(self):
        a = assembler()
        a.feed(packets()[0], 0)
        a.expire(100_000_000)
        e = a.drain_failures()[0]
        self.assertEqual((e.reason, e.missing_ranges), ("timeout", ((1, 1),)))
        self.assertIsNone(a.feed(packets()[1], 100_000_001))
        self.assertEqual(a.stats["live_frames_complete"], 0)
        self.assertEqual(a.buffer_bytes, 0)

    def test_duplicate_cannot_extend_deadline(self):
        a = assembler()
        a.feed(packets()[0], 0)
        a.feed(packets()[0], 99_000_000)
        self.assertIsNone(a.feed(packets()[1], 100_000_000))
        self.assertEqual(a.stats["frames_failed_timeout"], 1)

    def test_bad_crc_does_not_poison_identity(self):
        a = assembler()
        bad = bytearray(packets()[0])
        bad[20] ^= 1
        a.feed(bad, 0)
        for p in packets():
            frame = a.feed(p, 1)
        self.assertIsNotNone(frame)
        self.assertEqual(a.stats["packets_rejected_crc"], 1)

    def test_conflicting_duplicate_fails(self):
        a = assembler()
        first, last = packets()
        a.feed(first, 0)
        p = decode_datagram(first, SMALL)
        a.feed(encode_packet(p.header, bytes(1400)), 1)
        self.assertIsNone(a.feed(last, 2))
        self.assertEqual(a.stats["frames_failed_duplicate_conflict"], 1)

    def test_metadata_conflict_and_descriptor_fork(self):
        for fields in (dict(param_version=9), dict(descriptor_id=12)):
            a = assembler()
            a.feed(packets()[0], 0)
            a.feed(rewrite(packets()[1], **fields), 1)
            self.assertEqual(a.stats["frames_failed_metadata_conflict"], 1)
            self.assertIsNone(a.feed(packets()[1], 2))

    def test_count_and_byte_bounds(self):
        a = assembler()
        for f in range(5):
            a.feed(packets(f)[0], 0)
        self.assertEqual((a.active_frames, a.buffer_bytes), (4, 8000))
        self.assertEqual(a.stats["frames_failed_capacity"], 1)
        a = assembler(limits=AssemblyLimits(max_buffer_bytes=1000))
        a.feed(packets()[0], 0)
        self.assertEqual(a.buffer_bytes, 0)
        self.assertEqual(a.stats["frames_rejected_memory"], 1)

    def test_explicit_epoch_change_and_same_epoch_reconnect(self):
        a = assembler()
        a.feed(packets()[0], 0)
        a.feed(packets(epoch=2)[0], 1)
        self.assertEqual(a.stream_epoch, 1)
        a.set_live_epoch(1)
        self.assertIsNotNone(a.feed(packets()[1], 2))
        a.set_live_epoch(2)
        for p in packets(epoch=2):
            frame = a.feed(p, 3)
        self.assertEqual(frame.header.stream_epoch, 2)
        self.assertIsNone(a.feed(packets()[1], 4))

    def test_replay_after_history_prune_and_bounded_tombstones(self):
        a = assembler(limits=AssemblyLimits(max_live_frames=2, live_window=4))
        for f in range(20):
            for p in packets(f):
                a.feed(p, f)
        for p in packets(0):
            self.assertIsNone(a.feed(p, 21))
        self.assertLessEqual(len(a._terminal), 4)
        self.assertEqual(a.stats["live_frames_complete"], 20)

    def test_wholly_missing_source_ids(self):
        a = assembler()
        for f in (10, 12):
            for p in packets(f):
                a.feed(p, 0)
        self.assertEqual(a.status()["live_unobserved_ids_in_span"], 1)
        for p in packets(11):
            a.feed(p, 1)
        self.assertEqual(a.status()["live_unobserved_ids_in_span"], 0)

    def test_snapshot_admission_and_missing_chunk_repair(self):
        a = assembler()
        s1, result = specs()
        self.assertIsNone(a.feed(snapshot_packets(s1)[0], 0))
        a.admit_snapshot(s1, result, 0)
        self.assertEqual(a.missing_ranges(s1.header.key), ((0, 5),))
        for p in snapshot_packets(s1)[1:]:
            a.feed(p, 1)
        self.assertEqual(a.missing_ranges(s1.header.key), ((0, 1),))
        p = decode_datagram(snapshot_packets(s1)[0], SMALL)
        frame = a.feed(encode_packet(replace(p.header, flags=p.header.flags | 1), p.payload), 2)
        self.assertEqual(len(frame.data), 6000)
        self.assertIsNotNone(frame.descriptor_json)
        self.assertEqual(a.stats["packets_retransmitted"], 1)

    def test_completely_lost_snapshots_have_deadline(self):
        a = assembler()
        a.admit_snapshot(*specs(), now_ns=0)
        a.expire(2_000_000_000)
        self.assertEqual(a.stats["frames_failed_timeout"], 2)
        self.assertEqual(a.buffer_bytes, 0)
        self.assertEqual(a.drain_failures()[0].missing_ranges, ((0, 5),))

    def test_snapshot_survives_live_epoch_and_requires_close(self):
        a = assembler()
        s1, result = specs()
        a.admit_snapshot(s1, result, 0)
        a.set_live_epoch(2)
        for p in snapshot_packets(s1):
            frame = a.feed(p, 1)
        self.assertEqual(frame.header.stream_epoch, 1)
        with self.assertRaises(ValueError):
            a.admit_snapshot(s1, result, 2)
        a.close_snapshot()
        self.assertEqual(a.buffer_bytes, 0)

    def test_snapshot_wrong_identity_and_memory_do_not_evict_raw(self):
        a = assembler(limits=AssemblyLimits(max_buffer_bytes=13000))
        s1, result = specs()
        bad = SnapshotSpec.from_dict(dict(result.descriptor, frame_id=8))
        with self.assertRaisesRegex(ValueError, "frame_id"):
            a.admit_snapshot(s1, bad, 0)
        a.feed(packets()[0], 0)
        with self.assertRaisesRegex(ValueError, "budget"):
            a.admit_snapshot(s1, result, 1)
        self.assertIsNotNone(a.feed(packets()[1], 2))

    def test_failure_history_overflow_is_counted(self):
        a = assembler(limits=AssemblyLimits(max_events=2))
        for f in range(3):
            a.feed(packets(f)[0], f * 200_000_000)
        a.expire(600_000_000)
        self.assertEqual(len(a.drain_failures()), 2)
        self.assertEqual(a.stats["failure_events_overflow"], 1)

class SocketQueueStorageTests(unittest.TestCase):
    def test_preview_replaces_archive_preserves_and_byte_bound(self):
        frame = complete_small()
        q = FrameQueue(1, 2000)
        self.assertEqual(q.offer(frame), (True, 0))
        self.assertEqual(q.offer(frame), (False, 0))
        self.assertEqual(q.offer(frame, replace_oldest=True), (True, 1))
        self.assertIs(q.get(), frame)
        self.assertEqual(q.status()["payload_bytes"], 0)
        self.assertEqual(FrameQueue(100, 1999).offer(frame), (False, 0))

    def exchange(self, payloads, foreign=False):
        stop, errors = threading.Event(), []
        with socket.socket(socket.AF_INET, socket.SOCK_DGRAM) as sender:
            sender.bind(("127.0.0.1", 0))
            peer = sender.getsockname()
            if foreign:
                peer = ("127.0.0.2", peer[1])
            rx = UDPReceiver(assembler(), bind=("127.0.0.1", 0), peer=peer)
            target = rx.open()
            def run():
                try:
                    rx.run(stop, duration=0.2)
                except BaseException as e:
                    errors.append(e)
            thread = threading.Thread(target=run)
            thread.start()
            try:
                for p in payloads:
                    sender.sendto(p, target)
                thread.join(2)
                self.assertFalse(thread.is_alive())
                self.assertEqual(errors, [])
                return rx
            finally:
                stop.set()
                thread.join(2)
                rx.close()

    def test_actual_udp_loopback(self):
        rx = self.exchange(packets())
        self.assertEqual(rx.live_frames.get().data, synthetic_pixels(2000, 7))

    def test_actual_udp_oversize_not_truncated_to_good_packet(self):
        rx = self.exchange([packets()[0] + bytes(4000), packets()[1]])
        self.assertEqual(rx.assembler.stats["packets_rejected_datagram_length"], 1)
        self.assertEqual(rx.stats["live_frames_complete"], 0)

    def test_actual_udp_peer_filter(self):
        rx = self.exchange(packets(), foreign=True)
        self.assertEqual(rx.stats["datagrams_wrong_peer"], 2)
        self.assertEqual(rx.assembler.active_frames, 0)

    def test_network_count_precedes_preview_and_archive_overflow(self):
        rx = UDPReceiver(assembler(), bind=("127.0.0.1", 0), peer=("127.0.0.1", 50001), archive_every=1)
        for _ in range(5):
            rx._publish(complete_small())
        self.assertEqual(rx.stats["live_frames_complete"], 5)
        self.assertEqual(rx.stats["preview_frames_replaced"], 3)
        self.assertEqual(rx.archive_frames.status()["frames"], 4)
        self.assertEqual(rx.stats["archive_frames_rejected"], 1)
        self.assertEqual(rx.failures[-1]["reason"], "archive_queue_full")

    def scratch(self):
        tmp = tempfile.TemporaryDirectory(dir=HOST_ROOT / "build")
        self.assertTrue(Path(tmp.name).resolve().is_relative_to((HOST_ROOT / "build").resolve()))
        return tmp

    def test_raw_evidence_no_overwrite_and_no_fake_hdmi_identity(self):
        with self.scratch() as work:
            target = Path(work) / "frame"
            m = save_frame(complete_small(), target, device_id="test-device", source_mode="mock")
            self.assertEqual((target / "image.raw").read_bytes(), synthetic_pixels(2000, 7))
            self.assertTrue(m["transport_complete"])
            self.assertFalse(m["measurement_ready"])
            self.assertFalse(m["board_frame_hash_verified"])
            self.assertIsNone(m["hdmi_source_frame_id"])
            with self.assertRaises(FileExistsError):
                save_frame(complete_small(), target, device_id="test-device", source_mode="mock")

    def test_disk_failure_has_no_metadata_commit(self):
        with self.scratch() as work:
            target = Path(work) / "frame"
            with patch("pango_video.storage.os.fsync", side_effect=OSError("synthetic disk error")):
                with self.assertRaises(OSError):
                    save_frame(complete_small(), target, device_id="test-device", source_mode="mock")
            self.assertFalse((target / "metadata.json").exists())

    def test_snapshot_pair_commit_and_identity_gate(self):
        a, frames = assembler(), []
        s1, result = specs()
        a.admit_snapshot(s1, result, 0)
        for spec in (s1, result):
            for p in snapshot_packets(spec):
                f = a.feed(p, 1)
                if f is not None:
                    frames.append(f)
        with self.scratch() as work:
            target = Path(work) / "pair"
            receipt = save_snapshot_pair(*frames, target, device_id="test-device", source_mode="mock")
            self.assertTrue((target / "pair.json").exists())
            self.assertTrue(receipt["release_request_eligible"])
            self.assertFalse(receipt["board_release_confirmed"])
            with self.assertRaises(ValueError):
                save_snapshot_pair(frames[0], replace(frames[1], header=replace(frames[1].header, frame_id=8)),
                    Path(work) / "bad", device_id="test-device", source_mode="mock")
            self.assertFalse((Path(work) / "bad").exists())

    def test_hardware_template_requires_device_readback(self):
        with self.assertRaisesRegex(ValueError, "device_id"):
            load_config(HOST_ROOT / "config/receiver.hardware.example.json")

"""Synthetic software checks for the user's 21x21 board and full host-frame adapters."""
import hashlib
import http.client
import json
from pathlib import Path
import shutil
import sys
import tempfile
import threading
import time
import unittest
from unittest.mock import Mock, patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import numpy as np
from pango_video.calibration import CalibrationStore, object_points
from pango_video.calibration_source import request_from_pixels, saved_request, saved_sources, live_request
from pango_video.calibration_source import TEST_DESCRIPTOR
from pango_video.protocol import frame_header
from pango_video.reassembly import CompleteFrame
from pango_video.web_server import LocalServer
from pango_video.web_session import WebSession, frame_info
from pango_video import web_launcher

HOST = Path(__file__).resolve().parents[1]
CONFIG = dict(model="pinhole_k1_k2_p1_p2", pattern="chessboard", cols=21, rows=21, square_mm=10,
              board_id="SYNTHETIC-21x21", camera_id="software-test",
              lens_id="synthetic-lens", distance_reference="synthetic optical center",
              lens_focus="synthetic", flatness="ideal plane", mode_notes="synthetic software only")
MANUAL = dict(distance_mm=600.0, light_preset="unknown", notes="synthetic software only")


def board21():
    """Render 22x22 squares with a white margin, at exact full test-frame size."""
    image = np.full((600, 600), 255, np.uint8)
    for y in range(22):
        for x in range(22):
            if (x + y) % 2 == 0:
                image[36+y*24:36+(y+1)*24, 36+x*24:36+(x+1)*24] = 0
    return image.tobytes()


def metadata(data, **extra):
    """Declare a test fixture as unverified input to exercise production source gates."""
    return dict(width=600, height=600, row_stride=600, frame_bytes=360000,
                pixel_format="RAW8", bayer_code=1, bit_depth=8, file="image.raw",
                frame_id=str(2**63 + 1), stream_epoch=str(2**63 + 2),
                source_mode="hardware_unverified", device_id="SOFTWARE-FIXTURE",
                source_stage="S0", descriptor_id=0, synthetic=False,
                transport_complete=True, sha256=hashlib.sha256(data).hexdigest(), **extra)


class CalibrationSourceTests(unittest.TestCase):
    def setUp(self):
        # All generated fixtures and temporary archives stay in host/build.
        (HOST / "build").mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="calibration-source-test-", dir=HOST / "build")
        self.root = Path(self.tmp.name)
        self.store = CalibrationStore(self.root)
        self.dataset = self.store.create(CONFIG)["id"]
        (self.root / "config").mkdir()
        shutil.copyfile(HOST / "config/receiver.mock.json", self.root / "config/receiver.mock.json")

    def tearDown(self):
        self.assertTrue(self.root.resolve().is_relative_to((HOST / "build").resolve()))
        self.tmp.cleanup()

    def archive(self, key, data, meta):
        """Build a committed fixture matching the actual PRAW archive convention."""
        folder = self.root / "data" / key
        folder.mkdir(parents=True)
        (folder / meta["file"]).write_bytes(data)
        (folder / "metadata.json").write_text(json.dumps(meta), encoding="utf-8")
        return folder

    def test_21x21_detection_native_raw_and_original_bytes(self):
        data = board21()
        self.archive("test-run/frame", data, metadata(data))
        request = saved_request(self.root, "test-run/frame", "validation")
        request["manual"] = MANUAL
        sample = self.store.add(self.dataset, request)
        self.assertTrue(sample["eligible"], sample["reason"])
        self.assertEqual(len(sample["corners"]), 441)
        self.assertEqual((sample["width"], sample["height"]), (600, 600))
        self.assertEqual(sample["role"], "validation")
        self.assertEqual(self.store.artifact(self.dataset, sample["id"], "image.raw").read_bytes(), data)
        self.assertEqual(len(self.store.artifact(self.dataset, sample["id"], "image.rgb").read_bytes()), 600*600*3)
        self.assertEqual(sample["source_metadata"]["archive_key"], "test-run/frame")
        self.assertIsNone(sample["source_frame_id"])
        self.assertFalse(sample["measurement_ready"])
        np.testing.assert_equal(object_points(CONFIG)[-1], [200, 200, 0])
        duplicate = self.store.add(self.dataset, request)
        self.assertFalse(duplicate["eligible"])
        self.assertIn("重复", duplicate["reason"])

    def test_all_four_bayer_phases_preserve_rgb_order(self):
        # Independent constant-color mosaics catch swapped red/blue or Bayer phases.
        tiles = {1: [[200, 60], [60, 10]], 2: [[60, 200], [10, 60]],
                 3: [[60, 10], [200, 60]], 4: [[10, 60], [60, 200]]}
        for code, tile in tiles.items():
            with self.subTest(code=code):
                raw = np.tile(np.array(tile, np.uint8), (300, 300)).tobytes()
                meta = dict(metadata(raw), bayer_code=code)
                dataset = self.store.create(CONFIG)["id"]
                request = request_from_pixels(raw, meta, "train", "constant mosaic")
                sample = self.store.add(dataset, dict(request, manual=MANUAL))
                rgb = np.frombuffer(self.store.artifact(dataset, sample["id"], "image.rgb").read_bytes(), np.uint8).reshape(600, 600, 3)
                np.testing.assert_equal(rgb[300, 300], [200, 60, 10])

    def test_source_hash_complete_geometry_and_known_test_gates(self):
        data = board21()
        meta = metadata(data)
        for change in (dict(synthetic=True), dict(source_mode="mock"), dict(descriptor_id=TEST_DESCRIPTOR),
                       dict(source_stage="S2"), dict(descriptor={"tap": "S3"}), dict(transport_complete=False),
                       dict(row_stride=601), dict(sha256="0"*64), dict(width=599)):
            with self.subTest(change=change), self.assertRaises(ValueError):
                request_from_pixels(data, dict(meta, **change), "train", "bad source")
        folder = self.archive("run/tampered", data, meta)
        (folder / "image.raw").write_bytes(bytes(len(data)))
        with self.assertRaisesRegex(ValueError, "SHA-256"):
            saved_request(self.root, "run/tampered", "train")
        with self.assertRaises(ValueError):
            saved_request(self.root, "../escape", "train")
        self.archive("run/test", data, dict(meta, descriptor_id=TEST_DESCRIPTOR))
        blocked = next(item for item in saved_sources(self.root) if item["key"] == "run/test")
        self.assertFalse(blocked["calibration_allowed"])

    def test_live_frame_native_size_and_stale_rejection(self):
        data = board21()
        header = frame_header(width=600, height=600, bayer_code=1, stream_epoch=2**63+2, frame_id=2**63+1)
        frame = CompleteFrame(header, data, time.monotonic_ns(), time.monotonic_ns())
        session = WebSession(self.root)
        session._frame, session._state, session._run_id = frame, "listening", "test-run"
        session._config.update(source_mode="hardware_unverified", device_id="SOFTWARE-FIXTURE")
        request = live_request(session, "train")
        self.assertEqual((request["width"], request["height"]), (600, 600))
        self.assertEqual(request["metadata"]["frame_id"], str(2**63+1))
        self.assertEqual(request["metadata"]["device_id"], "SOFTWARE-FIXTURE")
        session._frame = CompleteFrame(header, data, 0, time.monotonic_ns()-2_000_000_000)
        with self.assertRaisesRegex(ValueError, "1秒"):
            live_request(session, "train")
        info = frame_info(frame, "test-run", "mock")
        with self.assertRaisesRegex(ValueError, "合成"):
            live_request(Mock(latest=Mock(return_value=(frame, info))), "train")

    def test_http_record_and_live_routes_with_shared_auth(self):
        # Real loopback HTTP checks token enforcement and full archive import.
        data = board21()
        self.archive("run/frame", data, metadata(data))
        server = LocalServer(0, WebSession(self.root))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            def call(method, path, body=None, authorized=True):
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=30)
                headers = {"Content-Type": "application/json"}
                if authorized:
                    headers["X-Pango-Token"] = server.token
                connection.request(method, path, None if body is None else json.dumps(body), headers)
                response = connection.getresponse()
                status, result = response.status, json.loads(response.read())
                connection.close()
                return status, result
            self.assertEqual(call("GET", "/api/calibration/sources")[1]["items"][0]["key"], "run/frame")
            request = dict(dataset=self.dataset, key="run/frame", role="train", manual=MANUAL)
            self.assertEqual(call("POST", "/api/calibration/record", request, False)[0], 403)
            status, sample = call("POST", "/api/calibration/record", request)
            self.assertEqual(status, 200, sample)
            self.assertEqual(len(sample["corners"]), 441)
            status, error = call("POST", "/api/calibration/live", dict(dataset=self.dataset))
            self.assertEqual(status, 400)
            self.assertIn("1秒", error["error"])
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_calibration_launcher_reuses_service_and_opens_requested_page(self):
        # Reusing a live workbench must select the calibration route without stopping capture.
        with patch.object(web_launcher, "LocalServer", side_effect=OSError("occupied")), \
                patch.object(web_launcher, "is_same_instance", return_value=True), \
                patch.object(web_launcher, "open_page") as open_page:
            self.assertEqual(web_launcher.main(["--page", "calibration"]), 0)
            open_page.assert_called_once_with("http://127.0.0.1:8765/calibration")


if __name__ == "__main__":
    unittest.main(verbosity=2)

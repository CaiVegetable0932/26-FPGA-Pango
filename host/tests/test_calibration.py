"""Synthetic software tests only; these are not camera calibration evidence."""
import base64
import hashlib
import http.client
import json
from pathlib import Path
import sys
import tempfile
import shutil
import threading
import unittest

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "src"))
import cv2 as cv
import numpy as np
from pango_video.calibration import CalibrationStore, fit_model, object_points
from pango_video.calibration_image import image_size
from pango_video.web_server import LocalServer
from pango_video.web_session import WebSession

# Purpose: synthetic geometry and operator inputs exercise validation only;
# these values must never be presented as physical camera evidence.
CONFIG = dict(model="pinhole_k1_k2_p1_p2", cols=9, rows=6, square_mm=20.0, pattern="chessboard", board_id="SYNTHETIC",
              camera_id="mock", lens_id="mock-lens", lens_focus="synthetic", mode_notes="synthetic only",
              flatness="ideal plane", distance_reference="synthetic optical center")
MANUAL = dict(distance_mm=600.0, distance_uncertainty_mm=2.0, light_preset="unknown", notes="synthetic")


def board():
    """Render a full chessboard with a white border, preserving known corners."""
    image = np.full((400, 520, 3), 255, np.uint8)
    for y in range(7):
        for x in range(10):
            if (x + y) % 2 == 0:
                image[60+y*40:60+(y+1)*40, 60+x*40:60+(x+1)*40] = 0
    return image


def upload(image, **extra):
    """Build an exact RGB upload rather than lossy screenshot evidence."""
    result = dict(kind="rgb", width=image.shape[1], height=image.shape[0], manual=MANUAL,
                  payload=base64.b64encode(image.tobytes()).decode())
    result.update(extra)
    return result


class CalibrationTests(unittest.TestCase):
    def setUp(self):
        # Keep all test artifacts under the host development area.
        build = Path(__file__).resolve().parents[1] / "build"
        build.mkdir(exist_ok=True)
        self.tmp = tempfile.TemporaryDirectory(prefix="calibration-test-", dir=build)
        self.store = CalibrationStore(self.tmp.name)
        self.dataset = self.store.create(CONFIG)["id"]

    def tearDown(self):
        self.tmp.cleanup()

    def test_detection_original_and_duplicate(self):
        image = board()
        sample = self.store.add(self.dataset, upload(image))
        self.assertEqual(len(sample["corners"]), 54)
        self.assertTrue(sample["eligible"])
        self.assertFalse(sample["measurement_ready"])
        self.assertEqual(sample["manual"]["distance_mm"], 600.0)
        self.assertIsNone(sample["source_frame_id"])
        raw = self.store.artifact(self.dataset, sample["id"], "image.rgb").read_bytes()
        self.assertEqual(raw, image.tobytes())
        self.assertEqual(hashlib.sha256(raw).hexdigest(), sample["sha256"])
        duplicate = self.store.add(self.dataset, upload(image, role="validation"))
        self.assertFalse(duplicate["eligible"])
        self.assertIn("重复", duplicate["reason"])
        self.store.select(self.dataset, sample["id"], False, "manual review")
        self.assertEqual(len(self.store.read(self.dataset)["samples"][0]["selection_history"]), 1)

    def test_failure_and_mismatch_retained(self):
        blank = np.zeros((400, 520, 3), np.uint8)
        failed = self.store.add(self.dataset, upload(blank))
        self.assertFalse(failed["eligible"])
        self.assertTrue(self.store.artifact(self.dataset, failed["id"], "image.rgb").exists())
        resized = cv.resize(board(), (780, 600))
        mismatch = self.store.add(self.dataset, upload(resized))
        self.assertFalse(mismatch["eligible"])
        self.assertIn("尺寸", mismatch["reason"])
        with self.assertRaises(ValueError):
            self.store.solve(self.dataset)

    def test_invalid_input_and_paths(self):
        with self.assertRaises(ValueError):
            self.store.folder("../escape")
        with self.assertRaises(ValueError):
            self.store.create({**CONFIG, "square_mm": float("nan")})
        with self.assertRaises(ValueError):
            self.store.add(self.dataset, upload(board(), manual={"distance_mm": float("nan")}))
        with self.assertRaises(ValueError):
            self.store.add(self.dataset, upload(board(), manual={"distance_mm": 0}))
        with self.assertRaises(ValueError):
            self.store.add(self.dataset, upload(board(), manual={"distance_mm": 600, "light_preset": "4"}))
        with self.assertRaises(ValueError):
            self.store.add(self.dataset, dict(kind="rgb", width=100, height=100, payload="AA=="))
        with self.assertRaises(ValueError):
            image_size(b"not an image")
        with self.assertRaises(ValueError):
            self.store.artifact(self.dataset, "a"*32, "../dataset.json")

    def test_png_jpeg_decoding(self):
        for extension in (".png", ".jpg"):
            ok, encoded = cv.imencode(extension, board())
            self.assertTrue(ok)
            self.assertEqual(image_size(encoded.tobytes()), (520, 400))
            sample = self.store.add(self.dataset, dict(kind="image", manual=MANUAL, payload=base64.b64encode(encoded).decode()))
            self.assertTrue(sample["decoded_from_compressed"])
            self.assertTrue((self.store.folder(self.dataset) / sample["id"] / "upload.bin").exists())

    def test_four_coefficient_fit_with_held_out_views(self):
        # Known camera and varied poses exercise actual OpenCV optimization.
        rng = np.random.default_rng(428)
        K = np.array([[850., 0, 640], [0, 860., 360], [0, 0, 1.]])
        D = np.array([-.12, .025, .001, -.002, 0.])
        points = []
        for i in range(30):
            r = rng.uniform(-.5, .5, 3)
            t = np.array([rng.uniform(-140, 10), rng.uniform(-90, 10), rng.uniform(480, 950)])
            p, _ = cv.projectPoints(object_points(CONFIG), r, t, K, D)
            points.append(p.reshape(-1, 2).tolist())
        result = fit_model(CONFIG, points[:25], points[25:], (1280, 720))
        self.assertEqual(result["k3"], 0)
        np.testing.assert_allclose(result["K"], K, atol=.05)
        np.testing.assert_allclose(result["D"], D[:4], atol=.0001)
        self.assertLess(max(result["validation_errors_px"]), .01)

    def test_fisheye_fit_is_not_fpga_pinhole_profile(self):
        """Project synthetic fisheye corners and validate model identity."""
        rng = np.random.default_rng(77)
        K = np.array([[620., 0, 640.], [0, 625., 360.], [0, 0, 1.]])
        D = np.array([-.08, .02, -.003, .001])
        obj = object_points(CONFIG).astype(np.float64).reshape(-1, 1, 3)
        points = []
        for _ in range(30):
            rotation = rng.uniform(-.45, .45, 3)
            translation = np.array([rng.uniform(-120, 10), rng.uniform(-90, 10), rng.uniform(380, 850)])
            projected, _ = cv.fisheye.projectPoints(obj, rotation, translation, K, D)
            points.append(projected.reshape(-1, 2).tolist())
        result = fit_model({**CONFIG, "model": "fisheye_equidistant"}, points[:25], points[25:], (1280, 720))
        self.assertEqual(result["distortion_order"], ["k1", "k2", "k3", "k4"])
        self.assertFalse(result["fpga_compatible"])
        self.assertLess(result["rms_px"], .05)
        self.assertLess(max(result["validation_errors_px"]), .05)

    def test_network_raw8_preserves_exact_sensor_bytes(self):
        """Derived RGB is separate from exact received RAW8 evidence."""
        raw = board()[:, :, 0].tobytes()
        metadata = dict(source_mode="hardware_unverified", pixel_format="RAW8", transport_complete=True,
                        width=520, height=400, row_stride=520, bayer_code=4, stream_epoch="1",
                        source_stage="fpga_enhanced_raw8", frame_id="42")
        sample = self.store.add(self.dataset, dict(kind="raw8", manual=MANUAL, width=520, height=400,
            bayer_code=4, payload=base64.b64encode(raw).decode(), metadata=metadata))
        self.assertEqual(self.store.artifact(self.dataset, sample["id"], "image.raw").read_bytes(), raw)
        self.assertEqual(sample["source_frame_claim"], "42")
        self.assertIsNone(sample["source_frame_id"])
        self.assertFalse(sample["measurement_ready"])
        self.assertTrue(sample["eligible"], sample["reason"])

    def test_raw8_bayer_phase_matches_rgb_channel_order(self):
        """All four protocol Bayer codes must decode to the same RGB cell."""
        for code, layout in ((1, (200, 100, 100, 20)), (2, (100, 200, 20, 100)),
                             (3, (100, 20, 200, 100)), (4, (20, 100, 100, 200))):
            pixels = np.zeros((16, 16), np.uint8)
            pixels[0::2, 0::2], pixels[0::2, 1::2] = layout[0], layout[1]
            pixels[1::2, 0::2], pixels[1::2, 1::2] = layout[2], layout[3]
            metadata = dict(source_mode="hardware_unverified", pixel_format="RAW8", transport_complete=True,
                            width=16, height=16, row_stride=16, bayer_code=code, stream_epoch="1")
            sample = self.store.add(self.dataset, dict(kind="raw8", manual=MANUAL, width=16, height=16,
                bayer_code=code, payload=base64.b64encode(pixels.tobytes()).decode(), metadata=metadata))
            rgb = np.frombuffer(self.store.artifact(self.dataset, sample["id"], "image.rgb").read_bytes(), np.uint8).reshape(16, 16, 3)
            np.testing.assert_array_equal(rgb[8, 8], [200, 100, 20])

    def test_http_trust_and_routes(self):
        # A temporary host root keeps HTTP mutations separate from real evidence.
        config_dir = Path(self.tmp.name) / "config"
        config_dir.mkdir()
        shutil.copyfile(Path(__file__).resolve().parents[1] / "config/receiver.mock.json", config_dir / "receiver.mock.json")
        server = LocalServer(0, session=WebSession(root=Path(self.tmp.name)))
        thread = threading.Thread(target=server.serve_forever, daemon=True)
        thread.start()
        try:
            connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=30)
            body = json.dumps({"config": CONFIG})
            connection.request("POST", "/api/calibration/create", body, {"Content-Type": "application/json"})
            response = connection.getresponse(); response.read()
            self.assertEqual(response.status, 403)
            connection.request("POST", "/api/calibration/create", body,
                               {"Content-Type": "application/json", "X-Pango-Token": server.token})
            response = connection.getresponse(); data = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertIn("id", data)
            dataset = data["id"]
            connection.request("POST", "/api/calibration/image", json.dumps({"dataset": dataset, **upload(board())}),
                               {"Content-Type": "application/json", "X-Pango-Token": server.token})
            response = connection.getresponse(); sample = json.loads(response.read())
            self.assertEqual(response.status, 200)
            self.assertEqual(len(sample["corners"]), 54)
            # Purpose: the HTTP boundary must reject a sample without a
            # measured per-image distance, even if its image bytes are valid.
            invalid = upload(board()); invalid.pop("manual")
            connection.request("POST", "/api/calibration/image", json.dumps({"dataset":dataset, **invalid}),
                               {"Content-Type":"application/json", "X-Pango-Token":server.token})
            response = connection.getresponse(); error = json.loads(response.read())
            self.assertEqual(response.status, 400)
            self.assertIn("人工测量", error["error"])
            raw = board()[:, :, 0].tobytes()
            metadata = dict(source_mode="hardware_unverified", pixel_format="RAW8", transport_complete=True,
                            width=520, height=400, row_stride=520, bayer_code=4, stream_epoch="synthetic")
            request = dict(dataset=dataset, kind="raw8", width=520, height=400, bayer_code=4,
                           manual=MANUAL, payload=base64.b64encode(raw).decode(), metadata=metadata)
            connection.request("POST", "/api/calibration/image", json.dumps(request),
                               {"Content-Type":"application/json", "X-Pango-Token":server.token})
            response = connection.getresponse(); raw_sample = json.loads(response.read())
            self.assertEqual(response.status, 200)
            connection.request("GET", f"/api/calibration/artifact?dataset={dataset}&sample={raw_sample['id']}&file=image.raw")
            response = connection.getresponse(); downloaded = response.read()
            self.assertEqual(response.status, 200)
            self.assertEqual(downloaded, raw)
            connection.request("GET", "/api/calibration")
            response = connection.getresponse(); data = json.loads(response.read())
            self.assertTrue(data["environment"]["available"])
            connection.close()
        finally:
            server.shutdown(); server.server_close(); thread.join()

    def test_full_image_dataset_and_versioned_export(self):
        # Render independent ideal pinhole views, exercising detection through export.
        rng = np.random.default_rng(9020)
        K = np.array([[900., 0, 640], [0, 910., 360], [0, 0, 1.]])
        plane = np.array([[-50., -50., 0], [210., -50., 0], [210., 150., 0], [-50., 150., 0]], np.float32)
        pixels = np.array([[0., 0], [520., 0], [520., 400.], [0, 400.]], np.float32)
        for i in range(28):
            r = rng.uniform(-.35, .35, 3)
            t = np.array([rng.uniform(-110, -20), rng.uniform(-60, 0), rng.uniform(540, 760)])
            projected, _ = cv.projectPoints(plane, r, t, K, np.zeros(5))
            transform = cv.getPerspectiveTransform(pixels, projected.reshape(4, 2))
            image = cv.warpPerspective(board(), transform, (1280, 720), borderValue=(255, 255, 255))
            sample = self.store.add(self.dataset, upload(image, role="train" if i < 25 else "validation"))
            self.assertTrue(sample["eligible"], sample["reason"])
        result = self.store.solve(self.dataset)
        self.assertEqual(result["status"], "candidate_unverified")
        self.assertEqual(len(result["training_errors_px"]), 25)
        self.assertEqual(len(result["validation_errors_px"]), 3)
        self.assertFalse(result["hardware_applied"])
        self.assertLess(result["rms_px"], 1)
        path = self.store.artifact(self.dataset, None, "json", result["version"])
        self.assertTrue(path.exists())
        self.assertEqual(hashlib.sha256(path.read_bytes()).hexdigest(), self.store.read(self.dataset)["results"][-1]["sha256"])
        # Older local groups lack a model/manual schema. They retain pinhole semantics
        # and null distances, without rewriting archived measurements or image bytes.
        legacy = self.store.read(self.dataset)
        legacy["config"].pop("model")
        for sample in legacy["samples"]:
            sample.pop("manual")
        (self.store.folder(self.dataset) / "dataset.json").write_text(json.dumps(legacy), encoding="utf-8")
        legacy_result = self.store.solve(self.dataset)
        self.assertEqual(legacy_result["model"], "pinhole_k1_k2_p1_p2")
        self.assertTrue(all(item["distance_mm"] is None for item in legacy_result["manual_distances"]))
        evidence = self.store.artifact(self.dataset, result["training_ids"][0], "image.rgb")
        evidence.write_bytes(b"tamper")
        with self.assertRaisesRegex(ValueError, "校验失败"):
            self.store.solve(self.dataset)


if __name__ == "__main__":
    unittest.main(verbosity=2)


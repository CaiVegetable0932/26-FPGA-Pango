"""Independent ground-truth and evidence-integrity checks for offline calibration."""
import hashlib
from pathlib import Path
import tempfile
import unittest

import cv2 as cv
import numpy as np

from pango_video.calibration import object_points
from pango_video.offline_rgb_calibration import (
    HOST, MODELS, evaluate_models, grid_line_error, make_maps, natural_key,
    point_rectification, prepare_inputs,
)


class OfflineCalibrationTests(unittest.TestCase):
    def test_known_fisheye_geometry_and_held_out_generalization(self):
        """Known intrinsics and separately projected poses exercise real fitting, not a mock."""
        config = dict(pattern="chessboard", cols=15, rows=9, square_mm=15.0)
        obj = object_points(config).astype(np.float64).reshape(-1, 1, 3)
        K = np.array([[830., 0, 981], [0, 825., 571], [0, 0, 1.]])
        D = np.array([.01, -.02, .025, -.012])
        records = []
        for i, (rx, ry, x, y, z) in enumerate([
            (.15, .2, -110, -60, 200), (-.3, .1, -180, -30, 250),
            (.4, -.2, -40, -100, 240), (-.2, -.4, -130, -110, 220),
            (.2, .5, -30, -30, 280), (-.35, .3, -180, -90, 310),
            (.5, .15, -100, -70, 190)]):
            p, _ = cv.fisheye.projectPoints(obj, np.array([rx, ry, .05 * i]), np.array([x, y, z], np.float64), K, D)
            records.append(dict(name=f"synthetic-{i}", corners=p.reshape(-1, 2).tolist()))
        models = evaluate_models(records, config, (1920, 1080))
        fish = next(m for m in models if m["model"] == MODELS[0])
        np.testing.assert_allclose(fish["K"], K, atol=.02, rtol=0)
        np.testing.assert_allclose(fish["D"], D, atol=.002, rtol=0)
        self.assertLess(fish["loo_pooled_rms_px"], .002)
        self.assertEqual(len(fish["cross_validation"]), 7)
        for fold in fish["cross_validation"]:
            self.assertNotIn(fold["held_out"], fold["train_names"])
        # Removing lens distortion from analytic projections restores straight grid rows.
        rectified = point_rectification(fish, records[0]["corners"], K)
        self.assertLess(grid_line_error(rectified, (15, 9))["rms_px"], .002)

    def test_identity_map_and_bilinear_boundary_mask(self):
        """An independent identity geometry catches map direction and off-by-one neighbors."""
        K = np.array([[30., 0, 15.5], [0, 30., 11.5], [0, 0, 1.]])
        m = dict(model=MODELS[1], K=K.tolist(), D=[0., 0, 0, 0])
        x, y, valid = make_maps(m, (32, 24), K)
        np.testing.assert_allclose(x, np.tile(np.arange(32), (24, 1)), atol=1e-5)
        np.testing.assert_allclose(y, np.tile(np.arange(24)[:, None], (1, 32)), atol=1e-5)
        self.assertFalse(valid[-1].any()); self.assertFalse(valid[:, -1].any())

    def test_rgb_duplicates_and_archive_collision_keep_original_bytes(self):
        """Rejected inputs remain evidence; an existing different archive is never overwritten."""
        (HOST / "build").mkdir(exist_ok=True)
        with tempfile.TemporaryDirectory(dir=HOST / "build") as temp:
            root = Path(temp); source = root / "input"; source.mkdir()
            archive = root / "archive"; archive.mkdir(); report = root / "report"; report.mkdir()
            # Full synthetic 4x3 inner-corner target with a white border.
            gray = np.full((120, 144), 255, np.uint8)
            for r in range(4):
                for c in range(5):
                    if (r + c) % 2 == 0:
                        gray[12 + r * 24:12 + (r + 1) * 24, 12 + c * 24:12 + (c + 1) * 24] = 0
            data = cv.cvtColor(gray, cv.COLOR_GRAY2RGB).tobytes()
            files = [source / "image (1).rgb", source / "image (2).rgb"]
            for f in files:
                f.write_bytes(data)
            records, _ = prepare_inputs(files, (144, 120), (4, 3), archive, report, {})
            self.assertTrue(records[0]["accepted"])
            self.assertFalse(records[1]["accepted"])
            self.assertEqual(hashlib.sha256((archive / files[0].name).read_bytes()).hexdigest(), records[0]["sha256"])
            (archive / files[0].name).write_bytes(b"keep these bytes")
            with self.assertRaises(ValueError):
                prepare_inputs([files[0]], (144, 120), (4, 3), archive, report, {})
            self.assertEqual((archive / files[0].name).read_bytes(), b"keep these bytes")

    def test_numeric_order_and_dimension_conflict_rejection(self):
        """Headerless byte length never overrides metadata and ordering is numeric."""
        names = [Path("image (11).rgb"), Path("image (2).rgb"), Path("image (1).rgb")]
        self.assertEqual([p.name for p in sorted(names, key=natural_key)], ["image (1).rgb", "image (2).rgb", "image (11).rgb"])
        with tempfile.TemporaryDirectory(dir=HOST / "build") as temp:
            root = Path(temp); file = root / "bad.rgb"; file.write_bytes(bytes(32 * 24 * 3))
            archive, report = root / "archive", root / "report"; archive.mkdir(); report.mkdir()
            digest = hashlib.sha256(file.read_bytes()).hexdigest()
            metadata = {digest: [dict(width=24, height=32, source_metadata={})]}
            records, _ = prepare_inputs([file], (32, 24), (4, 3), archive, report, metadata)
            self.assertFalse(records[0]["accepted"])
            self.assertIn("dimensions conflict", records[0]["issues"][0])


if __name__ == "__main__":
    unittest.main()

"""Check browser fish-eye mapping against independent OpenCV projection."""
import json
from pathlib import Path
import subprocess
import unittest

import cv2 as cv
import numpy as np


class FisheyePreviewTests(unittest.TestCase):
    def test_forward_marker_opencv_agreement(self):
        """Compare source-to-output positions with independent OpenCV inversion."""
        script = Path(__file__).with_name("test_pixel_markers.cjs")
        output = subprocess.check_output(["node", str(script), "--coordinates"], text=True)
        compared = 0
        for case in json.loads(output):
            p = case["parameters"]
            K = np.array([[p["fx"], 0, p["cx"]], [0, p["fy"], p["cy"]], [0, 0, 1.]], dtype=np.float64)
            D = np.array([p[f"k{i}"] for i in range(1, 5)], dtype=np.float64)
            focal = case["width"] / (2 * np.tan(np.deg2rad(p["output_fov_deg"]) / 2))
            for item in case["points"]:
                if not item["visible"]:
                    continue  # Renderer-cropped points must not be drawn at a clamped border.
                src = np.array(item["source"], dtype=np.float64).reshape(1, 1, 2)
                ray = cv.fisheye.undistortPoints(src, K, D,
                    criteria=(cv.TERM_CRITERIA_COUNT | cv.TERM_CRITERIA_EPS, 100, 1e-12)).reshape(2)
                expected = ray * focal + [(case["width"] - 1) / 2, (case["height"] - 1) / 2]
                np.testing.assert_allclose(item["point"], expected, rtol=0, atol=1e-7)
                compared += 1
        self.assertGreater(compared, 20)

    def test_opencv_coordinate_agreement(self):
        """Compare central/edge rays and asymmetric, high-order configurations."""
        script = Path(__file__).with_suffix(".cjs")
        output = subprocess.check_output(["node", str(script), "--coordinates"], text=True)
        for case in json.loads(output):
            p, width, height = case["parameters"], case["width"], case["height"]
            sx, sy = width / p["reference_width"], height / p["reference_height"]
            K = np.array([[p["fx"] * sx, 0, (p["cx"] + .5) * sx - .5],
                          [0, p["fy"] * sy, (p["cy"] + .5) * sy - .5], [0, 0, 1.]])
            # OpenCV requires distortion and intrinsics to share floating type,
            # including the all-zero equidistant preset returned as JSON ints.
            D = np.array([p[f"k{i}"] for i in range(1, 5)], dtype=np.float64)
            focal = width / (2 * np.tan(np.deg2rad(p["output_fov_deg"]) / 2))
            rays = np.array([[(item["output"][0] - (width - 1) / 2) / focal,
                              (item["output"][1] - (height - 1) / 2) / focal, 1.]
                             for item in case["points"]]).reshape(-1, 1, 3)
            expected, _ = cv.fisheye.projectPoints(rays, np.zeros(3), np.zeros(3), K, D)
            actual = np.array([item["source"] for item in case["points"]])
            np.testing.assert_allclose(actual, expected.reshape(-1, 2), rtol=0, atol=1e-9)


if __name__ == "__main__":
    unittest.main()

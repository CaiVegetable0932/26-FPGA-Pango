"""Reproducible small-batch RGB calibration, separate from the 25/3 workbench policy.

Full-board detections only; original archives are immutable. Leave-one-view-out
validation refits K/D without the held-out view and estimates only its pose.
"""
import argparse
import csv
from datetime import datetime, timedelta, timezone
import hashlib
import json
from pathlib import Path
import platform
import re
import shutil
import sys
import time

import cv2 as cv
import numpy as np

from .calibration import fit_model, object_points
from .calibration_source import check_source

HOST = Path(__file__).resolve().parents[2]
MODELS = ("fisheye_equidistant", "pinhole_k1_k2_p1_p2")


def save_json(path, data):
    """Reject non-finite numbers and preserve a readable, byte-hashed result."""
    path.write_text(json.dumps(data, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")


def natural_key(path):
    """Numbered downloads must keep numeric order: 1, 2, ..., 10, 11."""
    return [int(s) if s.isdigit() else s.lower() for s in re.split(r"(\d+)", path.name)]


def evidence_index(root):
    """Match exact bytes to existing metadata; never infer source identity by arrival."""
    result = {}
    for path in sorted((root / "data/calibration").glob("*/dataset.json")):
        dataset = json.loads(path.read_text(encoding="utf-8"))
        for sample in dataset["samples"]:
            result.setdefault(sample["sha256"], []).append(dict(
                dataset_id=dataset["id"], sample_id=sample["id"],
                width=sample["width"], height=sample["height"],
                historical_config=dataset["config"], manual=sample.get("manual"),
                source_metadata=sample.get("source_metadata", {}),
                pairing_status=sample.get("pairing_status", "unverified")))
    return result


def detect(gray, pattern):
    """Try SB at native resolution; retry exhaustive search and classical refinement.

    Failed or partial grids are never resized into an accepted full grid. All
    returned coordinates refer to the untouched full-resolution input image.
    """
    trials = []
    for label, flags in (("SB normalize", cv.CALIB_CB_NORMALIZE_IMAGE),
                         ("SB exhaustive accuracy", cv.CALIB_CB_NORMALIZE_IMAGE |
                          cv.CALIB_CB_EXHAUSTIVE | cv.CALIB_CB_ACCURACY)):
        start = time.perf_counter()
        found, corners = cv.findChessboardCornersSB(gray, pattern, flags=flags)
        trials.append(dict(method=label, found=bool(found), seconds=time.perf_counter() - start))
        if found and len(corners) == pattern[0] * pattern[1]:
            return corners, trials
    start = time.perf_counter()
    found, corners = cv.findChessboardCorners(gray, pattern, cv.CALIB_CB_ADAPTIVE_THRESH | cv.CALIB_CB_NORMALIZE_IMAGE)
    trials.append(dict(method="classical subpixel", found=bool(found), seconds=time.perf_counter() - start))
    if found and len(corners) == pattern[0] * pattern[1]:
        cv.cornerSubPix(gray, corners, (5, 5), (-1, -1), (cv.TERM_CRITERIA_EPS | cv.TERM_CRITERIA_COUNT, 50, 1e-5))
        return corners, trials
    return None, trials


def prepare_inputs(paths, size, pattern, archive, report, index):
    """Validate contiguous RGB888, archive exact bytes, and annotate derived PNGs."""
    seen, records, images = set(), [], []
    for ordinal, path in enumerate(paths, 1):
        data = path.read_bytes()
        digest = hashlib.sha256(data).hexdigest()
        matches = index.get(digest, [])
        issues = []
        if len(data) != size[0] * size[1] * 3:
            issues.append("RGB888 byte count does not match explicit dimensions")
        if any((m["width"], m["height"]) != size for m in matches):
            issues.append("dimensions conflict with exact-hash host metadata")
        # A matching archive does not promote a known test/corrected tap into
        # a raw camera sample. Unknown provenance stays unverified in results.
        for match in matches:
            try:
                check_source(match["source_metadata"])
            except ValueError as error:
                issues.append(str(error))
        if digest in seen:
            issues.append("duplicate bytes; excluded from independent views")
        seen.add(digest)
        destination = archive / path.name
        if destination.exists() and hashlib.sha256(destination.read_bytes()).hexdigest() != digest:
            raise ValueError("Refusing to overwrite different archived evidence: " + str(destination))
        if not destination.exists():
            shutil.copy2(path, destination)
        record = dict(ordinal=ordinal, name=path.name, source_path=str(path.resolve()),
                      archive_path=str(destination.resolve()), bytes=len(data), sha256=digest,
                      metadata_matches=matches, issues=issues, corners=[], accepted=False)
        if not issues:
            rgb = np.frombuffer(data, np.uint8).reshape(size[1], size[0], 3)
            bgr = cv.cvtColor(rgb, cv.COLOR_RGB2BGR)
            gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY)
            corners, trials = detect(gray, pattern)
            record["detection_trials"] = trials
            record["laplacian_variance"] = float(cv.Laplacian(gray, cv.CV_64F).var())
            record["gray_percentiles"] = np.percentile(gray, [1, 50, 99]).tolist()
            if corners is None:
                issues.append("full expected board not detected")
            else:
                record["corners"] = corners.reshape(-1, 2).tolist()
                record["accepted"] = True
                record["corner_bbox"] = [*corners.min(axis=0).ravel().tolist(), *corners.max(axis=0).ravel().tolist()]
                record["board_hull_fraction"] = float(cv.contourArea(cv.convexHull(corners)) / (size[0] * size[1]))
                cv.drawChessboardCorners(bgr, pattern, corners, True)
            cv.imwrite(str(report / f"corners-{ordinal:02}.png"), bgr)
            # Store the unannotated BGR only in memory for software remapping.
            images.append((ordinal, cv.cvtColor(rgb, cv.COLOR_RGB2BGR)))
        records.append(record)
        print(f"{ordinal:02} {path.name}: {len(record['corners'])} corners; accepted={record['accepted']}", flush=True)
    return records, images


def point_rectification(model, points, Kout=None):
    """Return ideal ray coordinates or coordinates of the shared output camera."""
    K, D = np.array(model["K"], np.float64), np.array(model["D"], np.float64)
    points = np.asarray(points, np.float64).reshape(-1, 1, 2)
    if model["model"] == MODELS[0]:
        result = cv.fisheye.undistortPoints(points, K, D.reshape(4, 1), P=Kout)
    else:
        result = cv.undistortPoints(points, K, D, P=Kout)
    if not np.isfinite(result).all() or np.max(np.abs(result)) > 1e5:
        raise ValueError("unstable inverse point mapping")
    return result.reshape(-1, 2)


def grid_line_error(points, pattern):
    """Fit each row/column by orthogonal least squares; no arbitrary pass threshold."""
    grid = np.asarray(points).reshape(pattern[1], pattern[0], 2)
    distances = []
    for line in [*grid, *grid.transpose(1, 0, 2)]:
        centered = line - line.mean(axis=0)
        _, _, basis = np.linalg.svd(centered, full_matrices=False)
        distances.extend(np.abs(centered @ basis[-1]).tolist())
    values = np.asarray(distances)
    return dict(rms_px=float(np.sqrt(np.mean(values ** 2))), mean_abs_px=float(values.mean()),
                max_abs_px=float(values.max()))


def evaluate_models(accepted, config, size):
    """Keep all accepted views; explicitly report every failed fold and parameter drift."""
    points = [r["corners"] for r in accepted]
    models = []
    for name in MODELS:
        cfg = dict(config, model=name)
        start = time.perf_counter()
        try:
            result = fit_model(cfg, points, [], size)
            result.update(model=name, status="candidate_unverified", hardware_applied=False, measurement_ready=False,
                          training_names=[r["name"] for r in accepted], cross_validation=[])
            # Fixed-intrinsic pose estimates are derived geometry, not external
            # distance/IMU truth. Board origin is the first detected inner corner.
            obj = object_points(cfg).astype(np.float64)
            result["view_poses"] = []
            for record in accepted:
                if name == MODELS[0]:
                    observed = point_rectification(result, record["corners"])
                    ok, rotation, translation = cv.solvePnP(obj, observed, np.eye(3), None)
                else:
                    ok, rotation, translation = cv.solvePnP(obj, np.asarray(record["corners"], np.float64),
                                                           np.array(result["K"]), np.array(result["D"]))
                if not ok or not np.isfinite(rotation).all() or not np.isfinite(translation).all():
                    raise ValueError("Unable to estimate a finite per-view pose")
                R, _ = cv.Rodrigues(rotation)
                centre = R @ obj.mean(axis=0) + translation.ravel()
                result["view_poses"].append(dict(name=record["name"], rotation_vector_rad=rotation.ravel().tolist(),
                    translation_mm=translation.ravel().tolist(), inner_grid_centre_camera_mm=centre.tolist(),
                    centre_ray_distance_mm=float(np.linalg.norm(centre)), centre_depth_mm=float(centre[2]),
                    plane_normal_tilt_deg=float(np.rad2deg(np.arccos(np.clip(abs(R[2, 2]), 0, 1)))),
                    method="fixed K/D solvePnP; normalized rays for fisheye", externally_verified=False))
        except (cv.error, ValueError) as error:
            models.append(dict(model=name, error=str(error)))
            continue
        for i, record in enumerate(accepted):
            others = points[:i] + points[i + 1:]
            fold = dict(held_out=record["name"], train_names=[r["name"] for j, r in enumerate(accepted) if j != i])
            try:
                held = fit_model(cfg, others, [points[i]], size)
                fold.update(rms_px=held["validation_errors_px"][0], K=held["K"], D=held["D"],
                            train_rms_px=held["rms_px"])
            except (cv.error, ValueError) as error:
                fold["error"] = str(error)
            result["cross_validation"].append(fold)
            print(f"{name}: held out {i + 1}/{len(points)} {fold.get('rms_px', fold.get('error'))}", flush=True)
        valid = [f for f in result["cross_validation"] if "rms_px" in f]
        if len(valid) == len(accepted):
            errors = np.array([f["rms_px"] for f in valid])
            parameters = np.array([[f["K"][0][0], f["K"][1][1], f["K"][0][2], f["K"][1][2], *f["D"]] for f in valid])
            result["loo_pooled_rms_px"] = float(np.sqrt(np.mean(errors ** 2)))
            result["loo_mean_rms_px"] = float(errors.mean())
            result["loo_max_rms_px"] = float(errors.max())
            result["fold_parameter_range"] = dict(names=["fx", "fy", "cx", "cy", *result["distortion_order"]],
                                                   minimum=parameters.min(axis=0).tolist(), maximum=parameters.max(axis=0).tolist(),
                                                   sample_std=parameters.std(axis=0, ddof=1).tolist(),
                                                   interpretation="correlated LOO sensitivity, not a confidence interval")
        result["seconds"] = time.perf_counter() - start
        models.append(result)
    return models


def make_maps(model, size, Kout):
    """Inverse output-to-source maps; OpenCV bilinear interpolation is software reference only."""
    K, D = np.array(model["K"]), np.array(model["D"])
    if model["model"] == MODELS[0]:
        x, y = cv.fisheye.initUndistortRectifyMap(K, D.reshape(4, 1), np.eye(3), Kout, size, cv.CV_32FC1)
    else:
        x, y = cv.initUndistortRectifyMap(K, D, np.eye(3), Kout, size, cv.CV_32FC1)
    mask = np.isfinite(x) & np.isfinite(y) & (x >= 0) & (y >= 0) & (x < size[0] - 1) & (y < size[1] - 1)
    return x, y, mask


def make_visuals(report, records, images, models, config, size, fov):
    """Plot coverage/errors and save labelled equal-camera comparisons for every input."""
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    accepted = [r for r in records if r["accepted"]]
    success = [m for m in models if "K" in m]
    fx = size[0] / (2 * np.tan(np.deg2rad(fov / 2)))
    Kout = np.array([[fx, 0, (size[0] - 1) / 2], [0, fx, (size[1] - 1) / 2], [0, 0, 1]])
    for model in success:
        x, y, mask = make_maps(model, size, Kout)
        model["software_output"] = dict(K=Kout.tolist(), image_size=list(size), horizontal_fov_deg=fov,
                                         bilinear_valid_fraction=float(mask.mean()), interpolation="INTER_LINEAR",
                                         border="BORDER_CONSTANT black", no_black_border_guarantee=False)
        cv.imwrite(str(report / (model["model"] + "-valid-mask.png")), mask.astype(np.uint8) * 255)
        model["line_errors"] = []
        for record in accepted:
            before = grid_line_error(record["corners"], (config["cols"], config["rows"]))
            after = grid_line_error(point_rectification(model, record["corners"], Kout), (config["cols"], config["rows"]))
            model["line_errors"].append(dict(name=record["name"], raw=before, rectified=after))
        # Domain evidence discloses how far real detected rays constrain the fit.
        rays = point_rectification(model, [p for r in accepted for p in r["corners"]])
        theta = np.arctan(np.linalg.norm(rays, axis=1))
        model["observed_ray_angle_deg"] = [float(np.rad2deg(theta.min())), float(np.rad2deg(theta.max()))]
        if model["model"] == MODELS[0]:
            t = np.linspace(0, theta.max(), 1000)
            d = np.array(model["D"])
            derivative = 1 + sum((2 * i + 3) * d[i] * t ** (2 * i + 2) for i in range(4))
            model["fisheye_min_radial_derivative_observed_domain"] = float(derivative.min())
        short = "fisheye" if model["model"] == MODELS[0] else "pinhole"
        for ordinal, original in images:
            corrected = cv.remap(original, x, y, cv.INTER_LINEAR, borderMode=cv.BORDER_CONSTANT)
            cv.imwrite(str(report / f"{short}-{ordinal:02}.png"), corrected)
    # Every corner is represented, and axes retain the original image coordinates.
    fig, ax = plt.subplots(figsize=(10, 5.8), constrained_layout=True)
    for r in accepted:
        p = np.asarray(r["corners"])
        ax.scatter(p[:, 0], p[:, 1], s=5, alpha=.45, label=str(r["ordinal"]))
    ax.set(xlim=(0, size[0]), ylim=(size[1], 0), xlabel="Original u [px]", ylabel="Original v [px]", title="Detected corner coverage - full-resolution RGB")
    ax.set_aspect("equal"); ax.legend(title="View", ncol=6, loc="lower center")
    ax.grid(alpha=.2)
    fig.savefig(report / "coverage.png", dpi=170); plt.close(fig)
    fig, ax = plt.subplots(figsize=(10, 4.4), constrained_layout=True)
    for m in success:
        if "loo_pooled_rms_px" not in m:
            continue
        label = "Fisheye" if m["model"] == MODELS[0] else "Pinhole k1,k2,p1,p2"
        ax.plot([r["ordinal"] for r in accepted], [f["rms_px"] for f in m["cross_validation"]], "o-", label=label)
    ax.set(xlabel="Held-out view", ylabel="Reprojection RMS [px]", title="Leave-one-view-out validation - K/D fixed for held-out pose")
    ax.set_xticks([r["ordinal"] for r in accepted]); ax.legend(); ax.grid(alpha=.2)
    fig.savefig(report / "loo-errors.png", dpi=170); plt.close(fig)
    # A small contact sheet makes all original inputs reviewable in the report.
    thumbs = []
    for ordinal, bgr in images:
        t = cv.resize(bgr, (480, 270))
        cv.putText(t, f"VIEW {ordinal:02}", (12, 26), cv.FONT_HERSHEY_SIMPLEX, .7, (0, 180, 255), 2)
        thumbs.append(t)
    while len(thumbs) % 3:
        thumbs.append(np.zeros((270, 480, 3), np.uint8))
    if thumbs:
        cv.imwrite(str(report / "contact-sheet.png"), np.vstack([np.hstack(thumbs[i:i + 3]) for i in range(0, len(thumbs), 3)]))
    for ordinal, bgr in images:
        panels = [cv.resize(bgr, (640, 360))]
        labels = ["Original RGB / unverified source"]
        for model in success:
            short = "fisheye" if model["model"] == MODELS[0] else "pinhole"
            panels.append(cv.resize(cv.imread(str(report / f"{short}-{ordinal:02}.png")), (640, 360)))
            labels.append(short + " / PC reference / FOV " + str(fov))
        for panel, label in zip(panels, labels):
            cv.rectangle(panel, (0, 0), (640, 31), (25, 34, 44), -1)
            cv.putText(panel, label, (10, 22), cv.FONT_HERSHEY_SIMPLEX, .5, (255, 255, 255), 1)
        cv.imwrite(str(report / f"comparison-{ordinal:02}.jpg"), np.hstack(panels), [cv.IMWRITE_JPEG_QUALITY, 93])
    return Kout


def run(args):
    """Produce a fresh standalone result without altering workbench groups or hardware."""
    size, pattern = (args.width, args.height), (args.cols, args.rows)
    if min(size) < 16 or max(size) > 4096 or min(pattern) < 3 or max(pattern) > 30:
        raise ValueError("Unsupported dimensions/board")
    if not np.isfinite(args.square_mm) or args.square_mm <= 0 or not 30 <= args.fov <= 140:
        raise ValueError("Invalid measured spacing or software output FOV")
    report, archive = args.report_dir.resolve(), args.archive_dir.resolve()
    if not report.is_relative_to(HOST / "reports") or not archive.is_relative_to(HOST / "data"):
        raise ValueError("Reports and evidence must stay in this checkout's host/reports and host/data")
    paths = sorted(args.input_dir.glob(args.glob), key=natural_key)
    if not paths:
        raise ValueError("No RGB inputs matched")
    report.mkdir(parents=True, exist_ok=True); archive.mkdir(parents=True, exist_ok=True)
    config = dict(pattern="chessboard", cols=args.cols, rows=args.rows, square_mm=args.square_mm)
    records, images = prepare_inputs(paths, size, pattern, archive, report, evidence_index(HOST))
    accepted = [r for r in records if r["accepted"]]
    # Three is an algorithmic minimum here, not the higher workbench acceptance policy.
    models = evaluate_models(accepted, config, size) if len(accepted) >= 4 else []
    candidates = [m for m in models if "loo_pooled_rms_px" in m]
    best = min(candidates, key=lambda m: m["loo_pooled_rms_px"])["model"] if candidates else None
    result = dict(schema="pango.offline_rgb_calibration.v1", created=datetime.now(timezone(timedelta(hours=8))).isoformat(),
                  config=config, image_size=list(size), pixel_format="RGB888", row_stride=size[0] * 3,
                  source_stage="unverified", source_frame_id=None, pairing_status="unverified",
                  status="candidate_unverified" if candidates else "insufficient_or_failed_fit",
                  hardware_applied=False, measurement_ready=False, inputs=records, accepted_count=len(accepted),
                  selected_model=best, selection_basis="minimum pooled leave-one-view-out reprojection RMS; no outer holdout",
                  models=models, environment=dict(python=sys.version, platform=platform.platform(), opencv=cv.__version__, numpy=np.__version__),
                  software_output_fov_deg=args.fov,
                  script_sha256=hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
                  independent_test_images=0, MTF50=None, SFR=None, hardware_latency_ms=None, hardware_fps=None,
                  # Keep the disclosure tied to the actual usable views as batches grow.
                  limitations=[f"{len(accepted)}-view candidate; no new independent test set",
                               "LOO model selection reuses folds; reported validation is not an unbiased outer-test estimate",
                               "board flatness, spacing accuracy, focus stability, crop and S1 equivalence not physically verified",
                               "historical per-image manual distance is a claim and is not a calibration constraint",
                               "full-frame corner coverage is incomplete; extrapolation is unverified",
                               "fisheye k3/k4 must never be written as pinhole p1/p2",
                               "software remapping is not FPGA verification; no hardware parameters applied"],
                  command=["host/scripts/calibrate_rgb_dataset.py", *sys.argv[1:]])
    if models:
        make_visuals(report, records, images, models, config, size, args.fov)
    save_json(archive / "manifest.json", dict(config=config, image_size=list(size), inputs=records))
    save_json(report / "calibration-results.json", result)
    # Parameter files remain explicitly typed and unverified; keep hashes beside them.
    for model in models:
        if "K" not in model:
            continue
        path = report / (model["model"] + ".json")
        save_json(path, dict(model, config=config, image_size=list(size), source_stage="unverified"))
        path.with_suffix(".sha256").write_text(hashlib.sha256(path.read_bytes()).hexdigest() + "  " + path.name + "\n", encoding="ascii")
        # Typed OpenCV YAML supplements JSON without implying FPGA register support.
        storage = cv.FileStorage(str(path.with_suffix(".yml")), cv.FILE_STORAGE_WRITE)
        storage.write("model", model["model"])
        storage.write("camera_matrix", np.array(model["K"]))
        storage.write("distortion_coefficients", np.array(model["D"]).reshape(-1, 1))
        storage.write("distortion_order", json.dumps(model["distortion_order"]))
        storage.write("image_width", size[0]); storage.write("image_height", size[1])
        storage.write("square_mm", args.square_mm)
        storage.write("status", "candidate_unverified")
        storage.release()
    with (report / "per-view-errors.csv").open("w", newline="", encoding="utf-8-sig") as stream:
        writer = csv.writer(stream); writer.writerow(["view", "model", "training_rms_px", "loo_rms_px", "raw_line_rms_px", "rectified_line_rms_px"])
        for m in models:
            if "K" in m:
                for r, train, fold, line in zip(accepted, m["training_errors_px"], m["cross_validation"], m["line_errors"]):
                    writer.writerow([r["name"], m["model"], train, fold.get("rms_px"), line["raw"]["rms_px"], line["rectified"]["rms_px"]])
    from .rgb_calibration_report import create_reports
    create_reports(result, report, pdf=not args.no_pdf)
    # Verify input/archive bytes again after fitting and report generation.
    for r in records:
        if any(hashlib.sha256(Path(r[key]).read_bytes()).hexdigest() != r["sha256"] for key in ("source_path", "archive_path")):
            raise ValueError("Input changed during processing: " + r["name"])
    print("Report:", report / "report.html", flush=True)
    print("Selected candidate model:", best, flush=True)
    return result


def main(argv=None):
    """Require explicit RGB dimensions and board measurements for replayable calibration."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--input-dir", type=Path, required=True)
    parser.add_argument("--glob", default="*.rgb")
    for name in ("width", "height", "cols", "rows"):
        parser.add_argument("--" + name, type=int, required=True)
    parser.add_argument("--square-mm", type=float, required=True)
    parser.add_argument("--fov", type=float, default=100, help="common output horizontal FOV; software comparison only")
    parser.add_argument("--report-dir", type=Path, required=True)
    parser.add_argument("--archive-dir", type=Path, required=True)
    parser.add_argument("--no-pdf", action="store_true")
    args = parser.parse_args(argv)
    result = run(args)
    return 0 if result["selected_model"] else 2

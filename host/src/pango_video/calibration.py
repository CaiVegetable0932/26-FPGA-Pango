"""Offline calibration; preserve evidence and never invent FPGA frame identity."""
import base64
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path
import re
import threading
import uuid

from .record_store import safe_child


def vision():
    """Load optional OpenCV lazily so existing RAW reception stays usable."""
    try:
        import cv2
        import numpy as np
    except ImportError as error:
        raise ValueError("请运行 python host/scripts/setup_calibration.py 后重启服务") from error
    return cv2, np


def write_json(path, value):
    """Atomically replace metadata; image evidence is immutable."""
    temporary = path.with_suffix(".tmp")
    temporary.write_text(json.dumps(value, ensure_ascii=False, indent=2, allow_nan=False), encoding="utf-8")
    temporary.replace(path)


def identifier(value):
    """Accept generated UUID hex only, including for download routes."""
    if not isinstance(value, str) or not re.fullmatch(r"[a-f0-9]{32}", value):
        raise ValueError("无效的标定记录 ID")
    return value


def finite_number(value, label, *, minimum=None, maximum=None, optional=False):
    """Validate measured manual quantities without accepting booleans or NaN."""
    if optional and value in (None, ""):
        return None
    if type(value) not in (int, float) or not math.isfinite(value):
        raise ValueError(label + "必须为有限数值")
    if minimum is not None and value < minimum or maximum is not None and value > maximum:
        raise ValueError(label + "超出允许范围")
    return float(value)


def manual_context(value):
    """Freeze operator measurements as claims, never as synchronized MCU telemetry."""
    if not isinstance(value, dict):
        raise ValueError("请填写本张图的人工测量信息")
    allowed = {"distance_mm", "distance_uncertainty_mm", "light_preset", "illuminance_lux",
               "exposure_us", "gimbal_roll_deg", "gimbal_pitch_deg", "gantry_x_mm",
               "gantry_y_mm", "gantry_z_mm", "notes"}
    if set(value) - allowed:
        raise ValueError("人工测量信息包含未知字段")
    result = {"distance_mm": finite_number(value.get("distance_mm"), "镜头到图卡距离(mm)", minimum=1, maximum=100000)}
    ranges = {"distance_uncertainty_mm": (0, 10000), "illuminance_lux": (0, 1000000),
              "exposure_us": (0, 10000000), "gimbal_roll_deg": (-180, 180),
              "gimbal_pitch_deg": (-180, 180), "gantry_x_mm": (-100000, 100000),
              "gantry_y_mm": (-100000, 100000), "gantry_z_mm": (-100000, 100000)}
    for key, (low, high) in ranges.items():
        result[key] = finite_number(value.get(key), key, minimum=low, maximum=high, optional=True)
    if result["distance_uncertainty_mm"] is not None and result["distance_uncertainty_mm"] >= result["distance_mm"]:
        raise ValueError("距离不确定度必须小于实测距离")
    if value.get("light_preset", "unknown") not in ("unknown", "1", "2", "3"):
        raise ValueError("光照预设仅接受未知或1/2/3")
    result["light_preset"] = value.get("light_preset", "unknown")
    notes = value.get("notes", "")
    if not isinstance(notes, str) or len(notes) > 2000:
        raise ValueError("人工记录备注过长或格式无效")
    result["notes"] = notes
    result["source"] = "manual_unverified"
    return result


def object_points(config):
    """Board coordinates use measured millimetres and row-major order."""
    _, np = vision()
    cols, rows = config["cols"], config["rows"]
    xy = np.mgrid[:cols, :rows].T.reshape(-1, 2).astype(np.float32)
    if config["pattern"] == "asymmetric_circles":
        xy[:, 0] = 2 * xy[:, 0] + xy[:, 1] % 2
    result = np.zeros((rows * cols, 3), np.float32)
    result[:, :2] = xy * config["square_mm"]
    return result


def fit_model(config, training, validation, size):
    """Fit the selected optical model; held-out images estimate pose only."""
    cv, np = vision()
    obj = object_points(config)
    points = [np.asarray(p, np.float32).reshape(-1, 1, 2) for p in training]
    # Earlier local groups used the restricted pinhole model and lack a model key.
    if config.get("model", "pinhole_k1_k2_p1_p2") == "fisheye_equidistant":
        # Purpose: keep OpenCV's four fisheye coefficients distinct from the
        # FPGA's unsupported four-coefficient pinhole register interpretation.
        obj64 = np.asarray(obj, np.float64).reshape(-1, 1, 3)
        images64 = [np.asarray(p, np.float64).reshape(-1, 1, 2) for p in training]
        K = np.array([[size[0] / 2, 0, size[0] / 2], [0, size[0] / 2, size[1] / 2], [0, 0, 1]], np.float64)
        D = np.zeros((4, 1), np.float64)
        rms, K, D, rotations, translations = cv.fisheye.calibrate(
            [obj64.copy() for _ in images64], images64, size, K, D,
            flags=cv.fisheye.CALIB_RECOMPUTE_EXTRINSIC | cv.fisheye.CALIB_FIX_SKEW)
        if not np.isfinite(K).all() or not np.isfinite(D).all() or not np.isfinite(rms) or min(K[0, 0], K[1, 1]) <= 0:
            raise ValueError("鱼眼标定退化，请增加距离、倾角和视场覆盖")

        def error_for(observed, rotation, translation):
            projected, _ = cv.fisheye.projectPoints(obj64, rotation, translation, K, D)
            delta = projected.reshape(-1, 2) - np.asarray(observed).reshape(-1, 2)
            return float(np.sqrt(np.mean(np.sum(delta ** 2, axis=1))))

        train_errors = [error_for(p, r, t) for p, r, t in zip(images64, rotations, translations)]
        validation_errors = []
        for observed in validation:
            normalized = cv.fisheye.undistortPoints(np.asarray(observed, np.float64).reshape(-1, 1, 2), K, D)
            ok, r, t = cv.solvePnP(obj64.reshape(-1, 3), normalized, np.eye(3), None)
            if not ok:
                raise ValueError("独立验证图位姿求解失败")
            validation_errors.append(error_for(observed, r, t))
        return dict(K=K.tolist(), D=D.ravel().tolist(),
                    distortion_order=["k1", "k2", "k3", "k4"], rms_px=float(rms),
                    training_errors_px=train_errors, validation_errors_px=validation_errors,
                    fpga_compatible=False)

    # Purpose: the existing FPGA candidate accepts only k1/k2/p1/p2 with k3 fixed.
    rms, K, D, rotations, translations = cv.calibrateCamera(
        [obj.copy() for _ in points], points, size, None, None, flags=cv.CALIB_FIX_K3)
    if not np.isfinite(K).all() or not np.isfinite(D).all() or not np.isfinite(rms) or min(K[0, 0], K[1, 1]) <= 0:
        raise ValueError("标定退化，请增加距离、倾角和视场覆盖")

    def error_for(observed, rotation, translation):
        projected, _ = cv.projectPoints(obj, rotation, translation, K, D)
        return float(np.sqrt(np.mean(np.sum((projected.reshape(-1, 2) - np.asarray(observed).reshape(-1, 2)) ** 2, axis=1))))

    train_errors = [error_for(p, r, t) for p, r, t in zip(points, rotations, translations)]
    validation_errors = []
    for p in validation:
        p = np.asarray(p, np.float32).reshape(-1, 1, 2)
        ok, r, t = cv.solvePnP(obj, p, K, D)
        if not ok:
            raise ValueError("独立验证图位姿求解失败")
        validation_errors.append(error_for(p, r, t))
    return dict(K=K.tolist(), D=D.ravel()[:4].tolist(), k3=0.0,
                distortion_order=["k1", "k2", "p1", "p2"], rms_px=float(rms),
                training_errors_px=train_errors, validation_errors_px=validation_errors,
                fpga_compatible=True)


class CalibrationStore:
    """Serialize calibration operations and retain failed/excluded images."""

    def __init__(self, host_root):
        self.root = Path(host_root)
        self.lock = threading.RLock()

    def folder(self, dataset):
        return safe_child(self.root, "data/calibration/" + identifier(dataset))

    def read(self, dataset):
        return json.loads((self.folder(dataset) / "dataset.json").read_text(encoding="utf-8"))

    def list(self):
        """Expose stored datasets and runtime availability after a restart."""
        with self.lock:
            root = safe_child(self.root, "data/calibration")
            items = [self.read(p.parent.name) for p in sorted(root.glob("*/dataset.json"))] if root.exists() else []
            try:
                cv, np = vision()
                environment = dict(available=True, opencv=cv.__version__, numpy=np.__version__)
            except ValueError as error:
                environment = dict(available=False, error=str(error))
            return dict(items=items, environment=environment)

    def create(self, config):
        """Freeze optics, board geometry and measurement reference per dataset."""
        if not isinstance(config, dict):
            raise ValueError("配置必须为 JSON 对象")
        allowed = {"model", "pattern", "cols", "rows", "square_mm", "board_id", "flatness",
                   "camera_id", "lens_id", "lens_focus", "distance_reference", "mode_notes"}
        if set(config) != allowed:
            raise ValueError("标定组配置字段不完整或包含未知字段")
        if config["model"] not in ("fisheye_equidistant", "pinhole_k1_k2_p1_p2"):
            raise ValueError("未知镜头模型")
        for key in ("cols", "rows"):
            if type(config.get(key)) is not int or not 3 <= config[key] <= 30:
                raise ValueError("内角点/圆心行列数应为 3～30 的整数")
        _, np = vision()
        spacing = config.get("square_mm")
        if type(spacing) not in (int, float) or not np.isfinite(spacing) or not 0 < spacing <= 1000:
            raise ValueError("请填写实测格长/间距（毫米）")
        if config.get("pattern") not in ("chessboard", "circles", "asymmetric_circles"):
            raise ValueError("未知图卡类型")
        for key in ("board_id", "camera_id", "lens_id", "lens_focus", "mode_notes", "flatness", "distance_reference"):
            if not isinstance(config.get(key), str) or not config[key].strip() or len(config[key]) > 2000:
                raise ValueError("请填写 " + key)
        # Purpose: persisted calibration inputs are normalized and marked as
        # operator-measured, not silently substituted with nominal dimensions.
        config = dict(config, square_mm=float(spacing), schema_version=2)
        dataset = uuid.uuid4().hex
        result = dict(id=dataset, created=datetime.now(timezone.utc).isoformat(), config=config,
                      samples=[], results=[], source_frame_id=None, pairing_status="unverified")
        with self.lock:
            folder = self.folder(dataset)
            folder.mkdir(parents=True)
            write_json(folder / "dataset.json", result)
        return result

    def add(self, dataset, request):
        """Archive original RGB plus uploaded bytes and derive an annotated preview.

        Browser RGB and decoded PNG/JPEG never claim board-S1 equivalence. Supplied
        metadata is preserved as a claim; it does not promote measurement readiness.
        """
        cv, np = vision()
        role, kind = request.get("role", "train"), request.get("kind")
        if role not in ("train", "validation") or kind not in ("browser_rgb", "rgb", "image", "raw8"):
            raise ValueError("无效的样本分组或格式")
        # Purpose: every capture has its own measured lens-to-target distance;
        # nominal set-up distance is insufficient when poses/distances vary.
        manual = manual_context(request.get("manual"))
        supplied = request.get("metadata", {})
        if not isinstance(supplied, dict):
            raise ValueError("元数据必须是 JSON 对象")
        # Known synthetic or corrected inputs are rejected even for manual uploads.
        from .calibration_source import check_source
        check_source(supplied)
        payload = base64.b64decode(request.get("payload", ""), validate=True)
        if not 0 < len(payload) <= 32 * 1024 * 1024:
            raise ValueError("图像数据大小不允许")
        with self.lock:
            state = self.read(dataset)
            if len(state["samples"]) >= 200:
                raise ValueError("每组最多 200 张，请新建标定组")
            if kind in ("rgb", "browser_rgb", "raw8"):
                width, height = request.get("width"), request.get("height")
                if type(width) is not int or type(height) is not int or not (16 <= width <= 4096 and 16 <= height <= 4096 and width * height <= 9000000):
                    raise ValueError("RGB 尺寸无效")
                if kind == "raw8":
                    # Purpose: preserve exact network bytes, and derive only a
                    # candidate RGB image for corner extraction.
                    bayer = request.get("bayer_code")
                    if type(bayer) is not int or bayer not in (1, 2, 3, 4) or len(payload) != width * height:
                        raise ValueError("RAW8 Bayer 相位或字节长度无效")
                    # Four-letter codes explicitly match protocol Bayer phases.
                    code = {1: cv.COLOR_BayerRGGB2RGB, 2: cv.COLOR_BayerGRBG2RGB,
                            3: cv.COLOR_BayerGBRG2RGB, 4: cv.COLOR_BayerBGGR2RGB}[bayer]
                    rgb = cv.cvtColor(np.frombuffer(payload, np.uint8).reshape(height, width), code)
                else:
                    if len(payload) != width * height * 3:
                        raise ValueError("RGB888 字节数与宽高不符，要求无行填充")
                    rgb = np.frombuffer(payload, np.uint8).reshape(height, width, 3)
            else:
                from .calibration_image import image_size
                width, height = image_size(payload)
                try:
                    bgr = cv.imdecode(np.frombuffer(payload, np.uint8), cv.IMREAD_COLOR | cv.IMREAD_IGNORE_ORIENTATION)
                except cv.error as error:
                    raise ValueError("无法解码图像容器") from error
                if bgr is None or bgr.shape[:2] != (height, width):
                    raise ValueError("图像解码失败或尺寸不匹配")
                rgb = cv.cvtColor(bgr, cv.COLOR_BGR2RGB)
            digest = hashlib.sha256(rgb.tobytes()).hexdigest()
            # A device/format change cannot silently enter an existing camera set.
            # File imports without provenance remain explicitly unknown candidates.
            device = supplied.get("device", {})
            identity = {key: supplied.get(key) for key in ("camera_id", "mode_id", "crop", "mirror", "isp_version")}
            if kind == "browser_rgb":
                identity = dict(device_id=device.get("deviceId") if isinstance(device, dict) else None)
            if kind == "raw8":
                identity = {key: supplied.get(key) for key in ("run_id", "source_stage", "stream_epoch",
                             "descriptor_id", "param_version", "bayer_code")}
                identity["bayer_code"] = request["bayer_code"]
            signature = json.dumps(dict(kind=kind, identity=identity), sort_keys=True, allow_nan=False)
            sample_id = uuid.uuid4().hex
            folder = self.folder(dataset) / sample_id
            folder.mkdir()
            (folder / "image.rgb").write_bytes(rgb.tobytes())
            if kind == "image":
                (folder / "upload.bin").write_bytes(payload)
            if kind == "raw8":
                (folder / "image.raw").write_bytes(payload)
            sample = dict(id=sample_id, role=role, kind=kind, width=width, height=height,
                          sha256=digest, upload_sha256=hashlib.sha256(payload).hexdigest(),
                          source_frame_id=None, source_frame_claim=supplied.get("frame_id") if kind == "raw8" else None,
                          pairing_status="unverified", measurement_ready=False,
                          source_metadata=supplied, manual=manual, captured=datetime.now(timezone.utc).isoformat(),
                          name=str(request.get("name", "capture"))[:256], corners=[], enabled=False,
                          reason="", source_signature=signature, decoded_from_compressed=(kind == "image"))
            if kind == "raw8":
                sample.update(original_file="image.raw", original_sha256=sample["upload_sha256"],
                              conversion="OpenCV bilinear Bayer to RGB at native resolution; no geometry transform",
                              s1_equivalence="unverified")
            reasons = []
            if kind == "raw8" and (supplied.get("source_mode") != "hardware_unverified" or
                                  supplied.get("pixel_format") != "RAW8" or
                                  supplied.get("transport_complete") is not True):
                reasons.append("不是完整硬件 RAW8 帧，不能加入拟合")
            if kind == "raw8" and supplied.get("bayer_code") != request["bayer_code"]:
                reasons.append("Bayer 相位声明与像素解析不一致")
            if state["samples"] and state["samples"][0].get("source_signature") != signature:
                reasons.append("输入设备/格式/来源声明改变，请新建标定组")
            expected_stride = width if kind == "raw8" else width * 3
            if kind in ("rgb", "raw8") and any(supplied.get(key, value) != value for key, value in (("width", width), ("height", height), ("row_stride", expected_stride))):
                reasons.append("元数据尺寸或行跨度与像素格式不一致")
            if any(s["sha256"] == digest for s in state["samples"]):
                reasons.append("重复图像，不计入独立样本")
            if state["samples"] and [width, height] != [state["samples"][0]["width"], state["samples"][0]["height"]]:
                reasons.append("尺寸与本组不一致")
            if kind in ("rgb", "raw8") and supplied.get("sha256") and supplied["sha256"] != sample["upload_sha256"]:
                reasons.append("提供的原始字节 SHA-256 不匹配")
            gray = cv.cvtColor(rgb, cv.COLOR_RGB2GRAY)
            config = state["config"]
            pattern = (config["cols"], config["rows"])
            corners = None
            try:
                if config["pattern"] == "chessboard":
                    found, corners = cv.findChessboardCornersSB(gray, pattern, flags=cv.CALIB_CB_NORMALIZE_IMAGE)
                else:
                    flag = cv.CALIB_CB_SYMMETRIC_GRID if config["pattern"] == "circles" else cv.CALIB_CB_ASYMMETRIC_GRID
                    found, corners = cv.findCirclesGrid(gray, pattern, flags=flag)
                if not found:
                    reasons.append("未检测到完整角点/圆心，请检查行列、清晰度和遮挡")
                else:
                    sample["corners"] = corners.reshape(-1, 2).tolist()
            except cv.error as error:
                reasons.append("检测失败：" + str(error))
            sample.update(enabled=not reasons, eligible=not reasons, reason="；".join(reasons))
            # Overlays exist only in a derived PNG; original RGB is untouched.
            preview = cv.cvtColor(rgb, cv.COLOR_RGB2BGR)
            if sample["corners"]:
                cv.drawChessboardCorners(preview, pattern, corners, True)
            ok, png = cv.imencode(".png", preview)
            if not ok:
                raise ValueError("无法编码角点预览")
            (folder / "corners.png").write_bytes(png.tobytes())
            write_json(folder / "metadata.json", sample)
            state["samples"].append(sample)
            write_json(self.folder(dataset) / "dataset.json", state)
            return sample

    def select(self, dataset, sample_id, enabled, reason):
        """Exclude without deleting evidence and audit every manual decision."""
        if type(enabled) is not bool or not isinstance(reason, str) or not reason.strip():
            raise ValueError("选入/剔除必须填写原因")
        with self.lock:
            state = self.read(dataset)
            sample = next((s for s in state["samples"] if s["id"] == identifier(sample_id)), None)
            if sample is None or (enabled and not sample["eligible"]):
                raise ValueError("样本不存在或不具备拟合条件")
            sample["enabled"] = enabled
            sample.setdefault("selection_history", []).append(dict(enabled=enabled, reason=reason[:2000], at=datetime.now(timezone.utc).isoformat()))
            write_json(self.folder(dataset) / sample_id / "metadata.json", sample)
            write_json(self.folder(dataset) / "dataset.json", state)
            return sample

    def solve(self, dataset):
        """Save a versioned candidate; no automatic pruning of high-error images."""
        cv, np = vision()
        with self.lock:
            state = self.read(dataset)
            selected = [s for s in state["samples"] if s["enabled"] and s["eligible"]]
            train = [s for s in selected if s["role"] == "train"]
            valid = [s for s in selected if s["role"] == "validation"]
            if len(train) < 25 or len(valid) < 3:
                raise ValueError("至少需要 25 张有效拟合图和 3 张不同的独立验证图；建议拟合集 25～40 张")
            for s in selected:
                if hashlib.sha256((self.folder(dataset) / s["id"] / "image.rgb").read_bytes()).hexdigest() != s["sha256"]:
                    raise ValueError("原始图像校验失败：" + s["id"])
                if s["kind"] == "raw8" and hashlib.sha256((self.folder(dataset) / s["id"] / "image.raw").read_bytes()).hexdigest() != s["upload_sha256"]:
                    raise ValueError("RAW8 原始字节校验失败：" + s["id"])
            size = (train[0]["width"], train[0]["height"])
            try:
                result = fit_model(state["config"], [s["corners"] for s in train], [s["corners"] for s in valid], size)
            except cv.error as error:
                raise ValueError("标定失败：" + str(error)) from error
            # Occupancy counts show coverage gaps without inventing an acceptance threshold.
            bins = np.zeros((3, 4), dtype=int)
            for s in train:
                for x, y in s["corners"]:
                    bins[min(2, int(y * 3 / size[1])), min(3, int(x * 4 / size[0]))] += 1
            version = uuid.uuid4().hex
            # Purpose: archive operator-measured distance per frame without
            # pretending that it constrains the OpenCV intrinsic fit.
            # Legacy evidence has no manual measurements; keep them null, never invent values.
            distances = [{"sample_id":s["id"], "distance_mm":(s.get("manual") or {}).get("distance_mm"),
                          "uncertainty_mm":(s.get("manual") or {}).get("distance_uncertainty_mm")} for s in selected]
            model = state["config"].get("model", "pinhole_k1_k2_p1_p2")
            result.update(version=version, dataset_id=dataset, model=model,
                          pixel_center="integer (0,0)", image_size=list(size), config=state["config"],
                          opencv=cv.__version__, created=datetime.now(timezone.utc).isoformat(),
                          status="candidate_unverified", measurement_ready=False, hardware_applied=False,
                          coverage_4x3=bins.tolist(), independent_grid_validation="not_performed",
                          warnings=["人工距离仅作实验记录，未作为内参拟合约束", "来源与 S1 几何等价性需独立验证",
                                    "重投影误差不等同于独立网格直线度或有效域验收"] +
                                   (["鱼眼系数不兼容当前 FPGA 针孔 k1/k2/p1/p2 寄存器，禁止直接下发"]
                                    if model == "fisheye_equidistant" else []) +
                                   (["旧样本缺少人工测距记录，相关值保持 null"] if any(d["distance_mm"] is None for d in distances) else []),
                          manual_distances=distances,
                          samples=state["samples"], training_ids=[s["id"] for s in train],
                          validation_ids=[s["id"] for s in valid])
            folder = safe_child(self.root, "reports/calibration/" + dataset)
            folder.mkdir(parents=True, exist_ok=True)
            path = folder / (version + ".json")
            write_json(path, result)
            digest = hashlib.sha256(path.read_bytes()).hexdigest()
            path.with_suffix(".sha256").write_text(digest + "  " + path.name + "\n", encoding="ascii")
            state["results"].append(dict(version=version, sha256=digest))
            write_json(self.folder(dataset) / "dataset.json", state)
            return result

    def artifact(self, dataset, sample, filename, version=None):
        """Allow only owned calibration files, with safe path traversal checks."""
        if version:
            if filename not in ("json", "sha256"):
                raise ValueError("未知结果格式")
            return safe_child(self.root, "reports/calibration/" + identifier(dataset) + "/" + identifier(version) + "." + filename)
        if filename not in ("image.rgb", "image.raw", "metadata.json", "corners.png"):
            raise ValueError("未知标定文件")
        return safe_child(self.root, "data/calibration/" + identifier(dataset) + "/" + identifier(sample) + "/" + filename)


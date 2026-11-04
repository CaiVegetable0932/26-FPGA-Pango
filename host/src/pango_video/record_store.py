"""Inventory and explicit deletion of generated host evidence, never source files."""
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import shutil


class RecordError(ValueError):
    pass


def _plain(path):
    return not path.is_symlink() and not (hasattr(path, "is_junction") and path.is_junction())


def safe_child(root, relative):
    root = Path(root).absolute()
    if not isinstance(relative, str) or not relative or len(relative) > 400:
        raise RecordError("无效的记录路径")
    parts = relative.split("/")
    if any(p in ("", ".", "..") or "\\" in p or ":" in p or "\0" in p for p in parts):
        raise RecordError("记录路径不允许")
    if not _plain(root):
        raise RecordError("记录目录不能是符号链接或目录联接")
    current = root
    for part in parts:
        current = current/part
        if not _plain(current):
            raise RecordError("不允许通过链接访问记录")
    result = current.resolve()
    if result == root.resolve() or not result.is_relative_to(root.resolve()):
        raise RecordError("记录不在允许的目录中")
    return result


def _children(path, directories=True):
    if not path.is_dir() or not _plain(path):
        return []
    result = []
    for p in path.iterdir():
        try:
            if p.name.startswith(".") or not _plain(p):
                continue
            if p.is_dir() if directories else p.is_file():
                result.append(p)
        except OSError:
            continue
    return sorted(result, key=lambda p: _mtime(p), reverse=True)


def _mtime(path):
    try:
        return path.stat().st_mtime
    except OSError:
        return 0


def _read_json(path, maximum=2_000_000):
    if not _plain(path) or path.stat().st_size > maximum:
        raise RecordError("报告无效或过大")
    result = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(result, dict):
        raise RecordError("报告必须为JSON对象")
    return result


def sample_metadata(root, key):
    folder = safe_child(root/"data", key)
    meta = _read_json(safe_child(folder, "metadata.json"), 1_000_000)
    if meta.get("file") not in ("image.raw", "image.rgb") or meta.get("transport_complete") is not True:
        raise RecordError("原始图像尚未完整提交")
    if meta.get("pixel_format") not in ("RAW8", "RGB888"):
        raise RecordError("不支持的归档像素格式")
    if meta["pixel_format"] == "RAW8" and meta.get("bayer_code") not in (1, 2, 3, 4):
        raise RecordError("Bayer排列无效")
    for name in ("width", "height", "row_stride", "frame_bytes"):
        if type(meta.get(name)) is not int or meta[name] <= 0:
            raise RecordError("归档图像尺寸无效")
    bpp = 1 if meta["pixel_format"] == "RAW8" else 3
    if meta["row_stride"] != meta["width"]*bpp or meta["frame_bytes"] != meta["row_stride"]*meta["height"]:
        raise RecordError("归档图像行跨度无效")
    pixels = safe_child(folder, meta["file"])
    if not 0 < pixels.stat().st_size == meta["frame_bytes"] <= 8*1024*1024:
        raise RecordError("归档图像字节长度不匹配")
    meta["frame_id"], meta["stream_epoch"] = str(meta["frame_id"]), str(meta["stream_epoch"])
    return folder, meta


def archives(root, limit=None):
    data = Path(root)/"data"
    records = []
    for run in _children(data):
        # Keep historical video evidence outside RAW runs; never treat its folder
        # as a RAW run that the legacy record-deletion API could remove wholesale.
        if run.name == "recordings":
            continue
        for folder in _children(run):
            key = folder.relative_to(data).as_posix()
            record = dict(key=key, run_id=run.name, frame_id=None, source_mode="unknown",
                saved_utc=datetime.fromtimestamp(_mtime(folder), timezone.utc).isoformat(),
                width=None, height=None, frame_bytes=0, pixel_format="—",
                complete=False, state="未完成 / 组合记录", sha256="", tap=None)
            try:
                _, meta = sample_metadata(Path(root), key)
                record.update(frame_id=meta["frame_id"], source_mode=meta.get("source_mode", "unknown"),
                    saved_utc=meta.get("saved_utc"), width=meta["width"], height=meta["height"],
                    frame_bytes=meta["frame_bytes"], pixel_format=meta["pixel_format"],
                    sha256=meta.get("sha256", ""), complete=True, state="完整",
                    tap="S0" if meta["pixel_format"] == "RAW8" else (meta.get("descriptor") or {}).get("tap", "RGB"))
            except (OSError, ValueError, KeyError, TypeError):
                pass
            records.append(record)
    return records if limit is None else records[:limit]


def runs(root, limit=None):
    root = Path(root)
    reports_dir = root/"reports"
    # Historical "recordings" data remains outside RAW run ownership.
    names = {p.name for base in (root/"data", reports_dir) for p in _children(base) if p.name != "recordings"}
    records = []
    for name in names:
        report_dir = safe_child(reports_dir, name)
        files = [report_dir/"web-session.json", report_dir/"receiver.json"]
        path = next((p for p in files if p.is_file() and _plain(p)), None)
        record = dict(key=None if path is None else path.relative_to(reports_dir).as_posix(),
            run_id=name, mode="unknown", frames=0, saved=0, errors=0, seconds=0,
            state="未完成 / 无结束报告", modified=max(_mtime(report_dir), _mtime(root/"data"/name)))
        try:
            r = _read_json(path) if path is not None else {}
            config = r.get("config", r.get("configuration", {}))
            if not config and (report_dir/"receiver-config.json").is_file():
                config = _read_json(report_dir/"receiver-config.json")
            metrics = r.get("metrics", r.get("receiver", {}))
            counts = metrics.get("assembly", {}).get("counters", {})
            record.update(mode=config.get("source_mode", r.get("source_mode", "unknown")),
                frames=counts.get("live_frames_complete", 0),
                saved=r.get("saved_frames", r.get("storage", {}).get("frames_saved", 0)),
                errors=sum(v for k, v in counts.items() if k.startswith(("frames_failed_", "packets_rejected_"))),
                seconds=r.get("elapsed_seconds", r.get("elapsed_receive_seconds", 0)),
                state="异常结束" if r.get("error") else "已结束" if path else "未完成 / 无结束报告")
        except (OSError, ValueError, KeyError, TypeError, AttributeError):
            record["state"] = "报告不完整"
        records.append(record)
    records.sort(key=lambda r: (r["modified"], r["run_id"]), reverse=True)
    return records if limit is None else records[:limit]


def reports(root):
    records = []
    for p in _children(Path(root)/"reports", directories=False):
        if p.name.lower() == "readme.md" or p.suffix.lower() not in (".json", ".md", ".log", ".csv", ".txt", ".html", ".pdf"):
            continue
        records.append(dict(key=p.name, name=p.name, extension=p.suffix[1:].upper(),
            bytes=p.stat().st_size, modified_utc=datetime.fromtimestamp(_mtime(p), timezone.utc).isoformat()))
    return records


def inventory(root, active_run_id=None):
    result = dict(archives=archives(root), runs=runs(root), reports=reports(root))
    for kind in ("archives", "runs"):
        for item in result[kind]:
            item["protected"] = item["run_id"] == active_run_id
            if item["protected"]:
                item["state"] = "正在采集"
    result["total"] = sum(len(result[k]) for k in ("archives", "runs", "reports"))
    return result


def report_file(root, key):
    if key not in {r["key"] for r in reports(root)}:
        raise RecordError("找不到生成报告")
    return safe_child(Path(root)/"reports", key)


def _check_tree(base, path):
    """Verify the absolute target and every descendant before recursive removal."""
    base, path = base.resolve(), path.absolute()
    if path == base or not path.resolve().is_relative_to(base) or not _plain(path):
        raise RecordError("删除目标超出记录目录或包含链接")
    if path.is_dir():
        for parent, dirs, files in os.walk(path, followlinks=False):
            for name in dirs+files:
                child = Path(parent)/name
                if not _plain(child) or not child.resolve().is_relative_to(base):
                    raise RecordError("记录包含链接，未执行删除")


def delete_records(root, targets, active_run_id=None):
    """Validate the entire selection, then delete only catalogued records.

    A run owns both its data and reports folders. Children covered by a selected
    run are counted once without attempting a second filesystem deletion.
    """
    root = Path(root).resolve()
    if not isinstance(targets, list) or not 1 <= len(targets) <= 5000:
        raise RecordError("每批请选择1至5000条记录")
    catalog = inventory(root, active_run_id)
    lookup = {"archive":{r["key"]:r for r in catalog["archives"]},
              "run":{r["run_id"]:r for r in catalog["runs"]},
              "report":{r["key"]:r for r in catalog["reports"]}}
    selected = {}
    for target in targets:
        if not isinstance(target, dict) or set(target) != {"kind", "key"}:
            raise RecordError("删除记录格式无效")
        kind, key = target["kind"], target["key"]
        if not isinstance(kind, str) or kind not in lookup or not isinstance(key, str) or key not in lookup[kind]:
            raise RecordError("所选记录已不存在或不允许删除，请刷新列表")
        item = lookup[kind][key]
        if item.get("protected"):
            raise RecordError("正在采集的记录不能删除，请先停止采集")
        selected[(kind, key)] = item

    plans = {}
    for (kind, key), item in selected.items():
        pairs = [("data", key)] if kind == "archive" else [("reports", key)] if kind == "report" else [
            ("data", key), ("reports", key)]
        paths = []
        for area, relative in pairs:
            base = root/area
            path = safe_child(base, relative)
            if path.exists():
                _check_tree(base, path)
                paths.append((base, path))
        plans[(kind, key)] = paths

    result = dict(deleted=[], failed=[])
    completed_runs = set()
    # Parent runs go first; never remove a child of a failed parent separately.
    for (kind, key), item in sorted(selected.items(), key=lambda entry: entry[0][0] != "run"):
        run = item.get("run_id")
        covered = kind == "archive" and ("run", run) in selected
        if covered:
            if run in completed_runs:
                result["deleted"].append(dict(kind=kind, key=key))
            else:
                result["failed"].append(dict(kind=kind, key=key, error="所属运行未能完整删除"))
            continue
        try:
            for base, path in plans[(kind, key)]:
                # Re-check resolved boundaries immediately before the mutation.
                checked = safe_child(base, path.relative_to(base.resolve()).as_posix())
                _check_tree(base, checked)
                if checked.is_dir():
                    shutil.rmtree(checked)
                else:
                    checked.unlink()
            result["deleted"].append(dict(kind=kind, key=key))
            if kind == "run":
                completed_runs.add(key)
        except (OSError, RecordError) as error:
            result["failed"].append(dict(kind=kind, key=key, error=str(error)))
    return result

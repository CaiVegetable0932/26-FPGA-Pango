"""Local Web UI adapter. UDP ownership remains in a single receive thread."""
from collections import deque
from copy import deepcopy
from datetime import datetime, timezone
import hashlib
import ipaddress
import json
from pathlib import Path
import subprocess
import sys
import threading
import time
import uuid

from .cli import HOST_ROOT, validate_config
from .protocol import FormatLimits
from .reassembly import FrameAssembler
from .receiver import UDPReceiver
from .storage import save_frame


class SessionError(ValueError):
    pass


def utc_now():
    return datetime.now(timezone.utc).isoformat()


def public_config(config):
    result = dict(config)
    result["stream_epoch"] = str(result["stream_epoch"])
    return result


def frame_info(frame, run_id, source_mode):
    h = frame.header
    return dict(run_id=run_id, source_mode=source_mode,
        frame_id=str(h.frame_id), stream_epoch=str(h.stream_epoch),
        descriptor_id=h.descriptor_id, param_version=h.param_version,
        width=h.width, height=h.height, row_stride=h.row_stride,
        frame_bytes=h.frame_bytes, pixel_format="RAW8" if h.packet_type == 1 else "RGB888",
        bayer_code=h.bayer_code, packet_count=h.packet_count,
        key=f"{run_id}:{h.stream_epoch}:{h.frame_id}:{h.packet_type}:{h.descriptor_id}",
        source_stage="S0" if h.packet_type == 1 else "snapshot",
        transport_complete=True, measurement_ready=False)


class WebSession:
    def __init__(self, root=HOST_ROOT):
        self.root = Path(root).resolve()
        self._lock = threading.RLock()
        self._operation = threading.Lock()
        self._thread = None
        self._receiver = None
        self._mock = None
        self._stop = threading.Event()
        self._done = threading.Event()
        self._state = "idle"
        self._config = json.loads((self.root / "config/receiver.mock.json").read_text(encoding="utf-8"))
        self._metrics = {}
        self._frame = None
        self._events = deque(maxlen=60)
        self._history = deque(maxlen=60)
        self._ticks = deque(maxlen=12)
        self._pending = set()
        self._manual_enqueued = self._manual_rejected = 0
        self._saved_count = 0
        self._error = None
        self._source_hashes = {}
        self._run_id = None
        self._started_utc = None
        self._started = None
        self._ended = None
        self._fps = self._mbps = self._pps = 0.0
        self._last_history = 0.0
        self._last_failures = 0

    def _event(self, kind, message):
        with self._lock:
            self._events.append(dict(time=utc_now(), kind=kind, message=message))

    def _validated(self, data):
        if not isinstance(data, dict):
            raise SessionError("连接设置必须是对象")
        config = dict(data)
        epoch = config.get("stream_epoch")
        if isinstance(epoch, str):
            if not epoch.isascii() or not epoch.isdecimal() or len(epoch) > 20:
                raise SessionError("源代次必须是无符号64位十进制整数")
            config["stream_epoch"] = int(epoch)
        try:
            validate_config(config)
        except (ValueError, TypeError) as error:
            raise SessionError(str(error)) from error
        if not 1 <= config["port"] <= 65535 or not 1 <= config["peer_port"] <= 65535:
            raise SessionError("UDP端口必须在1至65535之间")
        if any(not 2 <= config[k] <= 4096 or config[k] % 2 for k in ("width", "height")):
            raise SessionError("Web预览尺寸须为2至4096之间的偶数")
        if config["width"] * config["height"] > 8 * 1024 * 1024:
            raise SessionError("RAW帧超过8MiB上限")
        if not 65536 <= config["receive_buffer_bytes"] <= 64 * 1024 * 1024:
            raise SessionError("接收缓冲必须在64KiB至64MiB之间")
        if not config["device_id"].strip():
            raise SessionError("设备标识不能为空白")
        if len(config["device_id"]) > 128:
            raise SessionError("设备标识过长")
        if config["source_mode"] == "mock":
            if not all(ipaddress.IPv4Address(config[k]).is_loopback for k in ("bind_ip", "peer_ip")):
                raise SessionError("模拟模式只能使用本机回环地址")
            if config["port"] == config["peer_port"]:
                raise SessionError("模拟发送与接收须使用不同端口")
        return config

    def configure(self, data):
        config = self._validated(data)
        with self._operation, self._lock:
            if self._thread and self._thread.is_alive():
                raise SessionError("请先停止采集，再更改连接设置")
            self._config = config
            return public_config(config)

    def start(self, *, config=None, archive_every=0, auto_mock=True):
        if type(archive_every) is not int or not 0 <= archive_every <= 100000:
            raise SessionError("归档间隔必须为0至100000之间的整数")
        if type(auto_mock) is not bool:
            raise SessionError("auto_mock必须是布尔值")
        with self._operation:
            if self._thread and self._thread.is_alive():
                raise SessionError("采集已启动")
            current = self._validated(self._config if config is None else config)
            assembler = FrameAssembler(device_id=current["device_id"], stream_epoch=current["stream_epoch"],
                format_limits=FormatLimits(current["width"], current["height"],
                                           expected_bayer_code=current["bayer_code"]))
            source_hashes = {p.relative_to(HOST_ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                for folder in ("src/pango_video","web") for p in sorted((HOST_ROOT/folder).glob("*")) if p.is_file()}
            receiver = UDPReceiver(assembler, bind=(current["bind_ip"], current["port"]),
                peer=(current["peer_ip"], current["peer_port"]),
                receive_buffer_bytes=current["receive_buffer_bytes"], archive_every=archive_every)
            try:
                receiver.open()
            except OSError as error:
                raise SessionError(f"无法打开UDP接收端口：{error}") from error
            run_id = f"web-{current['source_mode']}-{datetime.now(timezone.utc):%Y%m%dT%H%M%SZ}-{uuid.uuid4().hex[:8]}"
            report_dir = self.root / "reports" / run_id
            process = None
            try:
                report_dir.mkdir(parents=True, exist_ok=False)
                config_path = report_dir / "receiver-config.json"
                config_path.write_text(json.dumps(current, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
                if current["source_mode"] == "mock" and auto_mock:
                    with (report_dir / "mock-sender.log").open("wb") as log:
                        process = subprocess.Popen([sys.executable, "-X", "utf8", "-B",
                            str(HOST_ROOT / "scripts/praw_demo.py"), "--config", str(config_path)],
                            stdout=log, stderr=log, cwd=self.root,
                            creationflags=subprocess.CREATE_NO_WINDOW if sys.platform == "win32" else 0)
            except BaseException:
                receiver.close()
                if process is not None:
                    process.terminate()
                    process.wait(timeout=3)
                raise
            with self._lock:
                self._config, self._receiver, self._mock = current, receiver, process
                self._stop, self._done = threading.Event(), threading.Event()
                self._state, self._error, self._frame = "listening", None, None
                self._source_hashes = source_hashes
                self._run_id, self._started_utc = run_id, utc_now()
                self._started, self._ended = time.monotonic(), None
                self._pending.clear()
                self._manual_enqueued = self._manual_rejected = 0
                self._saved_count = 0
                self._events.clear()
                self._history.clear()
                self._ticks.clear()
                self._fps = self._mbps = self._pps = 0.0
                self._last_history = self._last_failures = 0
                self._metrics = receiver.status()
                self._event("info", "已启动本机模拟信号" if process else "接收端已就绪，等待来源数据")
            self._thread = threading.Thread(target=self._run, name="praw-web-receiver", daemon=True)
            self._thread.start()
            return self.status()

    def _observe(self, metrics):
        if self._mock is not None and not self._stop.is_set():
            result = self._mock.poll()
            if result is not None:
                with self._lock:
                    if result:
                        self._error = f"模拟发送器退出（{result}），详见本轮mock-sender.log"
                self._event("error" if result else "info", self._error or "本轮模拟发送已结束")
                self._stop.set()
        now = time.monotonic()
        c = metrics["assembly"]["counters"]
        point = (now, c.get("live_frames_complete", 0), c.get("live_bytes_complete", 0),
                 metrics["counters"].get("datagrams_received", 0))
        with self._lock:
            self._metrics = metrics
            self._ticks.append(point)
            while len(self._ticks) > 2 and self._ticks[1][0] < now - 1:
                self._ticks.popleft()
            base = self._ticks[0]
            dt = now - base[0]
            if dt >= 0.1:
                self._fps = (point[1] - base[1]) / dt
                self._mbps = (point[2] - base[2]) / dt / 1_000_000
                self._pps = (point[3] - base[3]) / dt
            failed = sum(v for k, v in c.items() if k.startswith("frames_failed_") and k != "frames_failed_stopped")
            if failed > self._last_failures:
                self._event("warning", f"新增{failed-self._last_failures}张组帧失败，请检查链路")
                self._last_failures = failed
            if now - self._last_history >= 0.9:
                self._history.append(dict(second=round(now-self._started, 1), fps=round(self._fps, 2)))
                self._last_history = now

    def _preview(self):
        rx = self._receiver
        while not self._done.is_set() or rx.live_frames.status()["frames"]:
            frame = rx.live_frames.get(timeout=0.05)
            if frame is not None:
                with self._lock:
                    if self._frame is None or frame.header.frame_id > self._frame.header.frame_id:
                        self._frame = frame

    def _archive(self):
        rx = self._receiver
        try:
            while not self._done.is_set() or rx.archive_frames.status()["frames"]:
                frame = rx.archive_frames.get(timeout=0.05)
                if frame is None:
                    continue
                h = frame.header
                name = f"e{h.stream_epoch}_f{h.frame_id}_t{h.packet_type}_d{h.descriptor_id}"
                destination = self.root/"data"/self._run_id/name
                if not (destination/"metadata.json").is_file():
                    save_frame(frame, destination,
                               device_id=self._config["device_id"], source_mode=self._config["source_mode"])
                    with self._lock:
                        self._saved_count += 1
                    self._event("success", f"源帧 {h.frame_id} 原始数据已保存")
                with self._lock:
                    self._pending.discard(name)
        except Exception as error:
            with self._lock:
                self._error = f"归档失败：{error}"
            self._event("error", self._error)
            self._stop.set()

    def _stop_mock(self):
        process = self._mock
        if process is not None and process.poll() is None:
            process.terminate()
            try:
                process.wait(timeout=3)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=3)

    def _run(self):
        preview = threading.Thread(target=self._preview, name="praw-preview-consumer", daemon=True)
        writer = threading.Thread(target=self._archive, name="praw-web-archive", daemon=True)
        preview.start()
        writer.start()
        try:
            self._receiver.run(self._stop, on_status=self._observe)
        except Exception as error:
            with self._lock:
                self._error = f"接收失败：{error}"
            self._event("error", self._error)
        finally:
            self._receiver.close()
            self._stop.set()
            self._done.set()
            self._stop_mock()
            preview.join()
            writer.join()
            self._observe(self._receiver.status())
            with self._lock:
                self._state = "error" if self._error else "stopped"
                self._ended = time.monotonic()
            self._event("info", "采集已停止，运行报告已整理")
            report = self.status()
            report["source_sha256"] = self._source_hashes
            report["hardware_acceptance"] = "not_performed"
            report["ended_utc"] = utc_now()
            try:
                (self.root/"reports"/self._run_id/"web-session.json").write_text(
                    json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
            except OSError as error:
                with self._lock:
                    self._error = f"运行报告保存失败：{error}"
                    self._state = "error"

    def stop(self):
        with self._operation:
            if self._thread and self._thread.is_alive():
                with self._lock:
                    self._state = "stopping"
                self._stop.set()
                self._thread.join(timeout=8)
                if self._thread.is_alive():
                    raise SessionError("正在排空归档队列，请稍后再检查")
            return self.status()

    def records(self):
        from .record_store import inventory
        with self._operation:
            active = self._run_id if self._thread and self._thread.is_alive() else None
            return inventory(self.root, active)

    def delete_records(self, targets):
        from .record_store import RecordError, delete_records
        with self._operation:
            active = self._run_id if self._thread and self._thread.is_alive() else None
            try:
                return delete_records(self.root, targets, active)
            except RecordError as error:
                raise SessionError(str(error)) from error

    def save_current(self):
        with self._operation, self._lock:
            frame = self._frame
            if not self._thread or not self._thread.is_alive() or self._stop.is_set():
                raise SessionError("请先启动采集")
            if frame is None or time.monotonic_ns() - frame.complete_ns > 1_000_000_000:
                raise SessionError("没有1秒内的完整新帧可保存")
            h = frame.header
            name = f"e{h.stream_epoch}_f{h.frame_id}_t{h.packet_type}_d{h.descriptor_id}"
            if (self.root/"data"/self._run_id/name/"metadata.json").is_file() or name in self._pending:
                return dict(status="already_saved_or_queued", frame_id=str(h.frame_id))
            accepted, _ = self._receiver.archive_frames.offer(frame)
            if not accepted:
                self._manual_rejected += 1
                raise SessionError("归档队列已满，请等待写入完成")
            self._manual_enqueued += 1
            self._pending.add(name)
            return dict(status="queued", frame_id=str(h.frame_id))

    def latest(self):
        with self._lock:
            if self._frame is None or self._state in ("idle", "stopping", "stopped", "error"):
                return None
            if time.monotonic_ns() - self._frame.complete_ns > 1_000_000_000:
                return None
            return self._frame, frame_info(self._frame, self._run_id, self._config["source_mode"])

    def status(self):
        with self._lock:
            running = self._state in ("listening", "stopping")
            age = None if self._frame is None else max(0, (time.monotonic_ns()-self._frame.complete_ns)/1_000_000)
            signal = "live" if running and age is not None and age <= 1000 else "waiting" if running else "stopped"
            metrics = deepcopy(self._metrics)
            assembly = metrics.get("assembly", {})
            for key in ("stream_epoch", "live_first_id", "live_highwater"):
                if assembly.get(key) is not None:
                    assembly[key] = str(assembly[key])
            for failure in metrics.get("recent_failures", []):
                if "key" in failure:
                    failure["key"] = [str(v) if i < 2 else v for i,v in enumerate(failure["key"])]
            now = self._ended if self._ended is not None else time.monotonic()
            return dict(state=self._state, signal=signal, running=running,
                config=public_config(self._config), run_id=self._run_id, started_utc=self._started_utc,
                elapsed_seconds=0 if self._started is None else max(0, now-self._started),
                frame=None if self._frame is None else frame_info(self._frame, self._run_id, self._config["source_mode"]),
                frame_age_ms=age, complete_fps=round(self._fps, 2) if signal=="live" else 0,
                payload_mb_s=round(self._mbps, 3) if signal=="live" else 0, packets_s=round(self._pps, 1),
                saved_frames=self._saved_count, pending_saves=len(self._pending), error=self._error,
                manual_saves_enqueued=self._manual_enqueued, manual_saves_rejected=self._manual_rejected,
                metrics=metrics, history=list(self._history), events=list(self._events),
                hdmi=dict(available=False, source_frame_id=None, pairing_status="unverified"),
                controls=dict(uart_available=False, snapshot_request_available=False),
                hardware_acceptance="not_performed")

"""Opt-in host-side recovery; existing FPGA UART commands and video stay unchanged.

The server, not a browser tab, owns probing and restoration. One saved physical
board is addressed, and all serial operations use BoardLink's existing mutex.
"""
from copy import deepcopy
import hashlib
import json
from math import isfinite
from pathlib import Path
import secrets
import threading
import time

from .board_link import atomic_json
from .board_view import MarkerPending
from .geometry_control import GeometryError, GeometryProfile
from .web_session import SessionError


DEFAULTS = dict(enabled=False, preset_path="config/calibration/fpga-fisheye-rgb33-20261010.json",
                rotation_deg=0, enhance=True, mode="corrected", markers=False, diameter=10)


class RecoveryCancelled(SessionError):
    """A stop, settings edit or manual write revokes an in-flight auto operation."""


class GuardedUart:
    """Check restoration authority before each transaction, including each WORD."""
    def __init__(self, uart, check):
        self.uart, self.check = uart, check

    def exchange(self, command, payload=b""):
        self.check()
        return self.uart.exchange(command, payload)


class BoardAutoLoader:
    """Background cold/warm recovery with bounded retries and manual precedence."""
    def __init__(self, link, *, clock=time.monotonic):
        self.link, self.root, self.clock = link, Path(link.root), clock
        self.path = self.root / "config" / "board-autoload.json"
        self.lock, self.cycle_lock = threading.RLock(), threading.Lock()
        self.wake, self.closed = threading.Event(), threading.Event()
        self.thread = None
        self.settings, self.generation = dict(DEFAULTS), 0
        self.paused, self.manual_context, self.applied = False, None, None
        self.retry_at, self.failures = 0.0, 0
        self.connecting = False
        self.state = dict(phase="disabled", message="自动参数恢复未启用", busy=False,
                          active_version=None, displayed_version=None, source_frame_id=None,
                          pairing_status="unverified", hardware_image_verified=False)
        # Only transition/upload evidence is journaled, not every idle poll.
        self.report = self.root / "reports" / ("board-autoload-" + time.strftime(
            "%Y%m%d-%H%M%S", time.gmtime()) + "-" + secrets.token_hex(3) + ".jsonl")
        try:
            if self.path.exists():
                self.settings = self._normalize(json.loads(self.path.read_text(encoding="utf-8-sig")))
        except (OSError, ValueError, TypeError) as error:
            self.state.update(phase="error", message="自动恢复配置损坏，未启用：" + str(error))

    def _normalize(self, data):
        """Reject unknown controls, unsafe paths and non-finite settings before save."""
        if not isinstance(data, dict) or set(data) - set(DEFAULTS):
            raise SessionError("自动恢复仅接受 enabled/preset_path/rotation_deg/enhance/mode/markers/diameter")
        value = dict(DEFAULTS, **data)
        if any(type(value[k]) is not bool for k in ("enabled", "enhance", "markers")):
            raise SessionError("自动恢复开关必须为布尔值")
        rotation = value["rotation_deg"]
        if type(rotation) not in (int, float) or not isfinite(rotation) or abs(rotation) > 360:
            raise SessionError("自动恢复旋转角必须为 -360～360 的有限数")
        if value["mode"] not in ("original", "corrected") or type(value["diameter"]) is not int or not 4 <= value["diameter"] <= 32:
            raise SessionError("自动恢复显示模式/标记直径无效")
        self._preset_path(value["preset_path"])
        return value

    def _preset_path(self, name):
        """Confine parameter files, including symlinks, to host/config/calibration."""
        if not isinstance(name, str) or not name or len(name) > 256:
            raise SessionError("需要 host 内相对参数文件路径")
        relative = Path(name.replace("\\", "/"))
        base = (self.root / "config" / "calibration").resolve()
        path = (self.root / relative).resolve()
        if relative.is_absolute() or ".." in relative.parts or not base.is_relative_to(self.root.resolve()) or not path.is_relative_to(base) or path.suffix.lower() != ".json":
            raise SessionError("参数文件必须在 host/config/calibration 内，禁止绝对路径或越界")
        return path

    def _load_preset(self, settings):
        """Read one frozen file and encode the same byte-hashed input used in logs."""
        path = self._preset_path(settings["preset_path"])
        if path.stat().st_size > 65536:
            raise SessionError("自动恢复参数文件超过64 KiB")
        raw = path.read_bytes()
        if len(raw) > 65536:
            raise SessionError("自动恢复参数文件超过64 KiB")
        preset = json.loads(raw.decode("utf-8-sig"))
        profile = GeometryProfile.from_preset(preset, rotation_deg=settings["rotation_deg"], enhance=settings["enhance"])
        return preset, profile, hashlib.sha256(raw).hexdigest()

    def status(self):
        """Report independent recovery state; verified parameters are not image proof."""
        with self.lock:
            return dict(deepcopy(self.state), settings=dict(self.settings), paused=self.paused,
                        retries=self.failures, retry_in_seconds=max(0, round(self.retry_at-self.clock(), 1)))

    def configure(self, data):
        """Persist explicit operator consent, validating the preset before enabling."""
        value = self._normalize(data)
        if value["enabled"]:
            self._load_preset(value)
        with self.lock:
            atomic_json(self.path, value)
            self.settings = value
            self.generation += 1
            self.manual_context = self.applied = None
            self.paused = False
            self.failures, self.retry_at = 0, 0
            self.state.update(phase="waiting" if value["enabled"] else "disabled",
                              message="设置已保存；后台等待板卡并恢复参数" if value["enabled"] else "自动下发已关闭", active_version=None, displayed_version=None)
        self.wake.set()
        return self.status()

    def preset(self):
        """Return the confined stored file for explicit UI review, not board readback."""
        with self.lock:
            settings = dict(self.settings)
        preset, _, sha = self._load_preset(settings)
        return dict(preset=preset, preset_sha256=sha, settings=settings,
                    uploaded=False, hardware_image_verified=False)

    def pause(self, message="已停止；自动恢复暂停至手动重连或服务重启"):
        """Explicit stop must never be undone by the next supervisor iteration."""
        with self.lock:
            self.paused = True
            self.generation += 1
            self.state.update(phase="paused", message=message)
        self.wake.set()

    def resume(self):
        """A manual reconnect resumes detection but keeps this boot's manual edits."""
        with self.lock:
            self.paused = False
            self.generation += 1
            self.retry_at, self.failures = 0, 0
        self.wake.set()

    def manual_override(self):
        """Let manual parameter/view controls own this context until a new boot."""
        state = self.link.status()
        with self.lock:
            self.manual_context = (state.get("epoch"), state.get("session_id"))
            self.generation += 1
            self.state.update(phase="manual", message="本次板卡会话由手动控制；重启后再恢复预设")
        self.wake.set()

    def start(self):
        """Start exactly one daemon for the service, independently of HTTP pages."""
        with self.lock:
            if self.thread and self.thread.is_alive():
                return
            self.closed.clear()
            self.thread = threading.Thread(target=self._run, name="board-autoload", daemon=True)
            self.thread.start()

    def close(self):
        """Revoke writes first and join; a guarded UART aborts between transactions."""
        self.closed.set()
        self.wake.set()
        if self.thread and self.thread is not threading.current_thread():
            self.thread.join(timeout=5)
            if self.thread.is_alive():
                raise SessionError("自动恢复线程尚未释放 UART")

    def _run(self):
        """Use interruptible low-frequency probing and exponential retry backoff."""
        while not self.closed.is_set():
            self.tick()
            self.wake.wait(2)
            self.wake.clear()

    def _check(self, generation):
        with self.lock:
            if self.closed.is_set() or self.paused or self.generation != generation:
                raise RecoveryCancelled("自动恢复已被停止或新的手动操作取消")

    def _set(self, **values):
        with self.lock:
            self.state.update(values)

    def _log(self, event):
        """Retain real context/readback and uncertainty, without per-poll disk I/O."""
        event = dict(event, utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
                     source_frame_id=None, pairing_status="unverified", hardware_image_verified=False)
        try:
            self.report.parent.mkdir(parents=True, exist_ok=True)
            with self.report.open("a", encoding="utf-8") as stream:
                stream.write(json.dumps(event, ensure_ascii=False) + "\n")
        except OSError as error:
            self._set(log_error=str(error))

    @staticmethod
    def _matches(client, profile):
        """Compare all active words AND model/enhance with one parameter version."""
        version = client.status()["version"]
        if not version:
            return False, version
        for index, word in enumerate(profile.words):
            value, actual = client.read(index)
            if actual != version:
                raise GeometryError("自动恢复读取期间参数版本变化，未执行覆盖")
            if value != word & 0xffffffff:
                return False, version
        flags, actual = client.read(14)
        if actual != version:
            raise GeometryError("自动恢复模型读取期间参数版本变化")
        return (flags & 7) == (profile.model | int(profile.enhance) << 2), version

    def tick(self):
        """One deterministic recovery iteration; tests inject ports/UART and clock."""
        if not self.cycle_lock.acquire(blocking=False):
            return
        try:
            with self.lock:
                settings, generation = dict(self.settings), self.generation
                allowed = settings["enabled"] or self.link.profile.get("auto_start", False)
                if self.closed.is_set() or self.paused or not allowed or self.clock() < self.retry_at:
                    return
            if self.link.status().get("busy"):
                return
            # Commissioning runs in BoardLink's worker. Feed its failures back
            # into this daemon's backoff instead of creating workers every poll.
            if self.connecting:
                self.connecting = False
                connection = self.link.status()
                if connection["phase"] == "error":
                    raise SessionError(connection["message"])
            # A manual mock/custom acquisition must not be replaced by this daemon.
            receiver = self.link.session.status()
            if receiver.get("signal") == "live" and receiver.get("config", {}).get("source_mode") != "hardware_unverified":
                self._set(phase="waiting", message="非板卡采集正在运行，自动恢复不会替换它")
                return
            self._set(busy=True)
            self._check(generation)
            probe = self.link.probe_boot()
            context = (str(probe["epoch"]), probe["session_id"])
            state = self.link.status()
            if probe["cold"] or state.get("epoch") != context[0] or state.get("session_id") != context[1] or state["phase"] not in ("ready", "waiting"):
                with self.lock:
                    self._check(generation)
                    self.applied = None
                    self.manual_context = None
                    self._set(phase="connecting", message="已收到 FPGA 回复，建立冷/热启动会话…", active_version=None, displayed_version=None)
                    self.link.start()
                    self.connecting = True
                return
            if self.manual_context == context:
                self._set(phase="manual", message="本次会话保持手动参数/显示设置")
                return
            if not settings["enabled"]:
                self._set(phase="disabled", message="板卡自动连接已就绪；参数自动下发未启用")
                return
            # Published source frames, not an open USB device, allow activation.
            board = state.get("board") or {}
            if state["phase"] != "ready" and not (board.get("sensor_ready") and board.get("frame_published")):
                self._set(phase="waiting", message="FPGA 已回应，等待摄像头就绪和完整源帧")
                return
            if self.applied == (context, generation):
                return
            if probe["capabilities"] & 0x180 != 0x180:
                raise GeometryError("固件缺少几何0x80或显示0x100接口，未下发参数")
            preset, profile, sha = self._load_preset(settings)
            self._set(phase="loading", message="正在自动上传/回读参数并等待 HDMI 应用…")
            transcript = []
            try:
                with self.link.control_session(view=True) as client:
                    raw_uart = client.uart
                    client.uart = GuardedUart(raw_uart, lambda:self._check(generation))
                    if (str(client.epoch), client.session) != context:
                        raise GeometryError("探测与上传会话不一致，未下发参数")
                    same, version = self._matches(client, profile)
                    if not same:
                        result = client.upload(profile)
                        version = result["version"]
                    else:
                        result = dict(version=version, parameters_verified=True, uploaded=False)
                    self._set(active_version=version, displayed_version=None)
                    # fd3335ab header-only verification keeps unmarked HDMI
                    # independent from optional out-of-domain marker failures.
                    try:
                        view = client.view_status()
                    except MarkerPending:
                        view = None
                    if view is None or any(view[k] != settings[k] for k in ("mode", "markers", "diameter")):
                        view = client.configure(mode=settings["mode"], markers=settings["markers"], diameter=settings["diameter"])
                    elif settings["markers"]:
                        view = client.markers()
                    if view["displayed_param_version"] != version:
                        raise MarkerPending("活动参数已确认；HDMI 尚未显示同一参数版本")
                    with self.lock:
                        # Publish success atomically with the final authority check;
                        # a stop/manual action cannot be overwritten after this point.
                        self._check(generation)
                        self.applied = (context, generation)
                        self.failures, self.retry_at = 0, 0
                        self.state.update(phase="ready", message="自动参数与 HDMI 显示版本已回读确认；图像精度未验收",
                                          epoch=context[0], session_id=context[1], preset_sha256=sha,
                                          displayed_version=version, uploaded=not same, last_success_utc=time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()))
                    self._log(dict(event="restored", preset_path=settings["preset_path"], preset_sha256=sha,
                                   parameters=preset.get("parameters", preset), words=list(profile.words), settings=settings,
                                   epoch=context[0], session_id=context[1], uploaded=not same, parameter_readback=result, display=view,
                                   uart=getattr(raw_uart, "records", [])))
                    return
            finally:
                if "raw_uart" in locals():
                    transcript = getattr(raw_uart, "records", [])
        except RecoveryCancelled:
            # Pause/manual UI owns the newer state; a cancelled worker cannot overwrite it.
            pass
        except Exception as error:
            with self.lock:
                # An I/O error after cancellation belongs to the old operation,
                # not the new manual state. A lost probe invalidates cached proof
                # so a transient reconnect performs full readback without reupload.
                if self.closed.is_set() or self.paused or self.generation != generation:
                    return
                self.applied = None
                if "probe" not in locals():
                    self.state.update(active_version=None, displayed_version=None)
                self.failures += 1
                self.retry_at = self.clock() + min(30, 2 ** min(self.failures-1, 5))
                self.state.update(phase="error", message=str(error))
            self._log(dict(event="retry", error=str(error), uart=locals().get("transcript", [])))
        finally:
            self._set(busy=False)
            self.cycle_lock.release()

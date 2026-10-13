"""Loopback-only HTTP adapter and static UI. No public hosting or cloud relay."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import hmac
import json
import os
from pathlib import Path
import secrets
import socket
import threading
import time
from struct import Struct
from urllib.parse import parse_qs, quote, urlsplit

from .cli import HOST_ROOT
from .web_session import SessionError, WebSession
from .record_store import safe_child, sample_metadata, archives, runs, report_file
from .calibration import CalibrationStore
from .board_link import BoardLink
from .board_autoload import BoardAutoLoader
from .preview_delivery import PreviewDelivery

ASSETS = {"":("index.html","text/html; charset=utf-8"), "index.html":("index.html","text/html; charset=utf-8"),
    "app.css":("app.css","text/css; charset=utf-8"), "app.js":("app.js","text/javascript; charset=utf-8"),
    "pixels.js":("pixels.js","text/javascript; charset=utf-8"),
    "records.js":("records.js","text/javascript; charset=utf-8"),
    "video-input.js":("video-input.js","text/javascript; charset=utf-8"),
    "video-input-ui.js":("video-input-ui.js","text/javascript; charset=utf-8"),
    "board-link.js":("board-link.js","text/javascript; charset=utf-8"),
    "board-geometry.js":("board-geometry.js","text/javascript; charset=utf-8"),
    # File-backed automatic controls do not change the independent PC reference.
    "board-autoload.js":("board-autoload.js","text/javascript; charset=utf-8"),
    "preview-worker.js":("preview-worker.js","text/javascript; charset=utf-8"),
    # GPU display helper stays on the same protected origin as its worker.
    "preview-renderer.js":("preview-renderer.js","text/javascript; charset=utf-8"),
    # Independent actual presentation meters for browser-owned video previews.
    "preview-rate.js":("preview-rate.js","text/javascript; charset=utf-8"),
    "preview-stream.js":("preview-stream.js","text/javascript; charset=utf-8"),
    "preview-diagnostics.js":("preview-diagnostics.js","text/javascript; charset=utf-8"),
    # Purpose: serve the local calibration workbench from the same protected origin.
    "calibration":("calibration.html","text/html; charset=utf-8"),
    "calibration.html":("calibration.html","text/html; charset=utf-8"),
    "calibration.js":("calibration.js","text/javascript; charset=utf-8"),
    "calibration.css":("calibration.css","text/css; charset=utf-8"),
    # Purpose: share the local PC fish-eye reference between calibration and
    # the optional HDMI display, without sending video to a remap endpoint.
    "fisheye-preview.js":("fisheye-preview.js","text/javascript; charset=utf-8"),
    "fisheye-tuning.js":("fisheye-tuning.js","text/javascript; charset=utf-8"),
    "favicon.svg":("favicon.svg","image/svg+xml")}


def instance_identity():
    """Identify the application and checkout without exposing a path or token."""
    workspace = os.path.normcase(str(HOST_ROOT.resolve()))
    return dict(service="pango-video-web", launcher_api=1,
                workspace=hashlib.sha256(workspace.encode("utf-8")).hexdigest())


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True
    # Unix reuse handles TIME_WAIT, without SO_REUSEPORT or UDP sharing.
    # Windows needs exclusive binding instead: SO_REUSEADDR there allows a
    # second active host to steal requests and bypass instance-reuse detection.
    allow_reuse_address = True

    def __init__(self, port=8765, session=None):
        self.session = session or WebSession()
        # One coordinator owns commissioning and receiver restarts across tabs.
        self.board_link = BoardLink(self.session)
        # One opt-in background owner restores parameters without a live page.
        self.board_autoload = BoardAutoLoader(self.board_link)
        # Purpose: serialize CPU-heavy image analysis independently of live UDP reception.
        self.calibration = CalibrationStore(self.session.root)
        self.calibration_slot = threading.BoundedSemaphore(1)
        self.preview_delivery = PreviewDelivery()
        self.token = secrets.token_urlsafe(32)
        self._slots = threading.BoundedSemaphore(16)
        super().__init__(("127.0.0.1",port), Handler)

    def server_bind(self):
        """Keep one loopback owner per port on both Windows and Linux/Jetson."""
        if os.name == "nt":
            self.allow_reuse_address = False
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

    def serve_forever(self, poll_interval=0.5):
        """Start recovery only for a successfully bound, actually running service."""
        self.board_autoload.start()
        try:
            return super().serve_forever(poll_interval=poll_interval)
        finally:
            self.board_autoload.close()

    def server_close(self):
        """Revoke background serial work before releasing the HTTP listener."""
        self.board_autoload.close()
        super().server_close()

    def process_request(self, request, address):
        if not self._slots.acquire(blocking=False):
            request.close()
            return
        try:
            super().process_request(request,address)
        except BaseException:
            self._slots.release()
            raise

    def process_request_thread(self, request, address):
        try:
            super().process_request_thread(request,address)
        finally:
            self._slots.release()


class Handler(BaseHTTPRequestHandler):
    # A frame response sends short headers followed by a large RAW body.
    # Disable Nagle so delayed ACKs cannot add ~40 ms to each local preview.
    disable_nagle_algorithm = True
    server_version = "PangoLocal/0.2"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *args):
        pass

    def _preview_stream(self, query):
        """One loopback connection follows new complete frames, without copies
        of the original RAW or a growing queue when the display is slower.
        """
        mode = query.get("mode", ["raw"])[0]
        scale = int(query.get("downscale", ["2"])[0])
        limit = int(query.get("limit", ["0"])[0])
        if mode not in ("raw", "gray", "color") or scale not in (1,2):
            raise ValueError("invalid preview mode/scale")
        if limit not in (0,1,2):
            raise ValueError("preview credit must be 1 or 2 (0 is legacy streaming)")
        # HTTP/1.0 closes this lengthless binary body at stream end. Bound each
        # write with the existing socket timeout; a closed view releases its slot.
        self.send_response(200)
        self.send_header("Content-Type", "application/octet-stream")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.end_headers()
        prefix = Struct("<II")
        # Current browsers request at most two complete messages at a time.
        # Old clients retain the stream API, but cannot grant unbounded credits
        # through the new parameter. Never abandon a frame mid-message.
        after = query.get("after", [""])[0]
        sent = 0
        try:
            # A preview needs only the lifecycle bit; the full status snapshot
            # is reserved for UI polls and would otherwise hold the RX lock
            # while copying metrics/history at video frame rate.
            while self.server.session.preview_running() and (not limit or sent < limit):
                latest = self.server.session.latest(after, 0.5)
                if latest is None:
                    continue
                frame, info = latest
                if info["key"] == after:
                    continue
                pixels, info = self.server.preview_delivery.payload(frame, info, mode, scale)
                send_ms = time.monotonic_ns()/1_000_000
                info["host_timing"]["send_start_ms"] = send_ms
                metadata = json.dumps(info, ensure_ascii=True).encode()
                self.wfile.write(prefix.pack(len(metadata), len(pixels)) + metadata)
                self.wfile.write(pixels)
                self.server.preview_delivery.sent(send_ms)
                after = info["key"]
                sent += 1
        except (BrokenPipeError, ConnectionResetError, TimeoutError):
            pass  # Closing/hiding a browser view cancels only its preview.

    def _trusted(self, mutate=False):
        hosts = {f"127.0.0.1:{self.server.server_port}",f"localhost:{self.server.server_port}"}
        if self.headers.get("Host","").lower() not in hosts:
            return False
        origin = self.headers.get("Origin")
        if origin is not None and origin not in {f"http://{host}" for host in hosts}:
            return False
        if mutate and not hmac.compare_digest(self.headers.get("X-Pango-Token",""), self.server.token):
            return False
        return True

    def _send(self, code, body=b"", content_type="application/json; charset=utf-8", extra=None):
        self.send_response(code)
        self.send_header("Content-Type",content_type)
        self.send_header("Content-Length",str(len(body)))
        self.send_header("Cache-Control","no-store")
        self.send_header("X-Content-Type-Options","nosniff")
        self.send_header("X-Frame-Options","DENY")
        self.send_header("Cross-Origin-Resource-Policy","same-origin")
        self.send_header("Content-Security-Policy",
            "default-src 'self'; script-src 'self'; style-src 'self'; img-src 'self' data: blob:; "
            "connect-src 'self'; worker-src 'self'; media-src 'self' blob:; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        for key,value in (extra or {}).items():
            self.send_header(key,value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, data):
        self._send(code,json.dumps(data, ensure_ascii=False, allow_nan=False).encode("utf-8"))

    def do_GET(self):
        # Bracket a clock exchange in the same monotonic domain as CompleteFrame.
        # The client reports RTT uncertainty, not an optical end-to-end latency.
        request_ms = time.monotonic_ns() / 1_000_000
        if not self._trusted():
            return self._json(403,dict(error="请求来源不允许"))
        url = urlsplit(self.path)
        route = url.path
        query = parse_qs(url.query)
        try:
            if route.lstrip("/") in ASSETS and not route.startswith("//"):
                filename, kind = ASSETS[route.lstrip("/")]
                return self._send(200,(HOST_ROOT/"web"/filename).read_bytes(),kind)
            if route == "/api/health":
                return self._json(200, instance_identity())
            if route == "/api/clock":
                return self._json(200, dict(clock="host_monotonic_ms", received_ms=request_ms,
                                          sent_ms=time.monotonic_ns()/1_000_000))
            if route == "/api/preview-performance":
                return self._json(200, self.server.preview_delivery.status())
            if route == "/api/session":
                return self._json(200,dict(token=self.server.token,status=self.server.session.status()))
            if route == "/api/status":
                return self._json(200,self.server.session.status(summary=True)
                                  if query.get("summary") == ["1"] else self.server.session.status())
            if route == "/api/board/status":
                return self._json(200,self.server.board_link.status())
            # Recovery settings/state are local controls, not image evidence.
            if route == "/api/board/autoload":
                return self._json(200,self.server.board_autoload.status())
            if route == "/api/board/autoload/preset":
                return self._json(200,self.server.board_autoload.preset())
            # Live controls read the serialized board session, never a local cache.
            if route == "/api/board/geometry":
                return self._json(200,self.server.board_link.geometry())
            # Count FPGA results independently of repeated HDMI/UVC frames.
            if route == "/api/board/performance":
                return self._json(200,self.server.board_link.performance())
            # Mode verification is independent of optional marker coordinates.
            if route == "/api/board/view":
                return self._json(200,self.server.board_link.view_status())
            if route == "/api/board/markers":
                return self._json(200,self.server.board_link.markers())
            if route == "/api/board/devices":
                return self._json(200,self.server.board_link.devices())
            if route == "/api/calibration":
                return self._json(200,self.server.calibration.list())
            if route == "/api/preview-stream":
                return self._preview_stream(query)
            if route == "/api/calibration/artifact":
                path = self.server.calibration.artifact(
                    query.get("dataset",[""])[0], query.get("sample",[""])[0],
                    query.get("file",[""])[0], query.get("version",[None])[0])
                return self._send(200,path.read_bytes(),"application/octet-stream",
                    {"Content-Disposition":"attachment; filename*=UTF-8''"+quote(path.name)})
            if route in ("/api/frame", "/api/preview"):
                # One bounded long poll follows complete source frames. The
                # legacy zero-wait API stays compatible with archive/tests.
                wait_ms = min(500, max(0, int(query.get("wait", ["0"])[0])))
                latest = self.server.session.latest(query.get("after", [""])[0], wait_ms / 1000)
                if latest is None:
                    return self._send(204)
                frame, info = latest
                if query.get("after",[""])[0] == info["key"]:
                    return self._send(204)
                pixels = frame.data
                if route == "/api/preview":
                    # Transfer only the current display's derived pixels;
                    # /api/frame and archives always expose original RAW bytes.
                    pixels, info = self.server.preview_delivery.payload(frame, info, query.get("mode", ["raw"])[0],
                                                                       int(query.get("downscale", ["2"])[0]))
                return self._send(200,pixels,"application/octet-stream",
                    {"X-Frame-Info":json.dumps(info,ensure_ascii=True)})
            if route == "/api/records":
                return self._json(200,self.server.session.records())
            if route == "/api/artifact":
                path = report_file(self.server.session.root,query.get("key",[""])[0])
                return self._send(200,path.read_bytes(),"application/octet-stream",
                    {"Content-Disposition":"attachment; filename*=UTF-8''"+quote(path.name)})
            if route == "/api/archives":
                return self._json(200,dict(items=archives(self.server.session.root)))
            if route == "/api/runs":
                return self._json(200,dict(items=runs(self.server.session.root)))
            if route in ("/api/archive/pixels","/api/archive/metadata"):
                key = query.get("key",[""])[0]
                folder, meta = sample_metadata(self.server.session.root,key)
                if route.endswith("metadata"):
                    return self._send(200,(folder/"metadata.json").read_bytes(),
                        "application/json; charset=utf-8",{"Content-Disposition":'attachment; filename="metadata.json"'})
                data = (folder/meta["file"]).read_bytes()
                if hashlib.sha256(data).hexdigest() != meta.get("sha256"):
                    return self._json(409,dict(error="原始数据SHA-256与元数据不一致"))
                info = {k:meta.get(k) for k in ("width","height","row_stride","frame_bytes","pixel_format",
                    "bayer_code","source_mode","source_stage","frame_id","stream_epoch","sha256","measurement_ready")}
                info["key"], info["run_id"] = key, key.split("/")[0]
                return self._send(200,data,"application/octet-stream",
                    {"X-Frame-Info":json.dumps(info,ensure_ascii=True),
                     "Content-Disposition":f'attachment; filename="{meta["file"]}"'})
            if route == "/api/report":
                key = query.get("key",[""])[0]
                if key not in {item["key"] for item in runs(self.server.session.root)}:
                    return self._json(404,dict(error="找不到运行报告"))
                path = safe_child(self.server.session.root/"reports",key)
                return self._send(200,path.read_bytes(),"application/json; charset=utf-8",
                    {"Content-Disposition":'attachment; filename="receiver-report.json"'})
            return self._json(404,dict(error="接口不存在"))
        except (OSError,ValueError,KeyError,TypeError) as error:
            return self._json(400,dict(error=str(error)))

    def do_POST(self):
        if not self._trusted(mutate=True):
            return self._json(403,dict(error="请求来源或会话凭据不允许"))
        try:
            if self.headers.get("Content-Type","").split(";")[0] != "application/json":
                return self._json(415,dict(error="需要JSON请求"))
            if self.headers.get("Transfer-Encoding"):
                return self._json(400,dict(error="不支持分块请求体"))
            route = urlsplit(self.path).path
            # Purpose: large calibration uploads have a separate bounded request path.
            if route.startswith("/api/calibration/"):
                return self._calibration_post(route)
            size = int(self.headers.get("Content-Length","0"))
            maximum = 1024*1024 if route == "/api/records/delete" else 16384
            if not 0 < size <= maximum:
                return self._json(413,dict(error="请求体长度不允许"))
            data = json.loads(self.rfile.read(size))
            if not isinstance(data,dict):
                raise SessionError("请求必须是JSON对象")
            route = urlsplit(self.path).path
            session = self.server.session
            # Board startup is asynchronous, keeping frame/status HTTP responsive.
            if route == "/api/board/start":
                self.server.board_autoload.resume()
                return self._json(202,self.server.board_link.start(data or None))
            # Explicit opt-in validates the stored preset before any board write.
            if route == "/api/board/autoload":
                return self._json(200,self.server.board_autoload.configure(data))
            # Token-protected board changes preserve the running video chain.
            if route == "/api/board/geometry":
                self.server.board_autoload.manual_override()
                return self._json(200,self.server.board_link.geometry(data))
            if route == "/api/board/view":
                self.server.board_autoload.manual_override()
                return self._json(200,self.server.board_link.view(data))
            # This token-protected action restores Ethernet defaults only.
            # Device/epoch validation happens before restarting the owned UDP.
            if route == "/api/board/reset-ethernet":
                if data:
                    raise SessionError("以太网恢复默认请求不需要参数")
                self.server.board_autoload.resume()
                return self._json(202,self.server.board_link.reset_ethernet())
            if route == "/api/board/stop":
                if data:
                    raise SessionError("停止请求不需要参数")
                self.server.board_autoload.pause()
                return self._json(200,self.server.board_link.stop())
            if route in ("/api/start", "/api/config") and self.server.board_link.status()["busy"]:
                raise SessionError("板卡启动中，请等待完成或先停止链路")
            if route == "/api/records/delete":
                if set(data) != {"targets"}:
                    raise SessionError("删除请求仅接受targets字段")
                return self._json(200,session.delete_records(data["targets"]))
            if route == "/api/start":
                if set(data)-{"config","archive_every","auto_mock"}:
                    raise SessionError("存在未定义启动字段")
                # Explicit alternate/mock capture must not be auto-replaced.
                self.server.board_autoload.pause("手动采集已暂停自动板卡恢复")
                return self._json(200,session.start(**data))
            if route == "/api/stop":
                if data:
                    raise SessionError("停止请求不需要参数")
                self.server.board_autoload.pause()
                self.server.board_link.stop()
                return self._json(200,session.status())
            if route == "/api/save":
                if data:
                    raise SessionError("保存请求不需要参数")
                return self._json(202,session.save_current())
            if route == "/api/config":
                return self._json(200,session.configure(data))
            return self._json(404,dict(error="接口不存在"))
        except SessionError as error:
            return self._json(409,dict(error=str(error)))
        except (ValueError,TypeError,OSError) as error:
            return self._json(400,dict(error=str(error)))

    def do_OPTIONS(self):
        self._json(403,dict(error="跨源访问未启用"))

    def _calibration_post(self, route):
        """Validate token in do_POST; bound uploads and preserve live receiver capacity."""
        if not self.server.calibration_slot.acquire(blocking=False):
            return self._json(409,dict(error="标定任务正在处理，请稍后重试"))
        try:
            size = int(self.headers.get("Content-Length","0"))
            limit = 44*1024*1024 if route == "/api/calibration/image" else 16384
            if not 0 < size <= limit:
                return self._json(413,dict(error="标定请求长度不允许"))
            data = json.loads(self.rfile.read(size))
            if not isinstance(data,dict):
                raise ValueError("请求必须是JSON对象")
            store = self.server.calibration
            if route == "/api/calibration/create":
                result = store.create(data.get("config"))
            elif route == "/api/calibration/image":
                result = store.add(data.get("dataset"),data)
            elif route == "/api/calibration/select":
                result = store.select(data.get("dataset"),data.get("sample"),data.get("enabled"),data.get("reason"))
            elif route == "/api/calibration/solve":
                result = store.solve(data.get("dataset"))
            else:
                return self._json(404,dict(error="标定接口不存在"))
            return self._json(200,result)
        except (ValueError,TypeError,OSError,KeyError) as error:
            return self._json(400,dict(error=str(error)))
        finally:
            self.server.calibration_slot.release()

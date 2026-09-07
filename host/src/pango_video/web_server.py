"""Loopback-only HTTP adapter and static UI. No public hosting or cloud relay."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import threading
from urllib.parse import parse_qs, urlsplit

from .cli import HOST_ROOT
from .web_session import SessionError, WebSession

ASSETS = {"":("index.html","text/html; charset=utf-8"), "index.html":("index.html","text/html; charset=utf-8"),
    "app.css":("app.css","text/css; charset=utf-8"), "app.js":("app.js","text/javascript; charset=utf-8"),
    "pixels.js":("pixels.js","text/javascript; charset=utf-8"),
    "preview-worker.js":("preview-worker.js","text/javascript; charset=utf-8"),
    "favicon.svg":("favicon.svg","image/svg+xml")}


def safe_child(root, relative):
    if not isinstance(relative, str) or not relative or len(relative)>400:
        raise ValueError("invalid artifact key")
    if any(part in ("", ".", "..") for part in relative.replace("\\","/").split("/")):
        raise ValueError("invalid artifact path")
    path = (root/relative).resolve()
    if not path.is_relative_to(root.resolve()):
        raise ValueError("artifact is outside the data directory")
    return path


def sample_metadata(root, key):
    folder = safe_child(root/"data", key)
    path = safe_child(folder,"metadata.json")
    if path.stat().st_size > 1_000_000:
        raise ValueError("metadata too large")
    meta = json.loads(path.read_text(encoding="utf-8"))
    if meta.get("file") not in ("image.raw","image.rgb") or meta.get("transport_complete") is not True:
        raise ValueError("sample is not a committed raw image")
    if meta.get("pixel_format") not in ("RAW8","RGB888"):
        raise ValueError("unsupported archived format")
    if meta["pixel_format"]=="RAW8" and meta.get("bayer_code") not in (1,2,3,4):
        raise ValueError("invalid Bayer layout")
    for name in ("width","height","row_stride","frame_bytes"):
        if type(meta.get(name)) is not int or meta[name] <= 0:
            raise ValueError("invalid archived image dimensions")
    bpp = 1 if meta["pixel_format"]=="RAW8" else 3
    if meta["row_stride"] != meta["width"]*bpp or meta["frame_bytes"] != meta["row_stride"]*meta["height"]:
        raise ValueError("invalid archived stride")
    pixels = safe_child(folder, meta["file"])
    if not 0 < pixels.stat().st_size == meta["frame_bytes"] <= 8*1024*1024:
        raise ValueError("archived length mismatch")
    meta["frame_id"] = str(meta["frame_id"])
    meta["stream_epoch"] = str(meta["stream_epoch"])
    return folder, meta


def archives(root, limit=100):
    data = root/"data"
    if not data.exists():
        return []
    # Only metadata commit markers are indexed; .part files never become records.
    candidates = sorted(data.glob("*/*/metadata.json"), key=lambda p:p.stat().st_mtime, reverse=True)
    records = []
    for p in candidates:
        key = p.parent.relative_to(data).as_posix()
        try:
            _, meta = sample_metadata(root,key)
            records.append(dict(key=key, run_id=key.split("/")[0], frame_id=meta["frame_id"],
                source_mode=meta.get("source_mode","unknown"), saved_utc=meta.get("saved_utc"),
                width=meta["width"], height=meta["height"], frame_bytes=meta["frame_bytes"],
                pixel_format=meta["pixel_format"], sha256=meta.get("sha256",""),
                tap="S0" if meta["pixel_format"]=="RAW8" else (meta.get("descriptor") or {}).get("tap","RGB")))
        except (OSError,ValueError,KeyError,TypeError):
            continue
        if len(records)>=limit:
            break
    return records


def runs(root, limit=30):
    folder = root/"reports"
    candidates = list(folder.glob("*/web-session.json"))+list(folder.glob("*/receiver.json"))
    records = []
    for path in sorted(candidates, key=lambda p:p.stat().st_mtime, reverse=True)[:limit]:
        try:
            safe_child(folder,path.relative_to(folder).as_posix())
            if path.stat().st_size>2_000_000:
                continue
            r = json.loads(path.read_text(encoding="utf-8"))
            m = r.get("metrics", r.get("receiver",{}))
            counts = m.get("assembly",{}).get("counters",{})
            records.append(dict(key=path.relative_to(folder).as_posix(), run_id=r["run_id"],
                mode=r.get("config",r.get("configuration",{})).get("source_mode",r.get("source_mode","unknown")),
                frames=counts.get("live_frames_complete",0), saved=r.get("saved_frames",r.get("storage",{}).get("frames_saved",0)),
                errors=sum(v for k,v in counts.items() if k.startswith(("frames_failed_","packets_rejected_"))),
                seconds=r.get("elapsed_seconds",r.get("elapsed_receive_seconds",0))))
        except (OSError,ValueError,KeyError,TypeError):
            continue
    return records


class LocalServer(ThreadingHTTPServer):
    daemon_threads = True
    allow_reuse_address = False

    def __init__(self, port=8765, session=None):
        self.session = session or WebSession()
        self.token = secrets.token_urlsafe(32)
        self._slots = threading.BoundedSemaphore(16)
        super().__init__(("127.0.0.1",port), Handler)

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
    server_version = "PangoLocal/0.2"
    sys_version = ""

    def setup(self):
        super().setup()
        self.connection.settimeout(10)

    def log_message(self, *args):
        pass

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
            "connect-src 'self'; worker-src 'self'; object-src 'none'; frame-ancestors 'none'; base-uri 'none'")
        for key,value in (extra or {}).items():
            self.send_header(key,value)
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(body)

    def _json(self, code, data):
        self._send(code,json.dumps(data, ensure_ascii=False, allow_nan=False).encode("utf-8"))

    def do_GET(self):
        if not self._trusted():
            return self._json(403,dict(error="请求来源不允许"))
        url = urlsplit(self.path)
        route = url.path
        query = parse_qs(url.query)
        try:
            if route.lstrip("/") in ASSETS and not route.startswith("//"):
                filename, kind = ASSETS[route.lstrip("/")]
                return self._send(200,(HOST_ROOT/"web"/filename).read_bytes(),kind)
            if route == "/api/session":
                return self._json(200,dict(token=self.server.token,status=self.server.session.status()))
            if route == "/api/status":
                return self._json(200,self.server.session.status())
            if route == "/api/frame":
                latest = self.server.session.latest()
                if latest is None:
                    return self._send(204)
                frame, info = latest
                if query.get("after",[""])[0] == info["key"]:
                    return self._send(204)
                return self._send(200,frame.data,"application/octet-stream",
                    {"X-Frame-Info":json.dumps(info,ensure_ascii=True)})
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
                    "bayer_code","source_mode","frame_id","stream_epoch","sha256","measurement_ready")}
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
            size = int(self.headers.get("Content-Length","0"))
            if not 0 < size <= 16384:
                return self._json(413,dict(error="请求体长度不允许"))
            data = json.loads(self.rfile.read(size))
            if not isinstance(data,dict):
                raise SessionError("请求必须是JSON对象")
            route = urlsplit(self.path).path
            session = self.server.session
            if route == "/api/start":
                if set(data)-{"config","archive_every","auto_mock"}:
                    raise SessionError("存在未定义启动字段")
                return self._json(200,session.start(**data))
            if route == "/api/stop":
                if data:
                    raise SessionError("停止请求不需要参数")
                return self._json(200,session.stop())
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

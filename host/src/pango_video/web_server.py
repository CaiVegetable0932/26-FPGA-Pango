"""Loopback-only HTTP adapter and static UI. No public hosting or cloud relay."""
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import hashlib
import hmac
import json
from pathlib import Path
import secrets
import threading
from urllib.parse import parse_qs, quote, urlsplit

from .cli import HOST_ROOT
from .web_session import SessionError, WebSession
from .record_store import safe_child, sample_metadata, archives, runs, report_file

ASSETS = {"":("index.html","text/html; charset=utf-8"), "index.html":("index.html","text/html; charset=utf-8"),
    "app.css":("app.css","text/css; charset=utf-8"), "app.js":("app.js","text/javascript; charset=utf-8"),
    "pixels.js":("pixels.js","text/javascript; charset=utf-8"),
    "records.js":("records.js","text/javascript; charset=utf-8"),
    "preview-worker.js":("preview-worker.js","text/javascript; charset=utf-8"),
    "favicon.svg":("favicon.svg","image/svg+xml")}


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
            route = urlsplit(self.path).path
            size = int(self.headers.get("Content-Length","0"))
            maximum = 1024*1024 if route == "/api/records/delete" else 16384
            if not 0 < size <= maximum:
                return self._json(413,dict(error="请求体长度不允许"))
            data = json.loads(self.rfile.read(size))
            if not isinstance(data,dict):
                raise SessionError("请求必须是JSON对象")
            route = urlsplit(self.path).path
            session = self.server.session
            if route == "/api/records/delete":
                if set(data) != {"targets"}:
                    raise SessionError("删除请求仅接受targets字段")
                return self._json(200,session.delete_records(data["targets"]))
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

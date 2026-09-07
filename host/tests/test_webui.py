"""Web integration tests use real loopback UDP/HTTP and isolated host/build evidence."""
import hashlib
import http.client
import json
from pathlib import Path
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from pango_video.cli import HOST_ROOT
from pango_video.protocol import FormatLimits, packetize
from pango_video.reassembly import FrameAssembler
from pango_video.receiver import UDPReceiver
from pango_video.web_server import LocalServer, archives, sample_metadata
from pango_video.web_session import SessionError, WebSession


def until(predicate, seconds=4):
    deadline = time.monotonic()+seconds
    while time.monotonic()<deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.01)
    raise AssertionError("condition did not become true")


class WebTests(unittest.TestCase):
    def setUp(self):
        build = (HOST_ROOT/"build").resolve()
        build.mkdir(exist_ok=True)
        self.temp = tempfile.TemporaryDirectory(prefix="web-test-", dir=build)
        self.root = Path(self.temp.name).resolve()
        self.assertTrue(self.root.is_relative_to(build))
        (self.root/"config").mkdir()
        self.sender = socket.socket(socket.AF_INET,socket.SOCK_DGRAM)
        self.sender.bind(("127.0.0.1",0))
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as reserve:
            reserve.bind(("127.0.0.1",0))
            port = reserve.getsockname()[1]
        self.config = dict(device_id="MOCK-TEST",source_mode="mock",bind_ip="127.0.0.1",
            port=port,peer_ip="127.0.0.1",peer_port=self.sender.getsockname()[1],
            stream_epoch=2**64-1,width=16,height=8,bayer_code=1,receive_buffer_bytes=8388608)
        (self.root/"config/receiver.mock.json").write_text(json.dumps(self.config),encoding="utf-8")
        self.session = WebSession(self.root)
        self.server = LocalServer(0,self.session)
        self.thread = threading.Thread(target=self.server.serve_forever, kwargs={"poll_interval":0.02},daemon=True)
        self.thread.start()
        self.token = self.call("GET","/api/session")[2]["token"]

    def tearDown(self):
        self.session.stop()
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(2)
        self.sender.close()
        # Verify the actual recursive cleanup target stays in the implementation area.
        self.assertTrue(self.root.resolve().is_relative_to((HOST_ROOT/"build").resolve()))
        self.temp.cleanup()

    def call(self, method, path, data=None, headers=None, raw=False):
        connection = http.client.HTTPConnection("127.0.0.1",self.server.server_port,timeout=5)
        body = None if data is None else json.dumps(data).encode()
        request_headers = {"Content-Type":"application/json"}
        if hasattr(self,"token"):
            request_headers["X-Pango-Token"] = self.token
        request_headers.update(headers or {})
        connection.request(method,path,body=body,headers=request_headers)
        response = connection.getresponse()
        result = response.read()
        status, hdrs = response.status, dict(response.getheaders())
        connection.close()
        return status, hdrs, result if raw or not result else json.loads(result)

    def start(self, **kwargs):
        code, _, state = self.call("POST","/api/start",dict(auto_mock=False,**kwargs))
        self.assertEqual(code,200,state)
        return state

    def send(self, frame_id=2**63+7, count=1, corrupt=False):
        data = bytes(range(128))
        for offset in range(count):
            for packet in packetize(data,stream_epoch=self.config["stream_epoch"],
                    frame_id=frame_id+offset,width=16,height=8,bayer_code=1):
                if corrupt:
                    packet = packet[:-1]+bytes([packet[-1]^1])
                self.sender.sendto(packet,("127.0.0.1",self.config["port"]))
            time.sleep(0.01)
        return data

    def test_http_udp_save_stop_report_and_u64(self):
        state = self.start()
        self.assertEqual(state["config"]["stream_epoch"],str(2**64-1))
        data = self.send()
        until(self.session.latest)
        status, headers, binary = self.call("GET","/api/frame",raw=True)
        self.assertEqual((status,binary),(200,data))
        info = json.loads(headers["X-Frame-Info"])
        self.assertEqual(info["frame_id"],str(2**63+7))
        self.assertFalse(info["measurement_ready"])
        self.assertEqual(self.call("GET","/api/frame?after="+info["key"])[0],204)
        saved = self.call("POST","/api/save",{})
        self.assertEqual(saved[0],202)
        until(lambda:self.session.status()["saved_frames"]==1)
        self.assertEqual(self.call("POST","/api/save",{})[2]["status"],"already_saved_or_queued")
        item = self.call("GET","/api/archives")[2]["items"][0]
        code, _, downloaded = self.call("GET","/api/archive/pixels?key="+item["key"],raw=True)
        self.assertEqual((code,downloaded),(200,data))
        meta = self.call("GET","/api/archive/metadata?key="+item["key"])[2]
        self.assertEqual(meta["sha256"],hashlib.sha256(data).hexdigest())
        self.assertEqual(meta["frame_id"],2**63+7)  # Original evidence keeps native JSON integers.
        self.assertEqual(meta["source_mode"],"mock")
        self.assertIsNone(meta["hdmi_source_frame_id"])
        self.assertFalse(meta["measurement_ready"])
        stopped = self.call("POST","/api/stop",{})[2]
        self.assertEqual(stopped["state"],"stopped")
        self.assertEqual(stopped["metrics"]["assembly"]["live_highwater"],str(2**63+7))
        self.assertEqual(self.call("GET","/api/frame")[0],204)
        report = self.call("GET","/api/runs")[2]["items"][0]
        self.assertEqual((report["frames"],report["saved"]),(1,1))
        downloaded = self.call("GET","/api/report?key="+report["key"])[2]
        self.assertEqual(downloaded["hardware_acceptance"],"not_performed")
        self.assertEqual(downloaded["hdmi"]["pairing_status"],"unverified")

    def test_state_machine_config_lock_and_restart_identity(self):
        first = self.start()
        self.assertEqual(self.call("POST","/api/start",{})[0],409)
        self.assertEqual(self.call("POST","/api/config",self.config)[0],409)
        self.send()
        until(self.session.latest)
        self.session.stop()
        second = self.start()
        self.assertNotEqual(first["run_id"],second["run_id"])
        self.assertIsNone(self.session.latest())
        self.assertIsNone(second["frame"])
        self.assertEqual(second["signal"],"waiting")
        self.assertEqual(self.call("POST","/api/save",{})[0],409)
        self.send(frame_id=0)
        until(self.session.latest)
        self.assertEqual(self.session.latest()[1]["frame_id"],"0")
        self.session.stop()
        self.assertEqual(self.session.stop()["state"],"stopped")

    def test_stale_image_never_presented_as_live_or_saved(self):
        self.start()
        self.send()
        until(self.session.latest)
        until(lambda:self.session.latest() is None, seconds=2)
        self.assertEqual(self.session.status()["signal"],"waiting")
        self.assertEqual(self.call("POST","/api/save",{})[0],409)

    def test_crc_and_foreign_source_are_reflected_in_api(self):
        self.start()
        self.send(corrupt=True)
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as foreign:
            foreign.sendto(b"foreign",("127.0.0.1",self.config["port"]))
        self.send()
        until(lambda:self.session.status()["metrics"].get("counters",{}).get("datagrams_wrong_peer")==1)
        state = self.session.status()
        self.assertEqual(state["metrics"]["assembly"]["counters"]["packets_rejected_crc"],1)
        self.assertEqual(state["metrics"]["assembly"]["counters"]["live_frames_complete"],1)

    def test_in_memory_config_validation_and_full_epoch(self):
        data = dict(self.config,stream_epoch=str(2**64-1))
        self.assertEqual(self.call("POST","/api/config",data)[2]["stream_epoch"],str(2**64-1))
        for key,value in [("stream_epoch",str(2**64)),("stream_epoch","1.5"),("port",0),
                ("port",True),("width",3),("height",0),("peer_ip","192.0.2.1"),
                ("receive_buffer_bytes",1),("device_id","")]:
            with self.subTest(key=key,value=value):
                self.assertEqual(self.call("POST","/api/config",dict(data,**{key:value}))[0],409)
        self.assertEqual(self.session.status()["config"]["stream_epoch"],str(2**64-1))

    def test_http_origin_token_paths_and_body_limits(self):
        self.assertEqual(self.call("GET","/api/status",headers={"Host":"evil.example"})[0],403)
        self.assertEqual(self.call("GET","/api/session",headers={"Origin":"https://evil.example"})[0],403)
        self.assertEqual(self.call("POST","/api/start",{},headers={"X-Pango-Token":"bad"})[0],403)
        self.assertEqual(self.call("OPTIONS","/api/start")[0],403)
        self.assertEqual(self.call("GET","/api/archive/pixels?key=../../config")[0],400)
        self.assertEqual(self.call("GET","/config/receiver.mock.json")[0],404)
        self.assertEqual(self.call("POST","/api/start",{"unknown":1})[0],409)
        self.assertEqual(self.call("POST","/api/start",{},headers={"Content-Type":"text/plain"})[0],415)
        self.assertEqual(self.call("POST","/api/start",{"x":"a"*17000})[0],413)
        self.assertEqual(self.call("POST","/api/start",[])[0],409)
        code, headers, html = self.call("GET","/",raw=True)
        self.assertEqual(code,200)
        self.assertIn("default-src 'self'",headers["Content-Security-Policy"])
        self.assertNotIn("Access-Control-Allow-Origin",headers)
        self.assertIn(b"/app.js",html)
        for asset in ("app.css","app.js","pixels.js","preview-worker.js","favicon.svg"):
            self.assertEqual(self.call("GET","/"+asset,raw=True)[0],200)

    def test_bind_failure_leaves_session_retryable(self):
        self.session.configure(dict(self.config,port=self.config["peer_port"]+1 if self.config["peer_port"]<65535 else 50000))
        with socket.socket(socket.AF_INET,socket.SOCK_DGRAM) as blocker:
            blocker.bind(("127.0.0.1",0))
            data = dict(self.config,port=blocker.getsockname()[1])
            self.assertEqual(self.call("POST","/api/start",{"config":data,"auto_mock":False})[0],409)
            self.assertEqual(self.session.status()["state"],"idle")
        self.start()

    def test_auto_archive_and_hash_tamper_rejection(self):
        self.start(archive_every=1)
        self.send(count=3)
        until(lambda:self.session.status()["saved_frames"]==3)
        items = archives(self.root)
        self.assertEqual(len(items),3)
        path = self.root/"data"/items[0]["key"]/"image.raw"
        path.write_bytes(bytes(128))
        self.assertEqual(self.call("GET","/api/archive/pixels?key="+items[0]["key"])[0],409)

    def test_archive_failure_stops_without_committed_evidence(self):
        with patch("pango_video.web_session.save_frame",side_effect=OSError("injected disk failure")):
            self.start(archive_every=1)
            self.send()
            until(lambda:self.session.status()["state"]=="error")
            self.assertIn("injected disk failure",self.session.status()["error"])
            self.assertEqual(archives(self.root),[])

    def test_manual_archive_backpressure_is_reported(self):
        self.start()
        self.send()
        until(self.session.latest)
        with patch.object(self.session._receiver.archive_frames,"offer",return_value=(False,0)):
            self.assertEqual(self.call("POST","/api/save",{})[0],409)
        state = self.session.status()
        self.assertEqual(state["manual_saves_rejected"],1)
        self.assertEqual(state["pending_saves"],0)
        self.assertEqual(self.call("POST","/api/save",{})[0],202)
        until(lambda:self.session.status()["saved_frames"]==1)

    def test_mock_sender_bind_failure_becomes_visible(self):
        # Fixture keeps the requested sender endpoint occupied.
        self.assertEqual(self.call("POST","/api/start",{})[0],200)
        until(lambda:self.session.status()["state"]=="error")
        self.assertIn("模拟发送器退出",self.session.status()["error"])
        self.assertIsNotNone(self.session._mock.poll())

    def test_owned_mock_subprocess_start_and_stop(self):
        # The sender port must be free for the child process.
        self.sender.close()
        result = self.call("POST","/api/start",{})
        self.assertEqual(result[0],200,result)
        until(self.session.latest,seconds=5)
        child = self.session._mock
        self.assertIsNone(child.poll())
        self.session.stop()
        self.assertIsNotNone(child.poll())

    def test_owner_thread_callback_runs_while_udp_idle(self):
        assembler = FrameAssembler(device_id="MOCK",stream_epoch=1,format_limits=FormatLimits(16,8))
        rx = UDPReceiver(assembler,bind=("127.0.0.1",0),peer=("127.0.0.1",self.config["peer_port"]))
        rx.open()
        calls = []
        owner = threading.get_ident()
        try:
            rx.run(threading.Event(),duration=0.12,status_interval=0.02,
                on_status=lambda value:calls.append((threading.get_ident(),value)))
        finally:
            rx.close()
        self.assertGreaterEqual(len(calls),3)
        self.assertTrue(all(tid==owner for tid,_ in calls))
        self.assertTrue(all(not value["counters"] for _,value in calls))


if __name__=="__main__":
    unittest.main()

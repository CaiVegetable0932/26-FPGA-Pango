"""Web integration tests use real loopback UDP/HTTP and isolated host/build evidence."""
import hashlib
import http.client
import json
from pathlib import Path
from types import SimpleNamespace
import socket
import tempfile
import threading
import time
import unittest
from unittest.mock import patch

from pango_video.cli import HOST_ROOT
from pango_video.protocol import FormatLimits, packetize, frame_header, ENHANCED_RAW8_DESCRIPTOR
from pango_video.reassembly import FrameAssembler
from pango_video.receiver import UDPReceiver
from pango_video.web_server import LocalServer, archives, sample_metadata
from pango_video.web_session import SessionError, WebSession, frame_info


def until(predicate, seconds=4):
    deadline = time.monotonic()+seconds
    while time.monotonic()<deadline:
        result = predicate()
        if result:
            return result
        time.sleep(0.01)
    raise AssertionError("condition did not become true")


class WebTests(unittest.TestCase):
    def test_enhanced_frame_stage_is_propagated_without_host_pixel_processing(self):
        # Purpose: the live API must identify board-processed bytes so the
        # browser can decode RAW8 directly without presenting them as S0.
        header = frame_header(stream_epoch=1, frame_id=7, width=16, height=8,
                              bayer_code=4, descriptor_id=ENHANCED_RAW8_DESCRIPTOR,
                              param_version=2)
        info = frame_info(SimpleNamespace(header=header), "run", "hardware_unverified")
        self.assertEqual(info["source_stage"], "fpga_enhanced_raw8")
        self.assertEqual(info["pixel_format"], "RAW8")
        self.assertEqual(info["frame_bytes"], 128)

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

    def test_board_routes_require_token_and_expose_inventory_errors(self):
        """Device failures remain actionable through HTTP without opening hardware."""
        self.server.board_link.inventory = lambda:[]
        self.server.board_link.ports = lambda:[]
        code, _, body = self.call("GET", "/api/board/devices")
        self.assertEqual(code, 200)
        self.assertEqual(body, dict(interfaces=[], ports=[], errors=[]))
        self.assertEqual(self.call("GET", "/api/board/status")[2]["phase"], "idle")
        self.assertEqual(self.call("POST", "/api/board/start", {}, headers={"X-Pango-Token":""})[0], 403)
        self.assertEqual(self.call("POST", "/api/board/start", {})[0], 409)
        self.assertEqual(self.call("POST", "/api/board/stop", {})[2]["phase"], "stopped")

    def test_ethernet_reset_route_requires_token_and_no_parameters(self):
        """The independent reset cannot accept ad-hoc endpoint overrides."""
        with patch.object(self.server.board_link, "reset_ethernet", return_value=dict(phase="checking", busy=True)) as reset:
            self.assertEqual(self.call("POST", "/api/board/reset-ethernet", {}, headers={"X-Pango-Token":""})[0], 403)
            self.assertEqual(self.call("POST", "/api/board/reset-ethernet", {"source_ip":"10.0.0.3"})[0], 409)
            reset.assert_not_called()
            code, _, result = self.call("POST", "/api/board/reset-ethernet", {})
            self.assertEqual(code, 202)
            self.assertTrue(result["busy"])
            reset.assert_called_once_with()

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

    def test_browser_video_input_assets_and_identity_boundary(self):
        for name in ("video-input.js", "video-input-ui.js"):
            code, headers, source = self.call("GET", "/"+name, raw=True)
            self.assertEqual(code, 200)
            self.assertIn("text/javascript", headers["Content-Type"])
            self.assertIn(b"create", source)
            self.assertIn("media-src 'self' blob:", headers["Content-Security-Policy"])
        code, _, page = self.call("GET", "/", raw=True)
        self.assertEqual(code, 200)
        self.assertIn(b'id="capture-device"', page)
        self.assertIn(b'id="capture-video"', page)
        state = self.call("GET", "/api/status")[2]
        self.assertEqual(state["state"], "idle")
        self.assertFalse(state["hdmi"]["available"])
        self.assertEqual(state["hdmi"]["available_scope"], "python_raw_capture")
        self.assertEqual(state["hdmi"]["preview_backend"], "browser_media_devices")
        self.assertEqual(state["hdmi"]["preview_state"], "not_reported")
        self.assertIsNone(state["hdmi"]["source_frame_id"])
        self.assertEqual(state["hdmi"]["pairing_status"], "unverified")

    def test_compact_display_preserves_full_raw_and_source_identity(self):
        """Derived HTTP pixels cannot replace native RAW evidence or geometry."""
        self.start();data = self.send();until(self.session.latest)
        code, headers, display = self.call("GET", "/api/preview?mode=raw&downscale=2", raw=True)
        self.assertEqual(code, 200)
        info = json.loads(headers["X-Frame-Info"])
        self.assertEqual((info["width"], info["height"], info["pixel_format"]), (16,8,"RAW8"))
        self.assertEqual((info["preview_width"],info["preview_height"],info["preview_pixel_format"]), (8,4,"GRAY8"))
        expected = bytes((data[y*16+x]+data[y*16+x+1]+data[(y+1)*16+x]+data[(y+1)*16+x+1])//4
                         for y in range(0,8,2) for x in range(0,16,2))
        self.assertEqual(display, expected)
        self.assertEqual(self.call("GET", "/api/frame", raw=True)[2], data)
        self.assertEqual(self.call("GET", "/api/preview?downscale=1", raw=True)[2], data)
        self.call("POST", "/api/save", {})
        until(lambda:self.session.status()["saved_frames"]==1)
        item = self.call("GET", "/api/archives")[2]["items"][0]
        self.assertEqual(self.call("GET", "/api/archive/pixels?key="+item["key"], raw=True)[2], data)
        self.assertEqual(self.call("GET", "/api/preview?mode=invalid")[0], 400)

    def test_preview_long_poll_wakes_for_new_complete_frame(self):
        """Wait for completion rather than a timer; incomplete frames stay hidden."""
        self.start();self.send(frame_id=1);until(self.session.latest)
        key = self.session.latest()[1]["key"]
        response = []
        waiter = threading.Thread(target=lambda:response.append(self.call("GET", "/api/frame?wait=500&after="+key, raw=True)))
        waiter.start();time.sleep(0.02);self.send(frame_id=2);waiter.join(2)
        self.assertFalse(waiter.is_alive());self.assertEqual(response[0][0], 200)
        self.assertEqual(json.loads(response[0][1]["X-Frame-Info"])["frame_id"], "2")

    def test_preview_stream_emits_derived_frame_and_releases_on_disconnect(self):
        """A real HTTP stream stays separate from full RAW reception ownership."""
        from struct import unpack
        self.start();data = self.send();until(self.session.latest)
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        connection.request("GET", "/api/preview-stream?mode=raw&downscale=2")
        response = connection.getresponse();self.assertEqual(response.status, 200)
        meta_bytes, pixel_bytes = unpack("<II", response.read(8))
        info = json.loads(response.read(meta_bytes));pixels = response.read(pixel_bytes)
        self.assertEqual((info["width"],info["height"],len(pixels)), (16,8,32))
        self.assertTrue(info["preview_derivative"])
        response.close();connection.close()
        self.send(frame_id=2**63+8)
        until(lambda:self.session.latest()[0].header.frame_id==2**63+8)
        self.assertTrue(self.session.status()["running"])
        self.assertEqual(self.session.latest()[0].data, data)

    def test_preview_stream_closes_when_receiver_stops(self):
        """A waiting preview must reach EOF without full status snapshots."""
        from struct import unpack
        self.start();self.send();until(self.session.latest)
        connection = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=3)
        try:
            connection.request("GET", "/api/preview-stream?mode=color&downscale=2")
            response = connection.getresponse()
            meta_bytes, pixel_bytes = unpack("<II", response.read(8))
            self.assertEqual(len(response.read(meta_bytes+pixel_bytes)), meta_bytes+pixel_bytes)
            self.session.stop()
            self.assertEqual(response.read(), b"")
        finally:
            connection.close()

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
        for asset in ("app.css","app.js","pixels.js","preview-worker.js","preview-renderer.js","favicon.svg"):
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

    def test_inventory_has_all_images_runs_and_standalone_reports(self):
        # Exceeds both former 100-image and 30-run caps.
        for n in range(111):
            (self.root/"data"/"many-images"/f"sample-{n}").mkdir(parents=True)
        for n in range(36):
            folder=self.root/"reports"/f"old-run-{n}"
            folder.mkdir(parents=True)
            (folder/"receiver-config.json").write_text(json.dumps(self.config),encoding="utf-8")
        (self.root/"reports"/"standalone.json").write_text('{"passed":true}',encoding="utf-8")
        (self.root/"reports"/"README.md").write_text("Directory documentation",encoding="utf-8")
        result=self.call("GET","/api/records")[2]
        self.assertEqual(len(result["archives"]),111)
        self.assertEqual(len(result["runs"]),37)
        self.assertEqual([r["key"] for r in result["reports"]],["standalone.json"])
        self.assertEqual(result["total"],149)
        self.assertEqual(len(self.call("GET","/api/archives")[2]["items"]),111)
        self.assertEqual(len(self.call("GET","/api/runs")[2]["items"]),37)
        self.assertEqual(self.call("GET","/api/artifact?key=standalone.json")[2],{"passed":True})
        self.assertEqual(self.call("GET","/api/artifact?key=README.md")[0],400)

    def test_delete_image_then_whole_run_and_report(self):
        state=self.start(archive_every=1)
        self.send(count=2)
        until(lambda:self.session.status()["saved_frames"]==2)
        self.session.stop()
        folder=self.root/"reports"
        (folder/"extra.json").write_text('{"test":true}',encoding="utf-8")
        images=self.call("GET","/api/records")[2]["archives"]
        result=self.call("POST","/api/records/delete",{"targets":[{"kind":"archive","key":images[0]["key"]}]})
        self.assertEqual(result[0],200,result)
        self.assertEqual(result[2]["failed"],[])
        self.assertFalse((self.root/"data"/images[0]["key"]).exists())
        self.assertTrue((folder/state["run_id"]/"web-session.json").exists())
        remaining=self.call("GET","/api/records")[2]["archives"][0]
        result=self.call("POST","/api/records/delete",{"targets":[
            {"kind":"archive","key":remaining["key"]},{"kind":"run","key":state["run_id"]},
            {"kind":"report","key":"extra.json"},{"kind":"report","key":"extra.json"}]})
        self.assertEqual(len(result[2]["deleted"]),3)
        self.assertEqual(result[2]["failed"],[])
        self.assertFalse((self.root/"data"/state["run_id"]).exists())
        self.assertFalse((folder/state["run_id"]).exists())
        self.assertFalse((folder/"extra.json").exists())
        self.assertTrue((self.root/"config/receiver.mock.json").exists())
        self.assertEqual(self.call("GET","/api/records")[2]["total"],0)

    def test_deletion_validates_entire_batch_and_active_session(self):
        state=self.start(archive_every=1)
        self.send()
        until(lambda:self.session.status()["saved_frames"]==1)
        (self.root/"reports"/"keep.json").write_text("{}",encoding="utf-8")
        data=self.call("GET","/api/records")[2]
        self.assertTrue(data["archives"][0]["protected"])
        self.assertTrue(next(r for r in data["runs"] if r["run_id"]==state["run_id"])["protected"])
        result=self.call("POST","/api/records/delete",{"targets":[
            {"kind":"report","key":"keep.json"},{"kind":"run","key":state["run_id"]}]})
        self.assertEqual(result[0],409)
        self.assertTrue((self.root/"reports/keep.json").exists())
        self.session.stop()
        result=self.call("POST","/api/records/delete",{"targets":[
            {"kind":"report","key":"keep.json"},{"kind":"report","key":"../config/receiver.mock.json"}]})
        self.assertEqual(result[0],409)
        self.assertTrue((self.root/"reports/keep.json").exists())
        self.assertEqual(self.call("POST","/api/records/delete",{"targets":[]})[0],409)
        self.assertEqual(self.call("POST","/api/records/delete",{"targets":[{"kind":"run","key":""}]})[0],409)
        self.assertEqual(self.call("POST","/api/records/delete",{"targets":[{"kind":"report","key":"keep.json"}]},
            headers={"X-Pango-Token":"bad"})[0],403)
        self.assertTrue((self.root/"config/receiver.mock.json").exists())

    def test_delete_reports_partial_failure_and_retry(self):
        from pango_video.record_store import delete_records
        (self.root/"reports").mkdir(exist_ok=True)
        for name in ("blocked.json","free.json"):
            (self.root/"reports"/name).write_text("{}",encoding="utf-8")
        original=Path.unlink
        def unlink(path,*args,**kwargs):
            if path.name=="blocked.json":
                raise PermissionError("injected file lock")
            return original(path,*args,**kwargs)
        with patch.object(Path,"unlink",unlink):
            result=delete_records(self.root,[{"kind":"report","key":"blocked.json"},{"kind":"report","key":"free.json"}])
        self.assertEqual([r["key"] for r in result["deleted"]],["free.json"])
        self.assertEqual([r["key"] for r in result["failed"]],["blocked.json"])
        self.assertTrue((self.root/"reports/blocked.json").exists())
        self.assertFalse((self.root/"reports/free.json").exists())
        self.assertEqual(delete_records(self.root,[{"kind":"report","key":"blocked.json"}])["failed"],[])

    def test_delete_rejects_linked_descendants_before_removal(self):
        from pango_video.record_store import RecordError, delete_records
        run=self.root/"reports/linked-run"
        run.mkdir(parents=True)
        sentinel=run/"linked.txt"
        sentinel.write_text("must remain",encoding="utf-8")
        original=Path.is_symlink
        # Inject a link predicate to exercise the platform-neutral guard on Windows
        # without requiring developer-mode privileges to create symlinks.
        def is_symlink(path):
            return path==sentinel or original(path)
        with patch.object(Path,"is_symlink",is_symlink):
            with self.assertRaises(RecordError):
                delete_records(self.root,[{"kind":"run","key":"linked-run"}])
        self.assertTrue(sentinel.exists())
        self.assertEqual(sentinel.read_text(encoding="utf-8"),"must remain")


if __name__=="__main__":
    unittest.main()

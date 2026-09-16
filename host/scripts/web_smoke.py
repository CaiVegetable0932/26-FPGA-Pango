"""Repeatable 1080p Web API + real UDP mock smoke; no browser/hardware acceptance."""
from datetime import datetime, timezone
import hashlib
import http.client
import json
from pathlib import Path
import platform
import socket
import sys
import threading
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0,str(ROOT/"src"))
from pango_video.web_server import LocalServer


def main():
    server = LocalServer(0)
    thread = threading.Thread(target=server.serve_forever,kwargs={"poll_interval":0.05},daemon=True)
    thread.start()
    token = None
    def api(path, data=None, raw=False):
        connection = http.client.HTTPConnection("127.0.0.1",server.server_port,timeout=12)
        headers = {"Content-Type":"application/json"}
        if token:
            headers["X-Pango-Token"] = token
        connection.request("GET" if data is None else "POST",path,
            body=None if data is None else json.dumps(data).encode(),headers=headers)
        response = connection.getresponse()
        payload = response.read()
        code, hdr = response.status, dict(response.getheaders())
        connection.close()
        if code >= 400:
            raise RuntimeError(f"HTTP {code}: {payload.decode('utf-8')}")
        return code,hdr,payload if raw or not payload else json.loads(payload)

    checks = []
    report = dict(utc=datetime.now(timezone.utc).isoformat(),platform=platform.platform(),python=sys.version,
        source_mode="mock",resolution=[1920,1080],nominal_sender_fps=30,
        hardware_acceptance="not_performed",ubuntu_target_validation="not_performed",
        browser_ui_qa="not_performed",webmcp_runtime_validation="not_performed")
    try:
        token = api("/api/session")[2]["token"]
        config = json.loads((ROOT/"config/receiver.mock.json").read_text(encoding="utf-8"))
        # Reserve distinct ephemeral UDP endpoints together, then hand them to the receiver/sender.
        endpoints = [socket.socket(socket.AF_INET,socket.SOCK_DGRAM) for _ in range(2)]
        try:
            for endpoint in endpoints:
                endpoint.bind(("127.0.0.1",0))
            config["port"],config["peer_port"] = [s.getsockname()[1] for s in endpoints]
        finally:
            for endpoint in endpoints:
                endpoint.close()
        config["stream_epoch"] = str(config["stream_epoch"])
        first = api("/api/start",dict(config=config))[2]
        deadline = time.monotonic()+20
        preview = None
        while time.monotonic()<deadline:
            state = api("/api/status")[2]
            code,hdr,data = api("/api/frame",raw=True)
            if code==200:
                info = json.loads(hdr["X-Frame-Info"])
                assert len(data)==1920*1080==info["frame_bytes"]
                assert info["source_mode"]=="mock" and not info["measurement_ready"]
                preview = info
            if preview and state["metrics"]["assembly"]["counters"].get("live_frames_complete",0)>=20:
                break
            if state["error"]:
                raise RuntimeError(state["error"])
            time.sleep(0.08)
        else:
            raise RuntimeError("1080p mock did not produce enough complete frames")
        checks.append("1080p RAW8 binary preview and live counters")
        receipt = api("/api/save",{})[2]
        deadline = time.monotonic()+5
        while time.monotonic()<deadline:
            state = api("/api/status")[2]
            if state["saved_frames"]==1:
                break
            time.sleep(0.03)
        else:
            raise RuntimeError("manual archive did not commit")
        item = next(i for i in api("/api/archives")[2]["items"] if i["run_id"]==first["run_id"])
        raw = api("/api/archive/pixels?key="+item["key"],raw=True)[2]
        metadata = api("/api/archive/metadata?key="+item["key"])[2]
        assert len(raw)==1920*1080
        assert metadata["sha256"]==hashlib.sha256(raw).hexdigest()
        assert str(metadata["frame_id"])==receipt["frame_id"]
        assert metadata["source_mode"]=="mock" and metadata["hdmi_source_frame_id"] is None
        checks.append("latest complete frame archive, original metadata and SHA-256 download")
        first_stopped = api("/api/stop",{})[2]
        assert first_stopped["state"]=="stopped" and api("/api/frame",raw=True)[0]==204
        checks.append("stop drains archive and removes live preview")
        second = api("/api/start",{})[2]
        assert second["run_id"]!=first["run_id"] and second["frame"] is None
        deadline = time.monotonic()+10
        while time.monotonic()<deadline:
            code,hdr,_ = api("/api/frame",raw=True)
            if code==200:
                assert json.loads(hdr["X-Frame-Info"])["run_id"]==second["run_id"]
                break
            time.sleep(0.05)
        else:
            raise RuntimeError("restart did not produce a fresh frame")
        second_stopped = api("/api/stop",{})[2]
        assert second_stopped["state"]=="stopped"
        checks.append("restart creates fresh run identity and resumes real UDP frames")
        records = api("/api/runs")[2]["items"]
        for current in (first_stopped,second_stopped):
            record = next(i for i in records if i["run_id"]==current["run_id"])
            result = api("/api/report?key="+record["key"])[2]
            assert result["hardware_acceptance"]=="not_performed"
        checks.append("both completed run reports are downloadable")
        report.update(passed=True,checks=checks,first_run_id=first["run_id"],second_run_id=second["run_id"],
            first_run_complete_frames=first_stopped["metrics"]["assembly"]["counters"].get("live_frames_complete",0),
            first_run_metrics=first_stopped["metrics"],observed_mock_complete_fps=state["complete_fps"],
            observed_mock_payload_mb_s=state["payload_mb_s"],raw_artifact="host/data/"+item["key"]+"/image.raw",
            metadata_artifact="host/data/"+item["key"]+"/metadata.json",raw_sha256=metadata["sha256"],
            note="Loopback software checks only. The nominal sender target is not a board throughput result.")
    except Exception as error:
        report.update(passed=False,checks=checks,error=str(error))
        raise
    finally:
        try:
            server.session.stop()
        finally:
            server.shutdown()
            server.server_close()
            thread.join(2)
        report["source_sha256"] = {p.relative_to(ROOT).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
            for folder in ("src/pango_video","web") for p in sorted((ROOT/folder).glob("*")) if p.is_file()}
        (ROOT/"reports/webui-smoke.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
        print(json.dumps({k:v for k,v in report.items() if k not in ("first_run_metrics","source_sha256")},ensure_ascii=False,indent=2))


if __name__=="__main__":
    main()

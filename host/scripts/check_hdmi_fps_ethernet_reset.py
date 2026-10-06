"""Verify current HDMI counters and independent Ethernet recovery in one existing tab.

The stall check briefly pauses only the video element, leaving its physical
MediaStreamTrack live. Ethernet reset is an explicit opt-in hardware action.
No extra tabs, USB/power changes, OS network writes or FPGA reset are performed.
"""
import argparse
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import sys
import time

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / "src"))
from check_hardware_inputs import api, linux_hagibis
from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright


def snapshot(page):
    """Read the installed meter without competing callbacks or pixel readbacks."""
    status = api("/api/status")
    browser = page.evaluate("""() => {
      const v=document.getElementById('capture-video'), rate=document.getElementById('capture-preview-rate');
      const t=v.srcObject?.getVideoTracks()[0], q=v.getVideoPlaybackQuality();
      return {time:performance.now(),preview:rate.textContent,meter:JSON.parse(rate.dataset.measurement||'null'),
        health:document.getElementById('capture-preview-health').textContent,
        quality:{total:q.totalVideoFrames,dropped:q.droppedVideoFrames},
        track:t?{id:t.id,label:t.label,readyState:t.readyState,settings:t.getSettings()}:null,
        canvas:{...document.getElementById('live-canvas').dataset},
        networkPreview:document.getElementById('preview-rate').textContent,
        sameStream:!window.__pangoEthernetBaseline||window.__pangoEthernetBaseline===v.srcObject,
        fields:Object.fromEntries(['source-ip','source-mac','peer-port','source-port','interface','port'].map(k=>[k,document.getElementById('board-'+k).value]))};
    }""")
    return dict(now=time.monotonic(), browser=browser, run_id=status["run_id"],
                config=status["config"], frame=status["frame"], signal=status["signal"],
                counters=status["metrics"].get("assembly", {}).get("counters", {}))


def main():
    """Fail visibly with a partial report retained if hardware verification fails."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--reload", action="store_true")
    parser.add_argument("--verify-stall", action="store_true")
    parser.add_argument("--reset-ethernet", action="store_true")
    parser.add_argument("--seconds", type=int, default=20, choices=range(5, 61))
    parser.add_argument("--folder", type=Path, default=HOST / "reports/hdmi-fps-ethernet-reset-20261006")
    args = parser.parse_args()
    folder = args.folder.resolve()
    if not folder.is_relative_to((HOST / "reports").resolve()):
        parser.error("reports must remain under host/reports")
    folder.mkdir(parents=True, exist_ok=True)
    report = dict(utc=datetime.now(timezone.utc).isoformat(), device=linux_hagibis(), checks={}, errors=[])
    def save():
        (folder / "verification.json").write_text(json.dumps(report, ensure_ascii=False, indent=2)+"\n", encoding="utf-8")
    try:
        with sync_playwright() as p:
            browser = p.chromium.connect_over_cdp(endpoint(), no_defaults=True)
            pages = [pg for c in browser.contexts for pg in c.pages if page_key(pg.url) == page_key("http://127.0.0.1:8765/")]
            if len(pages) != 1:
                raise RuntimeError(f"Expected one existing workbench; found {len(pages)}")
            page = pages[0]
            page.on("pageerror", lambda error:report["errors"].append(str(error)))
            if args.reload:
                page.reload(wait_until="domcontentloaded")
            # Function predicates respect the workbench CSP; string expressions
            # would make Playwright use eval and falsely fail on unsafe-eval.
            page.wait_for_function("() => document.getElementById('capture-video').srcObject?.getVideoTracks()[0]?.readyState==='live'", timeout=45000)
            page.wait_for_function("() => !!document.getElementById('capture-preview-rate').dataset.measurement", timeout=15000)
            # Wait for asynchronous commissioning before taking a stable baseline.
            deadline = time.monotonic()+30
            while api("/api/board/status")["busy"]:
                if time.monotonic() > deadline:
                    raise RuntimeError("Board startup did not finish")
                page.wait_for_timeout(500)
            page.wait_for_timeout(2000)
            report["initial"] = snapshot(page)
            if report["initial"]["browser"]["track"]["label"] != "Hagibis":
                raise RuntimeError("Browser capture label is not Hagibis")
            if args.verify_stall:
                # This is a controlled UI pause, not evidence of hardware failure.
                page.evaluate("document.getElementById('capture-video').pause()")
                try:
                    page.wait_for_timeout(2200)
                    report["controlled_pause"] = snapshot(page)
                    assert report["controlled_pause"]["browser"]["meter"]["fps"] == 0
                    assert report["controlled_pause"]["browser"]["track"]["readyState"] == "live"
                    report["checks"]["pause_expires_preview_fps_to_zero"] = True
                finally:
                    page.evaluate("document.getElementById('capture-video').play()")
                page.wait_for_timeout(2200)
            if args.reset_ethernet:
                report["before_reset"] = snapshot(page)
                report["board_before_reset"] = api("/api/board/status")
                page.evaluate("""() => {
                  window.__pangoEthernetBaseline=document.getElementById('capture-video').srcObject;
                  // Unsaved wrong form entries exercise the one-click recovery;
                  // no invalid addresses are ever submitted to the FPGA.
                  document.getElementById('board-source-ip').value='10.20.30.40';
                  document.getElementById('board-peer-port').value='12345';
                }""")
                page.locator("#board-reset-ethernet").click()
                page.wait_for_function("() => !document.getElementById('board-reset-ethernet').disabled && document.getElementById('board-source-ip').value==='192.168.80.3'", timeout=35000)
                page.wait_for_timeout(2000)
                report["after_reset"] = snapshot(page)
                report["board_after_reset"] = api("/api/board/status")
                a,b = report["before_reset"],report["after_reset"]
                assert b["browser"]["sameStream"] and a["browser"]["track"]["id"] == b["browser"]["track"]["id"]
                assert a["run_id"] != b["run_id"] and b["signal"] == "live"
                assert a["config"]["stream_epoch"] == b["config"]["stream_epoch"]
                assert b["browser"]["fields"]["peer-port"] == "50000"
                assert b["browser"]["fields"]["source-port"] == "50001"
                saved = json.loads((HOST / "config/board-link.json").read_text())
                assert saved == report["board_after_reset"]["profile"]
                assert saved["source_ip"] == "192.168.80.3" and saved["peer_port"] == 50000
                report["checks"].update(ethernet_default_fields_restored=True, defaults_persisted=True,
                                        receiver_restarted_and_live=True, hdmi_stream_and_track_unchanged=True, warm_epoch_preserved=True)
                page.evaluate("delete window.__pangoEthernetBaseline")
            samples = [snapshot(page)]
            start = time.monotonic()
            while time.monotonic()-start < args.seconds:
                page.wait_for_timeout(1000)
                samples.append(snapshot(page))
            report["samples"] = samples
            a,b = samples[0],samples[-1]
            seconds = b["now"]-a["now"]
            meters = [s["browser"]["meter"] for s in samples if s["browser"]["meter"]]
            report["rates"] = dict(seconds=seconds,
                complete_fps=(b["counters"].get("live_frames_complete",0)-a["counters"].get("live_frames_complete",0))/seconds,
                # Match the UI: totalVideoFrames includes dropped frames.
                decode_fps=((b["browser"]["quality"]["total"]-b["browser"]["quality"]["dropped"])-
                            (a["browser"]["quality"]["total"]-a["browser"]["quality"]["dropped"]))/seconds,
                decoder_drops=b["browser"]["quality"]["dropped"]-a["browser"]["quality"]["dropped"],
                preview_min=min(m["fps"] for m in meters), preview_max=max(m["fps"] for m in meters),
                callback_windows_with_skips=sum(m["skipped"]>0 for m in meters),
                maximum_update_gap_ms=max(m["maxGapMs"] for m in meters))
            assert b["signal"] == "live" and b["frame"]
            assert b["browser"]["quality"]["total"] > a["browser"]["quality"]["total"]
            assert not report["errors"], report["errors"]
            page.screenshot(path=str(folder / "workbench-derived.png"), full_page=False)
            report["checks"]["both_physical_previews_running"] = True
            report["passed"] = True
    except BaseException as error:
        report["passed"] = False
        report["failure"] = str(error)
        raise
    finally:
        sources = ["web/preview-rate.js", "web/video-input-ui.js", "web/board-link.js", "web/index.html",
                   "src/pango_video/board_link.py", "src/pango_video/web_server.py"]
        report["source_sha256"] = {name:hashlib.sha256((HOST / name).read_bytes()).hexdigest() for name in sources}
        save()
    print(json.dumps(dict(checks=report["checks"], rates=report["rates"], report=str(folder / "verification.json")), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

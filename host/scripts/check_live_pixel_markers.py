"""Verify real RAW8/HDMI pixel overlays in the existing desktop workbench.

Reuse one browser page and its Hagibis track. No mock source, second capture
session, USB reset, driver change or power-management write is performed.
"""
import argparse
import base64
from datetime import datetime, timezone
import hashlib
import json
from pathlib import Path
import time

from check_hardware_inputs import api, linux_hagibis
from open_browser import endpoint, open_tab, page_key
from playwright.sync_api import expect, sync_playwright

HOST = Path(__file__).resolve().parents[1]
URL = "http://127.0.0.1:8765/"


def snapshot(page):
    """Read DOM timing and marker coordinates without transferring video pixels."""
    status = api("/api/status")
    result = page.evaluate("""() => {
        const v=document.getElementById('capture-video'),t=v?.srcObject?.getVideoTracks()[0],q=v?.getVideoPlaybackQuality();
        function overlay(id){const el=document.getElementById(id);return el?{
            visible:!el.hasAttribute('hidden')&&getComputedStyle(el).display!=='none',
            count:el.querySelectorAll('g').length,points:JSON.parse(el.dataset.coordinates||'[]')}:null;}
        return {url:location.href,visibility:document.visibilityState,
            updatedUI:!!document.getElementById('pixel-markers-toggle'),
            track:t?{id:t.id,label:t.label,readyState:t.readyState,muted:t.muted,settings:t.getSettings()}:null,
            video:{width:v?.videoWidth,height:v?.videoHeight,time:v?.currentTime,paused:v?.paused,
                total:q?.totalVideoFrames||0,dropped:q?.droppedVideoFrames||0},
            raw:overlay('raw-pixel-markers'),hdmi:overlay('capture-pixel-markers'),
            markerInfo:document.getElementById('pixel-markers-info')?.textContent,
            rate:document.getElementById('capture-preview-rate')?.textContent,
            rateInfo:JSON.parse(document.getElementById('capture-preview-rate')?.dataset.measurement||'null'),
            rawRate:document.getElementById('preview-rate')?.textContent,
            corrected:{visible:!document.getElementById('capture-corrected')?.hidden,
                draws:Number(document.getElementById('capture-corrected')?.dataset.renderCount||0),
                renderer:document.getElementById('capture-corrected')?.dataset.renderer,
                info:document.getElementById('capture-correction-info')?.textContent},
            savedDevice:JSON.parse(localStorage.getItem('pango.video-input.v1')||'null'),
            message:document.getElementById('capture-message')?.textContent};
    }""")
    return dict(time=time.monotonic(), browser=result, run_id=status.get("run_id"),
                source_mode=status["config"]["source_mode"], signal=status["signal"],
                complete=status.get("metrics", {}).get("assembly", {}).get("counters", {}).get("live_frames_complete", 0))


def sample_window(page, seconds):
    """Compare decoder progress and complete RAW frames over a bounded interval."""
    samples = [snapshot(page)]
    for _ in range(seconds):
        page.wait_for_timeout(1000)
        samples.append(snapshot(page))
    a, b = samples[0], samples[-1]
    elapsed = b["time"] - a["time"]
    assert a["run_id"] == b["run_id"] and b["signal"] == "live", "RAW session changed or stalled"
    assert a["browser"]["track"]["id"] == b["browser"]["track"]["id"], "HDMI track was replaced"
    qa, qb = a["browser"]["video"], b["browser"]["video"]
    assert qb["total"] > qa["total"], "HDMI decoder did not advance"
    assert b["complete"] > a["complete"], "No new complete Ethernet frames"
    return dict(seconds=elapsed, complete_fps=(b["complete"] - a["complete"]) / elapsed,
                decode_fps=((qb["total"] - qb["dropped"]) - (qa["total"] - qa["dropped"])) / elapsed,
                correction_fps=(b["browser"]["corrected"]["draws"] - a["browser"]["corrected"]["draws"]) / elapsed,
                samples=samples)


def preserve_native_inputs(page, folder):
    """Keep native RAW/RGB separately from annotated screenshots, unpaired."""
    result = page.evaluate("""async () => {
        function encode(bytes){const parts=[];for(let i=0;i<bytes.length;i+=32768)
            parts.push(String.fromCharCode(...bytes.subarray(i,i+32768)));return btoa(parts.join(''));}
        const response=await fetch('/api/frame',{cache:'no-store'});
        if(response.status!==200)throw Error('Native RAW frame unavailable');
        const raw=new Uint8Array(await response.arrayBuffer()),meta=JSON.parse(response.headers.get('X-Frame-Info'));
        const video=document.getElementById('capture-video'),canvas=document.createElement('canvas');
        canvas.width=video.videoWidth;canvas.height=video.videoHeight;
        const c=canvas.getContext('2d',{willReadFrequently:true});c.drawImage(video,0,0);
        const rgba=c.getImageData(0,0,canvas.width,canvas.height).data,rgb=new Uint8Array(canvas.width*canvas.height*3);
        for(let i=0,j=0;i<rgba.length;i+=4){rgb[j++]=rgba[i];rgb[j++]=rgba[i+1];rgb[j++]=rgba[i+2];}
        return {raw:encode(raw),rawMeta:meta,rgb:encode(rgb),width:canvas.width,height:canvas.height};
    }""")
    folder.mkdir(parents=True, exist_ok=True)
    raw, rgb = base64.b64decode(result.pop("raw")), base64.b64decode(result.pop("rgb"))
    (folder / "ethernet.raw").write_bytes(raw)
    (folder / "hdmi-decoded.rgb").write_bytes(rgb)
    result.update(raw_bytes=len(raw), raw_sha256=hashlib.sha256(raw).hexdigest(),
                  rgb_bytes=len(rgb), rgb_sha256=hashlib.sha256(rgb).hexdigest(),
                  hdmi_source_frame_id=None, pairing_status="unverified",
                  hdmi_format="browser_decoded_RGB888", overlays_in_native_inputs=False)
    (folder / "metadata.json").write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return result


def main():
    """Leave the existing page visible, marked and corrected after verification."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--status-only", action="store_true")
    parser.add_argument("--reload", action="store_true", help="load new static assets in the existing page")
    parser.add_argument("--seconds", type=int, choices=range(3, 16), default=8)
    parser.add_argument("--out", type=Path, default=HOST / "reports/pixel-markers20-hardware-20261006")
    args = parser.parse_args()
    folder = args.out
    folder.mkdir(parents=True, exist_ok=True)
    report = dict(utc=datetime.now(timezone.utc).isoformat(), passed=False, errors=[], checks={})
    try:
        report["device"] = linux_hagibis()
        report["board"] = api("/api/board/status")
        state = api("/api/status")
        report["service"] = {k:state.get(k) for k in ("running", "signal", "run_id", "state", "frame")}
        report["source_mode"] = state["config"]["source_mode"]
        cdp = endpoint()
        report["browser_available"] = bool(cdp)
        with sync_playwright() as automation:
            if not cdp:
                if args.status_only:
                    return print(json.dumps(report, ensure_ascii=False, indent=2))
                raise RuntimeError("Existing project browser unavailable; use the normal one-command launcher first")
            browser = automation.chromium.connect_over_cdp(cdp, no_defaults=True)
            report["pages"] = [pg.url for context in browser.contexts for pg in context.pages]
            pages = [pg for context in browser.contexts for pg in context.pages if page_key(pg.url) == page_key(URL)]
            if args.status_only:
                report["page_states"] = [snapshot(pg) for pg in pages]
                print(json.dumps(report, ensure_ascii=False, indent=2))
                return
            assert report["source_mode"] == "hardware_unverified", "Receiver is not configured for actual board data"
            # The launcher reuses one canonical tab and keeps unrelated tabs.
            open_tab(browser, URL)
            page = next(pg for context in browser.contexts for pg in context.pages if page_key(pg.url) == page_key(URL))
            page.on("pageerror", lambda error:report["errors"].append(str(error)))
            saved = page.evaluate("() => JSON.parse(localStorage.getItem('pango.video-input.v1')||'null')")
            assert saved is None or "hagibis" in saved.get("label", "").lower(), "Saved input is not Hagibis"
            if args.reload or not page.locator("#pixel-markers-toggle").count():
                page.reload(wait_until="domcontentloaded")
            expect(page.locator("#server-health")).to_have_text("服务已连接", timeout=15000)
            page.locator("nav [data-view='live']").click()
            if api("/api/status")["signal"] != "live":
                # Use only the normal saved board-start action if the receiver
                # is awaiting commissioning; do not reset firmware or USB.
                expect(page.locator("#board-start")).to_be_enabled(timeout=30000)
                page.locator("#board-start").click()
            expect(page.locator("#live-canvas")).to_be_visible(timeout=35000)
            page.wait_for_function("() => document.getElementById('capture-video').srcObject?.getVideoTracks()[0]?.readyState==='live' && document.getElementById('capture-video').videoWidth>0", timeout=45000)
            initial = snapshot(page)
            assert initial["browser"]["track"]["label"].lower() == "hagibis", "Unexpected browser input label"
            assert (initial["browser"]["video"]["width"], initial["browser"]["video"]["height"]) == (1920, 1080), "HDMI input is not native 1080p"
            stream_id = initial["browser"]["track"]["id"]
            if page.locator("#capture-correction-toggle").get_attribute("aria-pressed") == "true":
                page.locator("#capture-correction-toggle").click()
            if page.locator("#pixel-markers-toggle").get_attribute("aria-pressed") != "true":
                page.locator("#pixel-markers-toggle").click()
            expect(page.locator("#raw-pixel-markers")).to_be_visible()
            expect(page.locator("#capture-pixel-markers")).to_be_visible()
            expect(page.locator("#raw-pixel-markers > g")).to_have_count(20)
            expect(page.locator("#capture-pixel-markers > g")).to_have_count(20)
            page.wait_for_timeout(1500)
            report["original"] = sample_window(page, args.seconds)
            page.screenshot(path=str(folder / "original-markers-derived.png"), full_page=False)
            report["native_inputs"] = preserve_native_inputs(page, HOST / "data" / folder.name)
            report["checks"]["actual_original_overlays_on_both_links"] = True
            page.locator("#pixel-markers-toggle").click()
            expect(page.locator("#raw-pixel-markers")).to_be_hidden()
            expect(page.locator("#capture-pixel-markers")).to_be_hidden()
            assert snapshot(page)["browser"]["track"]["id"] == stream_id
            page.locator("#pixel-markers-toggle").click()
            page.locator("#capture-correction-toggle").click()
            expect(page.locator("#capture-corrected")).to_be_visible()
            page.wait_for_function("() => document.getElementById('pixel-markers-info').textContent.includes('矫正视野内')", timeout=15000)
            page.wait_for_timeout(1500)
            report["corrected"] = sample_window(page, args.seconds)
            latest = report["corrected"]["samples"][-1]["browser"]
            points = latest["hdmi"]["points"]
            assert latest["hdmi"]["count"] == sum(p["visible"] for p in points)
            assert latest["hdmi"]["count"] > 0 and report["corrected"]["correction_fps"] > 0
            assert any(p["visible"] and abs(p["output"][0] - p["point"][0]) > 1 for p in points)
            assert latest["track"]["id"] == stream_id
            report["checks"].update(hide_show_verified=True, corrected_positions_visible=True,
                capture_track_preserved=True, both_links_advance=True, no_extra_workbench_tabs=True)
            page.screenshot(path=str(folder / "corrected-markers-derived.png"), full_page=False)
            assert not report["errors"], report["errors"]
            report["passed"] = True
            page.bring_to_front()
    except BaseException as error:
        report["failure"] = str(error)
        raise
    finally:
        name = "preflight.json" if args.status_only else "verification.json"
        (folder / name).write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(dict(passed=report["passed"], checks=report["checks"],
                         original={k:v for k,v in report["original"].items() if k!="samples"},
                         corrected={k:v for k,v in report["corrected"].items() if k!="samples"},
                         report=str(folder / "verification.json")), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()

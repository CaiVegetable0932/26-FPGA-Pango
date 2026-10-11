"""Measure real FPGA reception and existing browser previews, with no mock source."""
import argparse
from datetime import datetime, timezone
import json
import base64
import hashlib
from pathlib import Path
import subprocess
import time

from check_hardware_inputs import api, linux_hagibis
from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright

HOST = Path(__file__).resolve().parents[1]
URL = "http://127.0.0.1:8765/"


def snapshot(page):
    """Keep kernel drops separate from board frame gaps and complete frames."""
    status = api("/api/status")
    counts = status["metrics"].get("assembly", {}).get("counters", {})
    nic = {}
    for name in ("rx_packets", "rx_bytes", "rx_dropped", "rx_errors"):
        nic[name] = int(Path(f"/sys/class/net/enP8p1s0/statistics/{name}").read_text())
    drops = None
    for line in Path("/proc/net/udp").read_text().splitlines()[1:]:
        fields = line.split()
        if fields[1].endswith(":C350"):
            drops = int(fields[-1])
    video = page.locator("#capture-video").evaluate("""v => ({width:v.videoWidth,height:v.videoHeight,
        frames:v.getVideoPlaybackQuality().totalVideoFrames,dropped:v.getVideoPlaybackQuality().droppedVideoFrames,
        observed:Number(v.dataset.framesObserved||0),settings:v.srcObject?.getVideoTracks()[0]?.getSettings(),label:v.srcObject?.getVideoTracks()[0]?.label})""")
    return dict(now=time.monotonic(), running=status["running"], config=status["config"],
        run_id=status["run_id"], frame=status["frame"], counters=counts, nic=nic, socket_drops=drops,
        assembly=status["metrics"].get("assembly", {}), video=video,
        # Preserve receive/consumer queue counters independently of assembly.
        receiver_counters=status["metrics"].get("counters", {}),
        receiver_features=status["metrics"].get("backend", {}),
        canvas=page.locator("#live-canvas").evaluate("c=>({...c.dataset,width:c.width,height:c.height})"),
        network_display=page.locator("#preview-rate").inner_text(),
        hdmi_display=page.locator("#capture-preview-rate").inner_text() if page.locator("#capture-preview-rate").count() else None)


def main():
    """Optionally load tested changes, then measure both currently visible views."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--reload", action="store_true")
    parser.add_argument("--restart-service", action="store_true")
    parser.add_argument("--label", default="measurement")
    parser.add_argument("--preview-mode", choices=("raw", "color", "gray"),
                        help="测量指定模式；未指定时在刷新后保留当前模式")
    parser.add_argument("--verify-renderer", action="store_true", help="测量前核对独立软件样本的 GPU/Worker 像素一致性")
    parser.add_argument("--save-evidence", action="store_true", help="测量后保存完整 RAW 和原生解码 RGB，不影响测量窗口")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 120:
        parser.error("seconds must be between 5 and 120")
    device = linux_hagibis()
    if args.restart_service:
        # The normal service drains its current run before restarting; the
        # existing board coordinator revalidates its saved cold/warm epoch.
        subprocess.run(["systemctl", "--user", "restart", "pango-host.service"], check=True, timeout=45)
        deadline = time.monotonic() + 75
        while time.monotonic() < deadline:
            try:
                if api("/api/status")["running"]:
                    break
            except Exception:
                pass
            time.sleep(1)
        else:
            raise RuntimeError("Saved board setup did not resume after service restart")
    folder = HOST / "reports" / ("preview-performance-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    folder.mkdir()
    errors = []
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(), timeout=10000, no_defaults=True)
        page = next(p for p in browser.contexts[0].pages if page_key(p.url) == page_key(URL))
        page.on("pageerror", lambda error: errors.append(str(error)))
        # Reloading product code must not silently change color to the default
        # RAW view and make before/after timings incomparable.
        preview_mode = args.preview_mode or page.locator("[data-color].selected").get_attribute("data-color")
        if args.reload or args.restart_service:
            page.reload(wait_until="domcontentloaded")
        page.locator(f"[data-color='{preview_mode}']").click()
        page.bring_to_front()
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            ready = page.locator("#capture-video").evaluate("v => v.readyState>=2&&v.videoWidth>0")
            if ready:
                break
            page.wait_for_timeout(500)
        else:
            raise RuntimeError("Hagibis did not begin decoding")
        if "Hagibis" not in snapshot(page)["video"]["label"]:
            raise RuntimeError("Browser preview is not the verified Hagibis")
        renderer_checks = None
        if args.verify_renderer:
            # Fixtures use an isolated worker and detached canvas. They never
            # replace the user's live image or contribute to hardware counters.
            from check_preview_renderer import verify_renderer
            renderer_checks = verify_renderer(page)
        page.wait_for_timeout(5000)
        first = snapshot(page)
        samples = []
        start = time.monotonic()
        while time.monotonic() - start < args.seconds:
            page.wait_for_timeout(1000)
            samples.append(snapshot(page))
        last = samples[-1]
        elapsed = last["now"] - first["now"]
        delta = {k:last["counters"].get(k, 0)-first["counters"].get(k, 0)
                 for k in set(first["counters"]) | set(last["counters"])}
        complete_fps = delta.get("live_frames_complete", 0) / elapsed
        observed_fps = delta.get("live_frames_observed", 0) / elapsed
        hdmi_fps = (last["video"]["frames"]-first["video"]["frames"]) / elapsed
        canvas_fps = (int(last["canvas"].get("framesPresented",0))-int(first["canvas"].get("framesPresented",0))) / elapsed
        # Retain short-window variation as well as the whole-window average;
        # a mean near 30 alone does not establish stable display delivery.
        intervals = []
        for a,b in zip([first]+samples, samples):
            dt = b["now"]-a["now"]
            intervals.append(dict(elapsed_seconds=dt,
                network_canvas_fps=(int(b["canvas"].get("framesPresented",0))-int(a["canvas"].get("framesPresented",0)))/dt,
                # Quality totals and actual observed callbacks are separate.
                hdmi_browser_total_fps=(b["video"]["frames"]-a["video"]["frames"])/dt,
                hdmi_observed_preview_fps=(b['video']['observed']-a['video']['observed'])/dt,
                complete_fps=(b["counters"].get("live_frames_complete",0)-a["counters"].get("live_frames_complete",0))/dt))
        page.screenshot(path=str(folder / "dual-preview.png"), full_page=True)
        evidence = {}
        if args.save_evidence:
            # Preserve one original full RAW via the receiver's archive path.
            # Decode one native-size Hagibis frame to RGB, with no rescaling;
            # this is browser-decoded UVC evidence, never paired sensor RAW.
            saved = api("/api/save", {})
            evidence["raw_save"] = saved
            decoded = page.locator("#capture-video").evaluate("""v=>{
                const c=document.createElement('canvas');c.width=v.videoWidth;c.height=v.videoHeight;
                const ctx=c.getContext('2d');ctx.drawImage(v,0,0);
                const rgba=ctx.getImageData(0,0,c.width,c.height).data,rgb=new Uint8Array(c.width*c.height*3);
                for(let i=0,j=0;i<rgba.length;i+=4){rgb[j++]=rgba[i];rgb[j++]=rgba[i+1];rgb[j++]=rgba[i+2];}
                const parts=[];for(let i=0;i<rgb.length;i+=32768)parts.push(String.fromCharCode(...rgb.subarray(i,i+32768)));
                return {width:c.width,height:c.height,data:btoa(parts.join(''))};}""")
            pixels = base64.b64decode(decoded.pop("data"))
            # Raw capture evidence belongs in host/data; reports reference it.
            capture_folder = HOST / "data" / folder.name
            capture_folder.mkdir(exist_ok=True)
            (capture_folder / "hdmi-native.rgb").write_bytes(pixels)
            metadata = dict(**decoded, pixel_format="RGB888", row_stride=decoded["width"]*3,
                sha256=hashlib.sha256(pixels).hexdigest(), source="browser_decoded_hagibis_uvc",
                capture_settings=last["video"]["settings"], physical_device=device,
                source_frame_id=None, pairing_status="unverified", resized=False)
            (capture_folder / "hdmi-native.json").write_text(json.dumps(metadata, ensure_ascii=False, indent=2)+"\n")
            evidence["hdmi_rgb"] = dict(metadata, path=str(capture_folder.relative_to(HOST)))
        report = dict(label=args.label, preview_mode=preview_mode, elapsed_seconds=elapsed, physical_device=device,
            before=first, after=last, samples=samples, delta=delta,
            intervals=intervals,
            complete_fps=complete_fps, observed_network_ids_fps=observed_fps,
            hdmi_browser_total_fps=hdmi_fps,hdmi_observed_preview_fps=(last['video']['observed']-first['video']['observed'])/elapsed,
            network_canvas_fps=canvas_fps, source_frame_pairing="unverified", page_errors=errors,
            socket_drops=None if first["socket_drops"] is None else last["socket_drops"]-first["socket_drops"],
            nic_delta={k:last["nic"][k]-first["nic"][k] for k in first["nic"]})
        report["evidence"] = evidence
        report["renderer_checks"] = renderer_checks
        (folder / "performance.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({k:report[k] for k in ("label", "elapsed_seconds", "complete_fps", "observed_network_ids_fps", "hdmi_browser_total_fps", "hdmi_observed_preview_fps", "network_canvas_fps", "socket_drops", "nic_delta", "delta", "page_errors")}, ensure_ascii=False))
        print(f"Report: {folder}")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())

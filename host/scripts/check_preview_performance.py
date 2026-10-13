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


def source_version():
    """Record dirty core hashes as well as HEAD; exclude runtime evidence."""
    root=HOST.parent
    paths=sorted((HOST/"web").glob("*.js"))+sorted((HOST/"src/pango_video").glob("*.py"))
    return dict(commit=subprocess.check_output(["git","rev-parse","HEAD"],cwd=root,text=True).strip(),
        core_sha256={str(p.relative_to(root)):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths})


def snapshot(page):
    """Keep kernel drops separate from board frame gaps and complete frames."""
    # Long observations retain counters, not a repeated copy of every failure.
    status = api("/api/status?summary=1")
    counts = status["metrics"].get("assembly", {}).get("counters", {})
    nic = {}
    for name in ("rx_packets", "rx_bytes", "rx_dropped", "rx_errors"):
        nic[name] = int(Path(f"/sys/class/net/enP8p1s0/statistics/{name}").read_text())
    drops = None
    for line in Path("/proc/net/udp").read_text().splitlines()[1:]:
        fields = line.split()
        if fields[1].endswith(":C350"):
            drops = int(fields[-1])
    # Direct snapshot avoids selector polling through animation frames, which
    # can be throttled by desktop occlusion independently of video reception.
    ui=page.evaluate("""() => {const v=document.querySelector("#capture-video"),c=document.querySelector("#live-canvas");return {
      video:{width:v.videoWidth,height:v.videoHeight,frames:v.getVideoPlaybackQuality().totalVideoFrames,
        dropped:v.getVideoPlaybackQuality().droppedVideoFrames,observed:Number(v.dataset.framesObserved||0),
        settings:v.srcObject?.getVideoTracks()[0]?.getSettings(),label:v.srcObject?.getVideoTracks()[0]?.label},
      canvas:{...c.dataset,width:c.width,height:c.height},network_display:document.querySelector("#preview-rate").textContent,
      hdmi_display:document.querySelector("#capture-preview-rate")?.textContent,
      diagnostics:window.pangoPreviewDiagnostics?.()||null};}""")
    video=ui["video"]
    return dict(now=time.monotonic(), running=status["running"], config=status["config"],
        run_id=status["run_id"], frame=status["frame"], counters=counts, nic=nic, socket_drops=drops,
        assembly=status["metrics"].get("assembly", {}), video=video,
        # Preserve receive/consumer queue counters independently of assembly.
        receiver_counters=status["metrics"].get("counters", {}),
        receiver_features=status["metrics"].get("backend", {}),
        canvas=ui["canvas"],network_display=ui["network_display"],hdmi_display=ui["hdmi_display"],
        diagnostics=ui["diagnostics"])


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
    parser.add_argument("--latency-budget-ms", type=float, default=150,
                        help="本次预先约定的接收完成至 Canvas 提交年龄预算，非光学延迟承诺")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 3600 or not 0 < args.latency_budget_ms <= 10000:
        parser.error("seconds must be 5..3600; latency budget must be 0..10000 ms")
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
    version_before=source_version()
    errors = []
    with sync_playwright() as automation:
        print("Connecting to the existing preview",flush=True)
        browser = automation.chromium.connect_over_cdp(endpoint(), timeout=10000, no_defaults=True)
        page = next(p for p in browser.contexts[0].pages if page_key(p.url) == page_key(URL))
        page.on("pageerror", lambda error: errors.append(str(error)))
        # Reloading product code must not silently change color to the default
        # RAW view and make before/after timings incomparable.
        preview_mode = args.preview_mode or page.evaluate("() => document.querySelector('[data-color].selected').dataset.color")
        if args.reload or args.restart_service:
            page.reload(wait_until="domcontentloaded")
        # Avoid injecting a redundant pointer action into an already selected
        # view; direct DOM activation still exercises the real button handler.
        if page.evaluate("() => document.querySelector('[data-color].selected').dataset.color") != preview_mode:
            page.evaluate("mode => document.querySelector('[data-color='+mode+']').click()", preview_mode)
        # Observe the user's visible tab without a focus request to the desktop
        # window manager. Hidden tabs cannot establish display performance.
        if page.evaluate("() => document.visibilityState") != "visible":
            raise RuntimeError("Preview tab must be visible before measurement")
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            ready = page.evaluate("() => {const v=document.querySelector('#capture-video');return v?.readyState>=2&&v.videoWidth>0}")
            if ready:
                break
            time.sleep(.5)
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
        print("Preview ready; sampling both paths",flush=True)
        time.sleep(5)
        first = snapshot(page)
        samples = []
        start = time.monotonic()
        while time.monotonic() - start < args.seconds:
            time.sleep(1)
            samples.append(snapshot(page))
        last = samples[-1]
        print("Sampling complete; saving bounded report",flush=True)
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
        # Screenshots are optional evidence. Occluded desktop windows can
        # suppress animation-frame callbacks; retain metrics on timeout.
        screenshot_error=None
        if args.save_evidence:
            try:
                page.screenshot(path=str(folder / "dual-preview.png"), full_page=True,timeout=10000)
            except Exception as error:
                screenshot_error=type(error).__name__
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
        version_after=source_version()
        report["source_version"]=version_before
        report["source_unchanged_during_measurement"]=version_before==version_after
        report["screenshot_error"]=screenshot_error
        # Publish explicit criteria separately from script execution success.
        # No callback count can prove unique FPGA results or optical latency.
        age = last.get("diagnostics", {}).get("stages", {}).get("frame_age_estimate_ms", {}) if last.get("diagnostics") else {}
        uncertainty = (last.get("diagnostics") or {}).get("clock")
        report["latency_budget_ms"] = args.latency_budget_ms
        report["software_checks"] = dict(
            stable_lossless_receive=(report["socket_drops"] == 0 and
                not any(v for k,v in delta.items() if k.startswith("frames_failed_") or k=="live_frames_missing")),
            # Conservatively include the clock uncertainty in the budget test.
            recent_submission_age_within_budget=None if age.get("p99") is None or not uncertainty else
                age["p99"]+uncertainty["uncertainty_ms"] <= args.latency_budget_ms,
            optical_latency_verified=False, hdmi_source_identity_verified=False,
            cold_start_tested=False)
        report["host_preview_delivery"] = api("/api/preview-performance") if last.get("diagnostics") else None
        (folder / "performance.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")
        print(json.dumps({k:report[k] for k in ("label", "elapsed_seconds", "complete_fps", "observed_network_ids_fps", "hdmi_browser_total_fps", "hdmi_observed_preview_fps", "network_canvas_fps", "socket_drops", "nic_delta", "delta", "page_errors")}, ensure_ascii=False))
        print(f"Report: {folder}")
    return 0 if not errors else 1


if __name__ == "__main__":
    raise SystemExit(main())

"""Trace real DVP, UDP, canvas and Hagibis rates without changing board setup."""
import argparse
from datetime import datetime, timezone
import json
import os
from pathlib import Path
import statistics
import struct
import subprocess
import sys
import time

HOST = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(HOST / "src"))
from pango_video.board_link import Uart, serial_ports
from check_hardware_inputs import api, linux_hagibis
from check_preview_performance import snapshot
from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright


def write_report(folder, report):
    """Keep each finished phase even if a later hardware read fails."""
    (folder / "diagnosis.json").write_text(json.dumps(report, ensure_ascii=False, indent=2) + "\n")


class BoardProbe:
    """Read existing session telemetry; never send OPEN, boot or reset commands."""
    def __init__(self):
        state = api("/api/board/status")
        if state["busy"]:
            raise RuntimeError("Board startup owns UART; retry after it finishes")
        ports = [p for p in serial_ports() if p["serial"] == state["profile"]["serial_number"]]
        if len(ports) != 1:
            raise RuntimeError("Saved CP2102 serial is not unique")
        self.port = ports[0]["port"]
        owner = subprocess.run(["fuser", self.port], capture_output=True, text=True)
        if owner.returncode != 1:
            raise RuntimeError("UART is owned or ownership could not be checked: " + owner.stdout + owner.stderr)
        self.uart = Uart(self.port)
        try:
            caps = self.uart.exchange(1)
            if caps[0] or not int.from_bytes(caps[24:28], "little") & 0x40:
                raise RuntimeError("Board does not expose read-only DVP telemetry")
            self.epoch = int.from_bytes(caps[4:12], "little")
            self.session = int.from_bytes(caps[12:16], "little")
            if not self.session or str(self.epoch) != state["epoch"]:
                raise RuntimeError("Existing board epoch/session changed")
            self.payload = struct.pack("<QI", self.epoch, self.session)
        except BaseException:
            self.uart.close()
            raise

    def read(self):
        """Timestamp independent pages; do not claim atomic frame pairing."""
        start = time.monotonic()
        pages = {}
        for command in (3, 7, 8):
            reply = self.uart.exchange(command, self.payload)
            if (reply[0] or int.from_bytes(reply[4:12], "little") != self.epoch
                    or int.from_bytes(reply[12:16], "little") != self.session):
                raise RuntimeError("Read-only telemetry epoch/session mismatch")
            pages[command] = reply[20:32]
        frames, rows, minimum, maximum, extra, state, version = struct.unpack("<5H2B", pages[7])
        if version != 1:
            raise RuntimeError("Unsupported DVP geometry schema")
        clocks, rejected, overflows = struct.unpack("<3I", pages[8])
        flags = int.from_bytes(pages[3][:4], "little")
        return dict(now=(start+time.monotonic())/2, read_duration=time.monotonic()-start,
                    epoch=str(self.epoch), session=self.session, camera_frames_16=frames,
                    active_rows=rows, min_line_width=minimum, max_line_width=maximum,
                    extra_rows=extra, capture_state=state, schema=version,
                    sampled_clocks_32=clocks, rejected_frames=rejected, capture_overflows=overflows,
                    status_flags=flags, hdmi_underflow=bool(flags & 1024), core_fault=bool(flags & 128))

    def close(self):
        self.uart.close()


def cpu_snapshot(pids):
    """Measure interval CPU ticks, rather than process lifetime percentages."""
    cpu = {}
    for line in Path("/proc/stat").read_text().splitlines():
        fields = line.split()
        if fields[0].startswith("cpu"):
            ticks = list(map(int, fields[1:9]))
            cpu[fields[0]] = dict(total=sum(ticks), idle=ticks[3]+ticks[4])
    processes = {}
    for pid in pids:
        try:
            raw = Path(f"/proc/{pid}/stat").read_text()
            fields = raw[raw.rindex(")")+2:].split()
            processes[str(pid)] = dict(name=raw[raw.index("(")+1:raw.rindex(")")],
                                      ticks=int(fields[11])+int(fields[12]))
        except (OSError, ValueError):
            pass  # Process exit remains visible as an absent endpoint sample.
    return dict(now=time.monotonic(), cpu=cpu, processes=processes)


def cpu_delta(first, last):
    """Per-process 100 percent means one CPU core, not the whole Jetson."""
    dt = last["now"]-first["now"]
    rates = {}
    for name, b in last["cpu"].items():
        a = first["cpu"].get(name)
        if a and b["total"] > a["total"]:
            rates[name] = 100*(1-(b["idle"]-a["idle"])/(b["total"]-a["total"]))
    processes = {}
    for pid, b in last["processes"].items():
        a = first["processes"].get(pid)
        if a:
            processes[pid] = dict(name=b["name"], core_percent=100*(b["ticks"]-a["ticks"])/os.sysconf("SC_CLK_TCK")/dt)
    return dict(elapsed=dt, load_percent=rates, processes=processes)


def install_preview_audit(page):
    """Temporarily count parsed/submitted/returned live frames, without pixels."""
    page.evaluate("""() => {
      const h=window.__pangoPreviewAuditHooks={factory:PangoPreviewStream.createDecoder,
        post:Worker.prototype.postMessage,workers:new Map()};
      PangoPreviewStream.createDecoder=onFrame=>h.factory(job=>{
        const s=window.__pangoFpsAudit;
        if(s?.active){s.parsedFrames++;s.previewBytes+=job.buffer.byteLength;
          const id=BigInt(job.meta.frame_id);
          if(s.previousParsedId!==null&&id>s.previousParsedId+1n)s.streamFrameGaps+=Number(id-s.previousParsedId-1n);
          s.previousParsedId=id;}
        onFrame(job);
      });
      Worker.prototype.postMessage=function(job,...args){
        if(job?.target==='live'){
          if(!h.workers.has(this)){
            const listener=e=>{const s=window.__pangoFpsAudit;
              if(s?.active&&e.data?.target==='live'){
                if(e.data.error)s.workerErrors++;else s.returnedFrames++;}};
            h.workers.set(this,listener);this.addEventListener('message',listener);
          }
          const s=window.__pangoFpsAudit;if(s?.active)s.submittedFrames++;
        }
        return h.post.call(this,job,...args);
      };
    }""")
    # A decoder already following the stream retains its old callback. Switch
    # display mode twice to recreate only the HTTP view, leaving UDP/UVC intact.
    original = page.locator("[data-color].selected").get_attribute("data-color")
    alternate = "raw" if original != "raw" else "color"
    page.locator(f"[data-color='{alternate}']").click()
    page.wait_for_timeout(700)
    page.locator(f"[data-color='{original}']").click()


def clear_audits(page):
    """Remove diagnostic hooks on both normal completion and exceptions."""
    page.evaluate("""() => {
      const s=window.__pangoFpsAudit;
      if(s){s.active=false;cancelAnimationFrame(s.rafId);
        document.querySelector('#capture-video').cancelVideoFrameCallback(s.videoId);
        s.observer?.disconnect();delete window.__pangoFpsAudit;}
      const h=window.__pangoPreviewAuditHooks;
      if(h){PangoPreviewStream.createDecoder=h.factory;Worker.prototype.postMessage=h.post;
        for(const [w,listener] of h.workers)w.removeEventListener('message',listener);
        delete window.__pangoPreviewAuditHooks;}
    }""")


def measure(page, probe, seconds, label, pids):
    """Measure DVP and renderer independently while UDP keeps its same owner."""
    page.wait_for_timeout(2500)
    # Temporary observers measure main-thread/display scheduling, never pixels.
    page.evaluate("""() => {
      const s=window.__pangoFpsAudit={active:true,started:performance.now(),raf:0,videoCallbacks:0,lastPresented:null,
        submittedVideoFrames:0,longTasks:[],frameIntervals:[],lastVideoTime:null,
        parsedFrames:0,previewBytes:0,previousParsedId:null,streamFrameGaps:0,
        submittedFrames:0,returnedFrames:0,workerErrors:0};
      function raf(){if(!s.active)return;s.raf++;s.rafId=requestAnimationFrame(raf);}
      function video(t,m){if(!s.active)return;s.videoCallbacks++;
        if(s.lastPresented!==null)s.submittedVideoFrames+=Math.max(0,m.presentedFrames-s.lastPresented);
        s.lastPresented=m.presentedFrames;
        if(s.lastVideoTime!==null&&s.frameIntervals.length<10000)s.frameIntervals.push(t-s.lastVideoTime);
        s.lastVideoTime=t;s.videoId=document.querySelector('#capture-video').requestVideoFrameCallback(video);}
      s.rafId=requestAnimationFrame(raf);
      s.videoId=document.querySelector('#capture-video').requestVideoFrameCallback(video);
      try{s.observer=new PerformanceObserver(list=>{for(const e of list.getEntries())if(s.longTasks.length<10000)s.longTasks.push(e.duration);});s.observer.observe({entryTypes:['longtask']});}catch{}
    }""")
    board_a = probe.read()
    cpu_a = cpu_snapshot(pids)
    first = snapshot(page)
    samples = []
    started = time.monotonic()
    while time.monotonic()-started < seconds:
        page.wait_for_timeout(1000)
        samples.append(snapshot(page))
    last = samples[-1]
    cpu_b = cpu_snapshot(pids)
    board_b = probe.read()
    browser = page.evaluate("""() => {const s=window.__pangoFpsAudit;s.active=false;
      cancelAnimationFrame(s.rafId);document.querySelector('#capture-video').cancelVideoFrameCallback(s.videoId);
      s.observer?.disconnect();delete window.__pangoFpsAudit;
      return {elapsedSeconds:(performance.now()-s.started)/1000,
        raf:s.raf,videoCallbacks:s.videoCallbacks,submittedVideoFrames:s.submittedVideoFrames,
        longTasks:s.longTasks,frameIntervals:s.frameIntervals,
        preview:{parsedFrames:s.parsedFrames,previewBytes:s.previewBytes,
          streamFrameGaps:s.streamFrameGaps,submittedFrames:s.submittedFrames,
          returnedFrames:s.returnedFrames,workerErrors:s.workerErrors}};}""")
    elapsed = last["now"]-first["now"]
    counts = {k:last["counters"].get(k,0)-first["counters"].get(k,0)
              for k in set(first["counters"]) | set(last["counters"])}
    board_elapsed = board_b["now"]-board_a["now"]
    # Short bounded phases cannot span a 16-bit frame-counter wrap more than once.
    captured = (board_b["camera_frames_16"]-board_a["camera_frames_16"]) & 65535
    clocks = (board_b["sampled_clocks_32"]-board_a["sampled_clocks_32"]) & 0xffffffff
    return dict(label=label, elapsed_seconds=elapsed, before=first, after=last, samples=samples,
                board_before=board_a, board_after=board_b, board_elapsed_seconds=board_elapsed,
                dvp_frames=captured, dvp_fps=captured/board_elapsed, sampled_dvp_clock_mhz=clocks/board_elapsed/1e6,
                board_rejected_delta=(board_b["rejected_frames"]-board_a["rejected_frames"]) & 0xffffffff,
                board_overflow_delta=(board_b["capture_overflows"]-board_a["capture_overflows"]) & 0xffffffff,
                source_id_fps=(int(last["assembly"]["live_highwater"])-int(first["assembly"]["live_highwater"]))/elapsed,
                complete_fps=counts.get("live_frames_complete",0)/elapsed,
                network_canvas_fps=(int(last["canvas"].get("framesPresented",0))-int(first["canvas"].get("framesPresented",0)))/elapsed,
                hdmi_decode_fps=(last["video"]["frames"]-first["video"]["frames"])/elapsed,
                # Browser observers span the UART reads too; use their own
                # clock instead of the shorter HTTP-counter interval.
                hdmi_compositor_fps=browser["submittedVideoFrames"]/browser["elapsedSeconds"],
                display_raf_fps=browser["raf"]/browser["elapsedSeconds"], browser=browser, cpu=cpu_delta(cpu_a,cpu_b),
                delta=counts, socket_drop_delta=last["socket_drops"]-first["socket_drops"],
                unobserved_source_ids_delta=last["assembly"]["live_unobserved_ids_in_span"]-first["assembly"]["live_unobserved_ids_in_span"],
                receive_queue_replacements_delta=last["receiver_counters"].get("preview_frames_replaced",0)-first["receiver_counters"].get("preview_frames_replaced",0),
                nic_delta={k:last["nic"][k]-first["nic"][k] for k in first["nic"]},
                sampled_convert_ms_median=statistics.median(float(s["canvas"]["convertMs"]) for s in samples),
                sampled_paint_ms_median=statistics.median(float(s["canvas"]["paintMs"]) for s in samples))


def main():
    """Compare current/raw/color views, then restore the exact original mode."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--compare-modes", action="store_true")
    parser.add_argument("--audit-preview", action="store_true", help="临时计数浏览器收流、Worker提交和返回帧，并恢复诊断挂钩")
    parser.add_argument("--hdmi-ceiling", type=int, choices=(30,31,60),
                        help="临时对比浏览器 FPS 上限，结束时恢复；源 FPS 与 UVC 模式另行记录")
    parser.add_argument("--compare-hdmi-ceilings", action="store_true", help="交替比较 30/31 FPS 浏览器上限，完成后恢复")
    args = parser.parse_args()
    # Keep clock and frame modulo deltas unambiguous at the measured 84 MHz/30 FPS.
    if not 5 <= args.seconds <= 30:
        parser.error("seconds must be 5..30")
    device = linux_hagibis()
    folder = HOST / "reports" / ("frame-rate-diagnosis-"+datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    folder.mkdir()
    report = dict(utc=datetime.now(timezone.utc).isoformat(), physical_device=device, phases=[],
                  board_writes=False, source_frame_pairing="unverified", report=str(folder))
    probe = None
    try:
        probe = BoardProbe()
        with sync_playwright() as automation:
            browser = automation.chromium.connect_over_cdp(endpoint(), timeout=10000, no_defaults=True)
            report["browser_version"] = browser.version
            pages = browser.contexts[0].pages
            report["tabs"] = [dict(url=p.url, title=p.title()) for p in pages]
            page = next(p for p in pages if page_key(p.url)==page_key("http://127.0.0.1:8765/"))
            report["initial_visibility"] = page.evaluate("document.visibilityState")
            page.bring_to_front()
            if page.locator("#capture-video").evaluate("v=>v.readyState<2||!v.srcObject"):
                raise RuntimeError("Existing Hagibis preview must be active")
            if "Hagibis" not in snapshot(page)["video"]["label"]:
                raise RuntimeError("The active browser input is not the verified Hagibis")
            original = page.locator("[data-color].selected").get_attribute("data-color")
            report["original_preview_mode"] = original
            # Record the actual renderer and feature flags before considering
            # any GPU workaround; acceleration cannot be inferred from CPU load.
            browser_info = browser.new_browser_cdp_session()
            report["browser_gpu"] = browser_info.send("SystemInfo.getInfo")["gpu"]
            info = browser_info.send("SystemInfo.getProcessInfo")
            pids = [p["id"] for p in info["processInfo"]]
            report["chrome_processes"] = info["processInfo"]
            host_pid = subprocess.check_output(["systemctl","--user","show","pango-host","--property=MainPID","--value"],text=True).strip()
            pids.append(int(host_pid))
            report["host_pid"] = host_pid
            # Include desktop/remote-viewer processes without changing their
            # settings or stopping a user's remote session.
            process_rows = subprocess.check_output(["ps","-eo","pid=,comm="],text=True)
            auxiliaries = []
            for row in process_rows.splitlines():
                pid, name = row.split(maxsplit=1)
                if name.startswith("ToDesk") or name in ("gnome-shell","Xorg","codex"):
                    pids.append(int(pid))
                    auxiliaries.append(dict(pid=int(pid), name=name))
            report["auxiliary_processes"] = auxiliaries
            modes = [original] + [m for m in ("raw","color","gray") if m!=original] if args.compare_modes else [original]
            original_constraints = page.locator("#capture-video").evaluate("v=>v.srcObject.getVideoTracks()[0].getConstraints()")
            report["video_constraints_before"] = original_constraints
            # Alternate bounds in one unchanged live scene, rather than using
            # unrelated process-load windows as proof of a pacing difference.
            conditions = [(original,limit) for limit in (30,31,30,31)] if args.compare_hdmi_ceilings else [(mode,args.hdmi_ceiling) for mode in modes]
            try:
                if args.audit_preview:
                    install_preview_audit(page)
                for mode,ceiling in conditions:
                    if ceiling is not None:
                        # Test a browser constraint, never a camera/FPGA register.
                        # Preserve native geometry and the selected Hagibis stream;
                        # a higher ceiling does not prove more unique source frames.
                        changed = page.locator("#capture-video").evaluate("""async (v,max)=>{
                      const track=v.srcObject.getVideoTracks()[0];
                      await track.applyConstraints({...track.getConstraints(),frameRate:{ideal:30,max}});
                      return {constraints:track.getConstraints(),settings:track.getSettings()};
                        }""", ceiling)
                        if (changed["settings"]["width"],changed["settings"]["height"]) != (1920,1080):
                            raise RuntimeError("Constraint test changed the native capture geometry")
                    # G_FMT/G_PARM are read-only, independent of browser settings.
                    # Keep query errors visible rather than inferring the UVC mode.
                    uvc = subprocess.run([str(HOST/"build/environment/bin/v4l2-ctl"),
                        "--device",device["device_path"],"--get-fmt-video","--get-parm"],capture_output=True,text=True,timeout=5)
                    if page.locator("[data-color].selected").get_attribute("data-color")!=mode:
                        page.locator(f"[data-color='{mode}']").click()
                    label = mode if ceiling is None else f"{mode}-hdmi-ceiling-{ceiling}"
                    phase = measure(page, probe, args.seconds, label, pids)
                    phase["uvc_query"] = dict(returncode=uvc.returncode,stdout=uvc.stdout,stderr=uvc.stderr)
                    if ceiling is not None:phase["video_constraints"] = changed
                    # Save each phase immediately; a later camera failure must
                    # leave the earlier successful hardware measurements intact.
                    report["phases"].append(phase)
                    write_report(folder, report)
                    print(json.dumps({k:phase[k] for k in ("label","dvp_fps","source_id_fps","complete_fps","network_canvas_fps","hdmi_decode_fps","hdmi_compositor_fps","display_raf_fps","socket_drop_delta","board_rejected_delta","board_overflow_delta")}),flush=True)
                page.screenshot(path=str(folder/"dual-preview.png"),full_page=True)
            finally:
                # Also cancel observers if an intermediate UART/HTTP read fails.
                clear_audits(page)
                if args.hdmi_ceiling is not None or args.compare_hdmi_ceilings:
                    report["restored_video_constraints"] = page.locator("#capture-video").evaluate("""async (v,constraints)=>{
                      const track=v.srcObject.getVideoTracks()[0];await track.applyConstraints(constraints);
                      return {constraints:track.getConstraints(),settings:track.getSettings()};
                    }""", original_constraints)
                if page.locator("[data-color].selected").get_attribute("data-color")!=original:
                    page.locator(f"[data-color='{original}']").click()
                report["restored_preview_mode"] = page.locator("[data-color].selected").get_attribute("data-color")
    except Exception as error:
        report["error"] = str(error)
        raise
    finally:
        if probe:
            report["uart_records"] = probe.uart.records
            probe.close()
        write_report(folder, report)
        print("Report: "+str(folder),flush=True)
    return 0


if __name__=="__main__":
    raise SystemExit(main())

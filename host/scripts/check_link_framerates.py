"""Measure FPGA publication, kernel loss and visible previews independently.

Uses the running workbench's UART mutex and restores its live view in finally;
never resets hardware or labels UVC timestamps as unique FPGA results.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from check_hardware_inputs import api, linux_hagibis
from check_preview_performance import snapshot
from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright

HOST = Path(__file__).resolve().parents[1]
URL = "http://127.0.0.1:8765/"


def board():
    """Retry a busy UART, preserving the normal board-control ownership."""
    for attempt in range(10):
        try:
            return api("/api/board/performance")
        except RuntimeError as error:
            if "正忙" not in str(error) or attempt == 9:
                raise
            time.sleep(.2)


def main():
    """Compare visible and hidden processing without changing the HDMI track."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--seconds", type=int, default=20)
    parser.add_argument("--views", nargs="+", choices=("live", "settings"), default=["live", "settings", "live"])
    parser.add_argument("--label", default="comparison")
    parser.add_argument("--gpu-only", action="store_true", help="只读 Chromium 实际 GPU 和加速状态")
    parser.add_argument("--native-probe", action="store_true", help="增加原生轨道计数；额外消费者可能影响负载")
    args = parser.parse_args()
    if not 5 <= args.seconds <= 120:
        parser.error("seconds must be 5..120")
    folder = HOST / "reports" / ("link-framerates-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ"))
    folder.mkdir()
    report = dict(label=args.label, device=linux_hagibis(), phases=[], source_frame_pairing="unverified")
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(), no_defaults=True)
        # A WebGL API can be backed by a software rasterizer. Record Chromium's
        # actual device/features before attributing any gain to the Jetson GPU.
        diagnostics = browser.new_browser_cdp_session()
        report["gpu"] = diagnostics.send("SystemInfo.getInfo")["gpu"]
        diagnostics.detach()
        if args.gpu_only:
            (folder / "measurement.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
            print(json.dumps(report["gpu"],ensure_ascii=False),flush=True)
            return
        page = next(p for p in browser.contexts[0].pages if page_key(p.url) == page_key(URL))
        page.bring_to_front()
        # Count native deliveries without pixel copies, hashes or a new decoder.
        # The bounded processor never queues old frames behind a slow display.
        if args.native_probe:
            page.evaluate("""() => {
            const track=document.querySelector('#capture-video').srcObject?.getVideoTracks()[0];
            if(!track||track.readyState!=='live'||!track.label.includes('Hagibis'))throw Error('No live Hagibis track');
            const reader=new MediaStreamTrackProcessor({track,maxBufferSize:1}).readable.getReader();
            window.pangoRateProbe={frames:0,callbacks:0,reader,stop:false,callback:null};
            const s=window.pangoRateProbe,v=document.querySelector('#capture-video');
            const observe=()=>{if(s.stop)return;s.callbacks++;s.callback=v.requestVideoFrameCallback(observe);};
            s.callback=v.requestVideoFrameCallback(observe);
            (async()=>{try{while(!s.stop){const {done,value}=await reader.read();if(done)break;s.frames++;value.close();}}catch(e){if(!s.stop)s.error=String(e);}})();
        }""")
        try:
            for view in args.views:
                page.locator(f'nav button[data-view="{view}"]').click()
                page.wait_for_timeout(3000)
                before_board, first = board(), snapshot(page)
                first_native = page.evaluate("({frames:pangoRateProbe.frames,callbacks:pangoRateProbe.callbacks,now:performance.now()})") if args.native_probe else None
                samples = []
                start = time.monotonic()
                while time.monotonic()-start < args.seconds:
                    page.wait_for_timeout(1000)
                    samples.append(snapshot(page))
                last, after_board = samples[-1], board()
                last_native = page.evaluate("({frames:pangoRateProbe.frames,callbacks:pangoRateProbe.callbacks,now:performance.now(),error:pangoRateProbe.error})") if args.native_probe else None
                native_dt = (last_native["now"]-first_native["now"])/1000 if args.native_probe else None
                dt = last["now"]-first["now"]
                board_dt = after_board["counter_time"]-before_board["counter_time"]
                if (before_board["epoch"], before_board["session"], before_board["parameter_version"]) != (
                    after_board["epoch"], after_board["session"], after_board["parameter_version"]):
                    raise RuntimeError("FPGA identity changed during measurement")
                delta = {k:last["counters"].get(k,0)-first["counters"].get(k,0)
                         for k in set(first["counters"]) | set(last["counters"])}
                result = dict(view=view, seconds=dt,
                    hdmi_native_delivered_fps=(last_native["frames"]-first_native["frames"])/native_dt if args.native_probe else None,
                    hdmi_observed_callback_fps=(last_native["callbacks"]-first_native["callbacks"])/native_dt if args.native_probe else None,
                    fpga_result_fps=((after_board["result_published"]-before_board["result_published"]) & 0xffffffff)/board_dt,
                    # Independent physical VSYNC count; the monitor wraps at
                    # 16 bits and UART snapshots have their own timestamps.
                    camera_dvp_fps=((after_board['dvp_frame_count']-before_board['dvp_frame_count'])&0xffff)/
                        (after_board['dvp_counter_time']-before_board['dvp_counter_time'])
                        if before_board.get('dvp_frame_count') is not None and after_board.get('dvp_frame_count') is not None else None,
                    raw_complete_fps=delta.get("live_frames_complete",0)/dt,
                    network_canvas_fps=(int(last["canvas"].get("framesPresented",0))-int(first["canvas"].get("framesPresented",0)))/dt,
                    hdmi_browser_total_fps=(last["video"]["frames"]-first["video"]["frames"])/dt,
                    hdmi_preview_callback_fps=(last['video']['observed']-first['video']['observed'])/dt,
                    socket_drops=last["socket_drops"]-first["socket_drops"],
                    nic_delta={k:last["nic"][k]-first["nic"][k] for k in first["nic"]},
                    delta=delta, before=first, after=last, samples=samples,
                    before_board=before_board, after_board=after_board)
                report["phases"].append(result)
                (folder / "measurement.json").write_text(json.dumps(report,ensure_ascii=False,indent=2)+"\n",encoding="utf-8")
                print(json.dumps({k:v for k,v in result.items() if k not in ("before","after","samples","before_board","after_board","delta")},ensure_ascii=False),flush=True)
        finally:
            if args.native_probe:
                page.evaluate("""async()=>{const s=window.pangoRateProbe;s.stop=true;
                document.querySelector('#capture-video').cancelVideoFrameCallback(s.callback);
                await s.reader.cancel();delete window.pangoRateProbe;}""")
            page.locator('nav button[data-view="live"]').click()
    print("Report: "+str(folder),flush=True)


if __name__ == "__main__":
    main()

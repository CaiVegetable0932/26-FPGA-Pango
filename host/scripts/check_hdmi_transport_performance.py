"""Compare Hagibis native MJPEG transport and installed Jetson decoding.

Temporarily release the browser's exact selected card and restore it in finally.
Never reset USB, change power management, or use a different camera. Evidence
stays local in host/data and host/reports; no decoded frames prove FPGA pairing.
"""
from datetime import datetime, timezone
import argparse
import json
from pathlib import Path
import subprocess
import time

from check_hardware_inputs import api, linux_hagibis
from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright

HOST = Path(__file__).resolve().parents[1]
URL = "http://127.0.0.1:8765/"


def main():
    """Copy original 1080p MJPEG, then test the available native JPEG decoder."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restore-only',action='store_true',help='只恢复此前保存的 Hagibis 网页预览')
    args = parser.parse_args()
    name = "hdmi-transport-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report_dir, data_dir = HOST / "reports" / name, HOST / "data" / name
    report_dir.mkdir(); data_dir.mkdir()
    device = linux_hagibis()
    report = dict(device=device, source_frame_pairing="unverified", tests={})
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(), no_defaults=True)
        page = next(p for p in browser.contexts[0].pages if page_key(p.url) == page_key(URL))
        page.bring_to_front()
        page.locator('nav button[data-view="live"]').click()
        if args.restore_only:
            if not page.locator('#capture-video').evaluate("v=>v.srcObject?.getVideoTracks()[0]?.readyState==='live'"):
                page.locator('#capture-preview-open').click()
            page.wait_for_function("() => document.querySelector('#capture-video').srcObject?.getVideoTracks()[0]?.readyState==='live'",timeout=30000)
            print('Saved Hagibis preview restored',flush=True)
            return
        settings = page.locator('#capture-video').evaluate("v=>({settings:v.srcObject?.getVideoTracks()[0]?.getSettings(),label:v.srcObject?.getVideoTracks()[0]?.label})")
        if settings.get("label") != "Hagibis" or settings["settings"]["width"] != 1920 or settings["settings"]["height"] != 1080:
            raise RuntimeError("Expected existing native 1080p Hagibis track")
        report["browser_before"] = settings
        page.locator('#capture-preview-close').click()
        page.wait_for_function("() => !document.querySelector('#capture-video').srcObject")
        try:
            page.wait_for_timeout(1000)
            before = api('/api/status')
            start = time.monotonic()
            run = subprocess.run([str(HOST/'build/environment/bin/ffmpeg'), '-hide_banner', '-nostdin',
                '-f','v4l2','-input_format','mjpeg','-framerate','30','-video_size','1920x1080',
                '-i',device['device_path'],'-t','10','-an','-c:v','copy',str(data_dir/'transport.mkv')],
                capture_output=True,text=True,timeout=30)
            elapsed = time.monotonic()-start
            (report_dir/'copy.log').write_text(run.stderr,encoding='utf-8')
            if run.returncode:
                raise RuntimeError('MJPEG transport failed; see '+str(report_dir/'copy.log'))
            probe = subprocess.run([str(HOST/'build/environment/bin/ffprobe'),'-v','error','-count_packets',
                '-show_entries','stream=width,height,nb_read_packets,avg_frame_rate:format=duration',
                '-of','json',str(data_dir/'transport.mkv')],capture_output=True,text=True,check=True,timeout=15)
            transport = json.loads(probe.stdout)
            frames = int(transport['streams'][0]['nb_read_packets'])
            duration = float(transport['format']['duration'])
            after = api('/api/status')
            report['tests']['mjpeg_copy'] = dict(frames=frames,duration=duration,fps=frames/duration,
                wall_seconds=elapsed,probe=transport,
                raw_complete_delta=after['metrics']['assembly']['counters'].get('live_frames_complete',0)-before['metrics']['assembly']['counters'].get('live_frames_complete',0))
            print(json.dumps(report['tests']['mjpeg_copy']),flush=True)
            # Startup UVC corruption/settling is retained in the file. Count
            # the later original packet timestamps separately from its mean.
            packets = subprocess.run([str(HOST/'build/environment/bin/ffprobe'),'-v','error',
                '-show_packets','-show_entries','packet=pts_time','-of','json',str(data_dir/'transport.mkv')],
                capture_output=True,text=True,check=True,timeout=15)
            times = [float(p['pts_time']) for p in json.loads(packets.stdout)['packets']]
            steady = [t for t in times if t >= 2]
            report['tests']['mjpeg_copy']['steady_packets'] = len(steady)
            report['tests']['mjpeg_copy']['steady_fps'] = (len(steady)-1)/(steady[-1]-steady[0]) if len(steady)>1 else None
            # Installed plugin introspection precedes the test. Pipeline state
            # and all output stay project-local; fakesink performs no preview.
            subprocess.run(['gst-inspect-1.0','nvjpegdec'],stdout=subprocess.DEVNULL,check=True,timeout=10)
            start = time.monotonic()
            try:
                # Isolate decoding from UVC allocation/caps changes: use the
                # untouched local packets and the installed JPEG parser.
                run = subprocess.run(['gst-launch-1.0','-e','filesrc','location='+str(data_dir/'transport.mkv'),
                    '!','matroskademux','!','jpegparse','!','nvjpegdec','!','fakesink','sync=false'],
                    capture_output=True,text=True,timeout=20)
            except subprocess.TimeoutExpired as error:
                run = subprocess.CompletedProcess([],124,(error.stdout or b'').decode(errors='replace'),
                    (error.stderr or b'').decode(errors='replace')+'\nDecoder timed out; no driver changes attempted.')
            elapsed = time.monotonic()-start
            (report_dir/'nvjpeg.log').write_text(run.stdout+'\n'+run.stderr,encoding='utf-8')
            report['tests']['nvjpeg_decode'] = dict(returncode=run.returncode,wall_seconds=elapsed,
                input_packets=frames,wall_fps=frames/elapsed if run.returncode == 0 else None,
                note='Wall interval includes startup; fakesink does not prove browser display.')
            print(json.dumps(report['tests']['nvjpeg_decode']),flush=True)
        finally:
            report_dir.joinpath('measurement.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
            page.locator('#capture-preview-open').click()
            page.wait_for_function("() => document.querySelector('#capture-video').srcObject?.getVideoTracks()[0]?.readyState==='live'",timeout=30000)
            page.locator('nav button[data-view="live"]').click()
    print('Report: '+str(report_dir),flush=True)


if __name__ == '__main__':
    main()

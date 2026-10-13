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
import re

from check_hardware_inputs import api, linux_hagibis
from open_browser import endpoint, page_key
from playwright.sync_api import sync_playwright

HOST = Path(__file__).resolve().parents[1]
URL = "http://127.0.0.1:8765/"


def main():
    """Copy original 1080p MJPEG, then test the available native JPEG decoder."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--restore-only',action='store_true',help='只恢复此前保存的 Hagibis 网页预览')
    parser.add_argument('--seconds',type=int,default=10,help='原始 MJPEG 传输窗口，5..120 秒')
    parser.add_argument('--decoder',choices=('nvjpegdec','nvv4l2decoder'),default='nvjpegdec')
    parser.add_argument('--live-decode',action='store_true',help='另外测试原生实时解码至 fakesink，不接回网页')
    args = parser.parse_args()
    if not 5 <= args.seconds <= 120:
        parser.error('seconds must be 5..120')
    name = "hdmi-transport-" + datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S%fZ")
    report_dir, data_dir = HOST / "reports" / name, HOST / "data" / name
    report_dir.mkdir(); data_dir.mkdir()
    device = linux_hagibis()
    report = dict(device=device, source_frame_pairing="unverified", tests={})
    with sync_playwright() as automation:
        browser = automation.chromium.connect_over_cdp(endpoint(), no_defaults=True)
        page = next(p for p in browser.contexts[0].pages if page_key(p.url) == page_key(URL))
        # Use the real DOM handler without pointer/focus waits on an occluded
        # remote desktop; this experiment measures transport, not UI latency.
        def click(selector):
            page.evaluate("s=>document.querySelector(s).click()",selector)
        def wait_track(opened):
            # Direct snapshots stay reliable when injected browser pollers
            # time out even though a Hagibis track has actually resumed.
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                state=page.evaluate("()=>{const v=document.querySelector('#capture-video');return {present:!!v.srcObject,live:v.srcObject?.getVideoTracks()[0]?.readyState==='live'}}")
                if state["live"] if opened else not state["present"]:
                    return
                time.sleep(.1)
            raise RuntimeError("Hagibis track did not "+("resume" if opened else "release"))
        click('nav button[data-view="live"]')
        if args.restore_only:
            if not page.evaluate("()=>document.querySelector('#capture-video').srcObject?.getVideoTracks()[0]?.readyState==='live'"):
                click('#capture-preview-open')
            wait_track(True)
            print('Saved Hagibis preview restored',flush=True)
            return
        settings = page.evaluate("()=>{const v=document.querySelector('#capture-video');return {settings:v.srcObject?.getVideoTracks()[0]?.getSettings(),label:v.srcObject?.getVideoTracks()[0]?.label}}")
        if settings.get("label") != "Hagibis" or settings["settings"]["width"] != 1920 or settings["settings"]["height"] != 1080:
            raise RuntimeError("Expected existing native 1080p Hagibis track")
        report["browser_before"] = settings
        click('#capture-preview-close')
        wait_track(False)
        try:
            time.sleep(1)
            before = api('/api/status')
            start = time.monotonic()
            run = subprocess.run([str(HOST/'build/environment/bin/ffmpeg'), '-hide_banner', '-nostdin',
                '-f','v4l2','-input_format','mjpeg','-framerate','30','-video_size','1920x1080',
                '-i',device['device_path'],'-t',str(args.seconds),'-an','-c:v','copy',str(data_dir/'transport.mkv')],
                capture_output=True,text=True,timeout=args.seconds+30)
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
            inspected=subprocess.run(['gst-inspect-1.0',args.decoder],capture_output=True,text=True,check=True,timeout=10)
            (report_dir/(args.decoder+'-plugin.txt')).write_text(inspected.stdout)
            property_name='mjpegdecode' if args.decoder=='nvjpegdec' else 'mjpeg'
            if property_name not in inspected.stdout or 'image/jpeg' not in inspected.stdout:
                raise RuntimeError('Installed decoder does not confirm MJPEG support')
            # Inspect the locally installed plugin before selecting the MJPEG
            # property. Count actual identity outputs, not just input packets.
            tail=['!','jpegparse','!',args.decoder,property_name+'=true',
                  '!','identity','name=decoded','silent=false','!','fakesink','sync=false']
            sources=[('file_decode',['filesrc','location='+str(data_dir/'transport.mkv'),'!','matroskademux'],max(30,args.seconds*2))]
            if args.live_decode:
                sources.append(('live_decode',['v4l2src','device='+device['device_path'],'io-mode=2',
                    'num-buffers='+str(args.seconds*30),'!','image/jpeg,width=1920,height=1080,framerate=30/1'],args.seconds*2+30))
            for name,source,timeout in sources:
                start=time.monotonic()
                command=['gst-launch-1.0','-e','-v',*source,*tail]
                try:
                    run=subprocess.run(command,capture_output=True,text=True,timeout=timeout)
                except subprocess.TimeoutExpired as error:
                    run=subprocess.CompletedProcess(command,124,(error.stdout or b'').decode(errors='replace'),
                        (error.stderr or b'').decode(errors='replace')+'\nDecoder timed out; no driver changes attempted.')
                elapsed=time.monotonic()-start
                (report_dir/(name+'.log')).write_text(run.stdout+'\n'+run.stderr,encoding='utf-8')
                decoded=len(re.findall(r'GstIdentity:decoded: last-message = chain',run.stdout))
                report['tests'][name]=dict(decoder=args.decoder,command=command,returncode=run.returncode,
                    wall_seconds=elapsed,decoded_outputs=decoded,input_packets=frames if name=='file_decode' else None,
                    decoded_wall_fps=decoded/elapsed if decoded else None,
                    note='Diagnostic identity notifications add overhead. Native fakesink is not browser or optical acceptance.')
                print(json.dumps(report['tests'][name]),flush=True)
        finally:
            report_dir.joinpath('measurement.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
            click('#capture-preview-open')
            wait_track(True)
            click('nav button[data-view="live"]')
    print('Report: '+str(report_dir),flush=True)


if __name__ == '__main__':
    main()

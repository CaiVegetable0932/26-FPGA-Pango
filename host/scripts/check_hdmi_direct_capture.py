"""Isolate compressed V4L2 content from Chromium and remote-desktop display.

Briefly release only the saved Hagibis preview, record native 1080p30/MJPEG
with two mmap buffers, and reopen that exact saved browser device in finally.
No board, USB reset, module loading, OS power/clock or network changes occur.
"""
from datetime import datetime,timezone
import json
from pathlib import Path
import re
import subprocess
import time
from check_hardware_inputs import api,linux_hagibis
from open_browser import endpoint,page_key
from playwright.sync_api import sync_playwright

HOST=Path(__file__).resolve().parents[1]


def run(command,folder,name,timeout=30):
    """Bound our own capture child and retain complete diagnostic logs."""
    result=subprocess.run([str(x) for x in command],capture_output=True,timeout=timeout)
    (folder/(name+'.stdout.log')).write_bytes(result.stdout)
    (folder/(name+'.stderr.log')).write_bytes(result.stderr)
    if result.returncode:raise RuntimeError(name+' failed; see logs')
    return result


def main():
    device=linux_hagibis();folder=HOST/'reports/hdmi-latency-20261006';data=HOST/'data/hdmi-latency-20261006/direct-v4l2'
    folder.mkdir(parents=True,exist_ok=True);data.mkdir(parents=True,exist_ok=True)
    report=dict(utc=datetime.now(timezone.utc).isoformat(),device=device,board_before=api('/api/board/status'),
                source_frame_id=None,pairing_status='unverified',requested_size=[1920,1080],requested_fps=30)
    saved_track=None
    try:
        with sync_playwright() as p:
            browser=p.chromium.connect_over_cdp(endpoint(),no_defaults=True)
            pages=[pg for c in browser.contexts for pg in c.pages if page_key(pg.url)==page_key('http://127.0.0.1:8765/')]
            if len(pages)!=1:raise RuntimeError('Expected one existing workbench')
            page=pages[0]
            saved_track=page.evaluate('''() => {
              const t=document.getElementById('capture-video').srcObject?.getVideoTracks()[0];
              if(!t||t.label!=='Hagibis')throw Error('Hagibis preview is not open');
              return {label:t.label,settings:t.getSettings()};
            }''')
            if (saved_track['settings']['width'],saved_track['settings']['height'])!=(1920,1080):
                raise RuntimeError('Existing capture is not native 1080p; refusing implicit mode change')
            report['browser_before']=saved_track
            # Remove disposable display probes, not the workbench or other tabs.
            page.evaluate('''async () => {window.__pangoHdmiCanvasTrial?.stop();await window.__pangoHdmiLatestTrial?.stop();}''')
            try:
                page.locator('#capture-preview-close').click()
                page.wait_for_function("() => !document.getElementById('capture-video').srcObject")
                deadline=time.monotonic()+5
                while subprocess.run(['fuser',device['resolved_path']],capture_output=True).returncode!=1:
                    if time.monotonic()>deadline:raise RuntimeError('Capture node is still owned; no external process was killed')
                    page.wait_for_timeout(200)
                output=data/'native-1080p30.mjpeg'
                command=[HOST/'build/environment/bin/v4l2-ctl','-d',device['device_path'],
                    '--set-fmt-video=width=1920,height=1080,pixelformat=MJPG','--set-parm=30',
                    '--stream-mmap=2','--stream-count=150','--stream-poll','--stream-show-delta-now','--verbose','--stream-to='+str(output)]
                report['command']=[str(c) for c in command];start=time.monotonic()
                run(command,data,'capture',timeout=15);report['capture_elapsed']=time.monotonic()-start
                report['compressed_file']=str(output.relative_to(HOST))
            finally:
                # Always restore the actual saved card without refreshing USB,
                # rebooting the FPGA or changing network reception.
                page.locator('#capture-preview-open').click()
                page.wait_for_function("() => document.getElementById('capture-video').srcObject?.getVideoTracks()[0]?.readyState==='live'",timeout=45000)
                after=page.locator('#capture-video').evaluate("v=>({label:v.srcObject.getVideoTracks()[0].label,settings:v.srcObject.getVideoTracks()[0].getSettings()})")
                assert after['label']=='Hagibis' and after['settings']['deviceId']==saved_track['settings']['deviceId']
                assert (after['settings']['width'],after['settings']['height'])==(1920,1080)
                report['browser_restored']=after
        # Decode stored bytes after capture and UI recovery, so codec load does
        # not influence the direct transport measurement.
        probe=run([HOST/'build/environment/bin/ffprobe','-v','error','-f','mjpeg','-show_packets',
                   '-show_data_hash','sha256','-show_entries','packet=pts_time,size,data_hash,pos','-of','json',output],data,'packets')
        packets=json.loads(probe.stdout)['packets']
        hashes=[p['data_hash'] for p in packets]
        run([HOST/'build/environment/bin/ffmpeg','-hide_banner','-v','error','-threads','1','-f','mjpeg','-i',output,
             '-an','-pix_fmt','gray','-threads','1','-f','framehash','-hash','sha256',data/'decoded-framehash.txt'],data,'decode')
        decoded=[row.rsplit(',',1)[-1].strip() for row in (data/'decoded-framehash.txt').read_text().splitlines() if row and not row.startswith('#')]
        report['summary']=dict(packet_count=len(packets),unique_compressed_frames=len(set(hashes)),
            compressed_adjacent_repeats=sum(a==b for a,b in zip(hashes,hashes[1:])),
            decoded_frames=len(decoded),unique_decoded_gray_frames=len(set(decoded)),
            decoded_adjacent_repeats=sum(a==b for a,b in zip(decoded,decoded[1:])),
            capture_fps=len(packets)/report['capture_elapsed'],
            note='Content duplicates are not inferred sensor frame IDs; static scenes alone cannot prove source drops')
        report['packets']=packets;report['passed']=True
    except BaseException as error:
        report['passed']=False;report['error']=str(error);raise
    finally:
        report['board_after']=api('/api/board/status')
        (folder/'direct-v4l2.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    print(json.dumps(dict(summary=report['summary'],browser_restored=report.get('browser_restored'),report=str(folder/'direct-v4l2.json')),ensure_ascii=False,indent=2))


if __name__=='__main__':main()

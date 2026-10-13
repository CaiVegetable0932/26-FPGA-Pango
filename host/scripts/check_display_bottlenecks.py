"""Isolate actual display load without resetting hardware or power settings.

Compare receive-only in a hidden view, visible RAW only, both visible previews
and hidden HDMI decoding. Preserve the user's capture/mode/view in finally.
All evidence stays local; UVC delivery does not prove unique FPGA results.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from check_hardware_inputs import linux_hagibis
from check_link_framerates import board
from check_preview_performance import snapshot, source_version
from browser_probe import BrowserProbe

HOST=Path(__file__).resolve().parents[1]
URL="http://127.0.0.1:8765/"


def cpu_snapshot():
    """Read interval CPU work, not lifetime ps percentages or private argv."""
    result={}
    for path in Path('/proc').glob('[0-9]*/stat'):
        try:
            text=path.read_text();end=text.rindex(')');fields=text[end+2:].split()
            result[path.parent.name]=dict(name=text[text.index('(')+1:end],
                ticks=int(fields[11])+int(fields[12]))
        except (OSError,ValueError,IndexError):
            continue
    return result


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=int,default=20)
    parser.add_argument('--phases',nargs='+',choices=('idle','network','dual','hidden_decode'),
                        default=['idle','network','dual','hidden_decode','dual','network'])
    args=parser.parse_args()
    if not 5<=args.seconds<=120:parser.error('seconds must be 5..120')
    folder=HOST/'reports'/('display-bottlenecks-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    folder.mkdir()
    report=dict(device=linux_hagibis(),source_version=source_version(),phases=[],
                source_frame_pairing='unverified',scope='software_delivery_not_optical_latency')
    def save():
        (folder/'measurement.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n')
    # WebSocket image payloads must not be duplicated into debug traffic.
    # A lightweight Runtime-only observer avoids that measurement bias.
    with BrowserProbe() as page:
        gpu=page.system_info()['gpu']
        report['network_monitoring_enabled']=False
        report['gpu']={k:gpu.get(k) for k in ('devices','featureStatus','auxAttributes')}
        saved=page.evaluate("""() => ({view:document.querySelector('nav .active').dataset.view,
          mode:document.querySelector('[data-color].selected').dataset.color,
          capture:!!document.querySelector('#capture-video').srcObject})""")
        def click(selector):
            page.evaluate('s=>document.querySelector(s).click()',selector)
        def capture(opened):
            present=page.evaluate("()=>!!document.querySelector('#capture-video').srcObject")
            if present!=opened:click('#capture-preview-'+('open' if opened else 'close'))
            deadline=time.monotonic()+30
            while time.monotonic()<deadline:
                s=page.evaluate("""()=>{const v=document.querySelector('#capture-video');return {
                  present:!!v.srcObject,live:v.srcObject?.getVideoTracks()[0]?.readyState==='live',
                  ready:v.readyState,label:v.srcObject?.getVideoTracks()[0]?.label}}""")
                if (s.get('live') and s['ready']>=2) if opened else not s['present']:
                    if opened and s['label']!='Hagibis':raise RuntimeError('Wrong capture device')
                    return
                time.sleep(.1)
            raise RuntimeError('Capture did not '+('open' if opened else 'release'))
        try:
            for phase in args.phases:
                print('Starting '+phase,flush=True)
                capture(phase in ('dual','hidden_decode'))
                click('nav button[data-view="'+('live' if phase in ('network','dual') else 'settings')+'"]')
                time.sleep(3)
                before_board=board();first=snapshot(page);cpu0=cpu_snapshot();samples=[]
                start=time.monotonic()
                while time.monotonic()-start<args.seconds:
                    time.sleep(1);samples.append(snapshot(page))
                last=samples[-1];cpu1=cpu_snapshot();after_board=board()
                dt=last['now']-first['now']
                if first['run_id']!=last['run_id'] or any((s['run_id'],s['config']['stream_epoch'])!=
                    (first['run_id'],first['config']['stream_epoch']) for s in samples):
                    raise RuntimeError('Receive session changed during comparison')
                if any(after_board[k]!=before_board[k] for k in ('epoch','session','parameter_version')):
                    raise RuntimeError('FPGA session changed during comparison')
                delta={k:last['counters'].get(k,0)-first['counters'].get(k,0)
                       for k in set(first['counters'])|set(last['counters'])}
                # Each board counter uses its own UART sampling time and wrap.
                rates=dict(receive_fps=delta.get('live_frames_complete',0)/dt,
                    canvas_fps=(int(last['canvas'].get('framesPresented',0))-int(first['canvas'].get('framesPresented',0)))/dt,
                    hdmi_total_fps=(last['video']['frames']-first['video']['frames'])/dt,
                    hdmi_callback_fps=(last['video']['observed']-first['video']['observed'])/dt,
                    fpga_result_fps=((after_board['result_published']-before_board['result_published'])&0xffffffff)/
                        (after_board['counter_time']-before_board['counter_time']),
                    camera_dvp_fps=((after_board['dvp_frame_count']-before_board['dvp_frame_count'])&0xffff)/
                        (after_board['dvp_counter_time']-before_board['dvp_counter_time']))
                import os
                hz=os.sysconf('SC_CLK_TCK')
                cpu=sorted([dict(pid=k,name=v['name'],cpu_percent=100*(v['ticks']-cpu0[k]['ticks'])/hz/dt)
                            for k,v in cpu1.items() if k in cpu0],key=lambda v:v['cpu_percent'],reverse=True)[:15]
                value=dict(phase=phase,seconds=dt,**rates,socket_drops=last['socket_drops']-first['socket_drops'],
                    delta=delta,cpu=cpu,before=first,after=last,samples=samples,
                    before_board=before_board,after_board=after_board)
                report['phases'].append(value);save()
                print(json.dumps({k:v for k,v in value.items() if k not in
                    ('before','after','samples','before_board','after_board','delta','cpu')},ensure_ascii=False),flush=True)
        except Exception as error:
            report['error']=str(error);save();raise
        finally:
            # The experiment owns only temporary browser display state. Keep
            # the receiver, geometry parameters, UART and original archives.
            try:
                capture(saved['capture'])
                click('[data-color="'+saved['mode']+'"]')
                click('nav button[data-view="'+saved['view']+'"]')
                report['restored']=saved
            except Exception as error:
                report['restore_error']=str(error)
            report['source_unchanged']=report['source_version']==source_version();save()
    print('Report: '+str(folder),flush=True)
    return 1 if report.get('error') or report.get('restore_error') else 0


if __name__=='__main__':raise SystemExit(main())

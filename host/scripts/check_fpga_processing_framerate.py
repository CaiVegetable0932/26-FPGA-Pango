"""Measure physical input versus FPGA result cadence through the owned UART.

The optional original/corrected comparison changes only the existing FPGA
display-mode control and restores it in finally. No reset, parameter upload,
Flash, power or USB configuration is touched. Reports stay in host/reports.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time

from check_hardware_inputs import api
from check_link_framerates import board

HOST=Path(__file__).resolve().parents[1]


def control(route,data=None):
    """Retry only pre-transaction UART contention with the normal Web owner."""
    for attempt in range(10):
        try:return api(route,data)
        except RuntimeError as error:
            if '正忙' not in str(error) or attempt==9:raise
            time.sleep(.2)


def main():
    """Keep source identity, wrapped counters and actual sampling times distinct."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--seconds',type=int,default=20)
    parser.add_argument('--compare-original',action='store_true')
    args=parser.parse_args()
    if not 5<=args.seconds<=120:parser.error('seconds must be 5..120')
    folder=HOST/'reports'/('fpga-processing-fps-'+datetime.now(timezone.utc).strftime('%Y%m%dT%H%M%S%fZ'))
    folder.mkdir()
    # Refuse missing source diagnostics before making even a temporary mode
    # change; an unsupported counter must not be treated as zero input FPS.
    if board().get('dvp_frame_count') is None:
        raise RuntimeError('Firmware does not expose independent DVP diagnostics (CAPS 0x40)')
    previous=control('/api/board/view')
    report=dict(previous_view=previous,phases=[],source_frame_pairing='unverified')
    try:
        for mode in (['original','corrected'] if args.compare_original else [previous['mode']]):
            if args.compare_original:
                control('/api/board/view',dict(mode=mode,markers=False,diameter=previous['diameter']))
                time.sleep(2)
            first=board();samples=[];start=time.monotonic()
            while time.monotonic()-start<args.seconds:
                time.sleep(1);samples.append(board())
            last=samples[-1]
            if any((s['epoch'],s['session'],s['parameter_version']) != (first['epoch'],first['session'],first['parameter_version']) for s in samples):
                raise RuntimeError('FPGA session/parameters changed; comparison invalid')
            phase=dict(mode=mode,
                fpga_result_fps=((last['result_published']-first['result_published'])&0xffffffff)/(last['counter_time']-first['counter_time']),
                camera_dvp_fps=((last['dvp_frame_count']-first['dvp_frame_count'])&0xffff)/(last['dvp_counter_time']-first['dvp_counter_time']),
                capture_rejected_delta=(last['capture_rejected']-first['capture_rejected'])&0xffffffff,
                capture_overflows_delta=(last['capture_overflows']-first['capture_overflows'])&0xffffffff,
                faults=sorted(set(s['fault_bits'] for s in [first]+samples)),
                before=first,after=last,samples=samples)
            report['phases'].append(phase)
            print(json.dumps({k:v for k,v in phase.items() if k not in ('before','after','samples')},ensure_ascii=False),flush=True)
    finally:
        try:
            if args.compare_original:
                report['restored_view']=control('/api/board/view',{k:previous[k] for k in ('mode','markers','diameter')})
        except Exception as error:
            report['restore_error']=str(error)
            raise
        finally:
            # Preserve measurements even if physical disconnect prevents mode
            # restoration, and never report that failure as a successful test.
            folder.joinpath('measurement.json').write_text(json.dumps(report,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
    print('Report: '+str(folder),flush=True)


if __name__=='__main__':main()

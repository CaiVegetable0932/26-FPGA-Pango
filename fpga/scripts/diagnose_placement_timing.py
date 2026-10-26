"""Inspect completed PLC timing paths without claiming routed timing signoff.

The installed PDS report_timing command accepts an explicit design database.
These copied placement inputs have no completed data routing: their reported
net delays and slack must never authorize bitgen or replace routed min/max STA.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from route_supervisor import run_supervised


def sha(path):
    """Check that native diagnosis leaves the frozen evidence untouched."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Run isolated reports sequentially; preserve exact inputs and native logs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', action='append', type=Path, required=True)
    parser.add_argument('--timeout-minutes', type=int, default=15,
                        help='Bounded isolated diagnostic phase, never routed signoff')
    args = parser.parse_args()
    if not 1 <= args.timeout_minutes <= 60:
        parser.error('diagnostic timeout must be 1..60 minutes')
    fpga = Path(__file__).resolve().parents[1]
    root = fpga / 'build/full_integration_20261013' / datetime.now().strftime('placement_timing_%Y%m%d_%H%M%S_%f')
    root.mkdir()
    shutil.copyfile(__file__, root / 'diagnosis_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'), root / 'route_supervisor.py')
    results = []
    for original in args.build:
        original = original.resolve()
        if not original.is_relative_to(fpga / 'build'):
            raise ValueError('input must be a completed FPGA build')
        placement = original / 'place_route/pango_video_system_plc.adf'
        if Path(str(placement)+'.lock').exists():
            raise ValueError('placement is still being written')
        manifest = json.loads((original / 'sources.json').read_text(encoding='utf-8'))
        intact = lambda: all(sha(original / 'source' / n) == h for n,h in manifest.items())
        if not intact():
            raise ValueError('frozen sources changed')
        target = root / original.name
        target.mkdir()
        expected = sha(placement)
        copy = target / placement.name
        shutil.copyfile(placement, copy)
        assert sha(copy) == expected == sha(placement)
        # Change only the diagnostic output directory. All original design/IP
        # registrations and ordered constraints still reference frozen sources.
        flow = (original / 'flow.tcl').read_text(encoding='utf-8').split('\ncompile ',1)[0]+'\n'
        flow = re.sub(r'^set_dir -impl_directory .*$',
                      lambda _: 'set_dir -impl_directory {'+target.as_posix()+'}', flow, flags=re.M)
        flow += 'add_constraint {'+(original/'device_map/pango_video_system.pcf').as_posix()+'}\n'
        flow += ('report_timing -force_to_run -input_db_file {'+copy.as_posix()+
                 '} -delay_type min_max -max_path 30 -report_exception TRUE\n')
        script = target / 'diagnostic.tcl'
        script.write_text(flow, encoding='utf-8')
        log_path = target / 'native.log'
        print('PLC_TIMING_DIAGNOSTIC', target, flush=True)
        # Even read-only checkpoint diagnosis uses the shared native slot and
        # bounded owned-process supervision; never overlap another PDS phase.
        supervision = run_supervised(
            ['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
             '-file',str(script),'-work_dir',str(target)], cwd=target,
            log_path=log_path, monitor_path=target/'native_monitor.jsonl',
            timeout_seconds=args.timeout_minutes*60)
        child = subprocess.CompletedProcess([], supervision['returncode'])
        content = log_path.read_text(errors='replace')
        result = dict(original=str(original), output=str(target), native_exit=child.returncode,
                      errors=re.findall(r'^E:.*',content,re.M), plc_sha256=expected,
                      plc_intact=sha(placement)==expected and sha(copy)==expected,
                      sources_intact=intact(), routed=False, timing_signoff=False,
                      bitstream_generated=False, programmed=False, supervision=supervision)
        results.append(result)
        (root/'result.json').write_text(json.dumps(results,indent=2),encoding='utf-8')
        print(json.dumps(result),flush=True)
        if supervision['status']!='COMPLETED' or child.returncode or result['errors'] or not result['plc_intact'] or not result['sources_intact']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()

"""Compare native SYN resources for image controls with immutable source copies.

Installed PDS 2022.2-SP6.4 ADS Synthesis User Guide PDF page50 documents the
compile/synthesize shell flow. Device/package/options match the board script.
Abstract ports measure logic only; no route, timing or hardware claim follows.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil

from route_supervisor import run_supervised


def main():
    """Freeze all baseline/current jobs before sequentially acquiring the lock."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--source', type=Path)
    parser.add_argument('--top', choices=['isp_colour_control', 'tone_entity_control', 'camera_brightness_control'])
    parser.add_argument('--trusted-lut', action='store_true', help='Specialize tone as the verified board UART-only consumer')
    parser.add_argument('--compare-baseline', type=Path)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    roots = [('current', (args.source or fpga).resolve())]
    if args.compare_baseline:
        roots.insert(0, ('baseline', args.compare_baseline.resolve()))
    run = fpga / 'build/image_resource_probes' / datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    shutil.copyfile(__file__, run/'probe_script.py')
    modules = {
        'isp_colour_control': ['rtl/isp/isp_colour_control.sv'],
        'tone_entity_control': ['rtl/geometry/tone_entity_control.sv', 'rtl/geometry/tone_builtin_lut.sv'],
        'camera_brightness_control': ['rtl/input/camera_brightness_control.sv'],
    }
    jobs = []
    for label, origin in roots:
        if not origin.is_relative_to(fpga):
            raise ValueError('source must remain within FPGA development area')
        for top, names in modules.items():
            if args.top and top != args.top:
                continue
            job = run/label/top
            source = job/'source'
            source.mkdir(parents=True)
            hashes = {}
            for name in names:
                target = source/Path(name).name
                shutil.copyfile(origin/name, target)
                # Explicit board specialization, retained in the immutable hash
                # and result. Baseline independent-consumer probes stay default.
                if args.trusted_lut and top == 'tone_entity_control' and target.name == 'tone_entity_control.sv':
                    text = target.read_text(encoding='utf-8')
                    if 'parameter LUT_PREVALIDATED=0' not in text:
                        raise ValueError('source does not implement the trusted LUT contract')
                    target.write_text(text.replace('parameter LUT_PREVALIDATED=0', 'parameter LUT_PREVALIDATED=1'), encoding='utf-8')
                hashes[target.name] = hashlib.sha256(target.read_bytes()).hexdigest()
            (job/'sources.json').write_text(json.dumps(hashes, indent=2))
            clocks = 'create_clock -name control -period 8.0 [get_ports clk]\n'
            if top == 'tone_entity_control':
                clocks += 'create_clock -name processing -period 6.666 [get_ports processing_clk]\n'
            (job/'clock.fdc').write_text(clocks)
            flow = f'set_dir -impl_directory {{{job.as_posix()}}}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow += ''.join(f'add_design {{{(source/Path(n).name).as_posix()}}}\n' for n in names)
            flow += f'add_constraint {{{(job/"clock.fdc").as_posix()}}}\ncompile -top_module {top} -system_verilog\n'
            flow += 'synthesize -ads -disable_io_insertion -rw_check_on_ram -resource_sharing false -fanout_guide 64 -selected_syn_tool_opt 2\n'
            (job/'flow.tcl').write_text(flow)
            jobs.append((label, top, origin, job, hashes))
    print('IMAGE_RESOURCE_PROBE', run, flush=True)
    results = []
    for label, top, origin, job, hashes in jobs:
        supervision = run_supervised([
            'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe', '-file', str(job/'flow.tcl'), '-work_dir', str(job)],
            cwd=job, log_path=job/'native.log', monitor_path=job/'monitor.jsonl', timeout_seconds=1200)
        errors = re.findall(r'^E:.*', (job/'native.log').read_text(errors='replace'), re.M)
        report = job/'synthesize'/(top+'.snr')
        resources = {}
        if report.exists():
            text = report.read_text(errors='replace')
            for key, pattern in [('LUT', r'Total LUTs: (\d+)'), ('FF', r'Total Registers: (\d+)')]:
                match = re.search(pattern, text)
                if match:
                    resources[key] = int(match[1])
        intact = all(hashlib.sha256((job/'source'/name).read_bytes()).hexdigest() == value for name, value in hashes.items())
        result = dict(label=label, top=top, lut_prevalidated=args.trusted_lut, origin=str(origin), supervision=supervision, errors=errors, resources=resources,
                      snapshot_intact=intact, passed=supervision['status']=='COMPLETED' and supervision['returncode']==0 and not errors and bool(resources) and intact)
        (job/'result.json').write_text(json.dumps(result, indent=2))
        results.append(result)
        (run/'result.json').write_text(json.dumps(dict(jobs=results, routed=False, hardware_tested=False), indent=2))
        print(label, top, json.dumps(resources), 'PASS' if result['passed'] else 'FAIL', flush=True)
        if not result['passed']:
            raise SystemExit(1)


if __name__ == '__main__':
    main()

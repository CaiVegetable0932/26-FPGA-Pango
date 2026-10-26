"""Freeze motion units and prove native SYN without routing or board claims.

PDS 2022.2-SP6.4 ADS guide shell flow and PG2L100H/FBG676 board settings match
build_video_system.py. Baseline SYN remains measurable despite known SIGNDIV
mapping failures; current units must complete SYN with no unmapped operators.
These abstract ports intentionally omit I/O buffers. Full device mapping is
performed by the board flow, not by claiming this unit screen proves pin DRC.
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
    """Freeze every input first, then use the shared native phase lock serially."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path)
    parser.add_argument('--tops', nargs='+', choices=['motion_trajectory','s1_motion_estimator','affine_dynamic_compose','motion_config_bank'])
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    run = fpga/'build/motion_resource_probes'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    shutil.copyfile(__file__, run/'probe_script.py')
    roots = [('baseline', args.baseline.resolve())] if args.baseline else []
    roots += [('current', fpga)]
    jobs = []
    for label, root in roots:
        if not root.is_relative_to(fpga):
            raise ValueError('source must remain within FPGA development area')
        for top in args.tops or ['motion_trajectory', 's1_motion_estimator', 'affine_dynamic_compose', 'motion_config_bank']:
            job = run/label/top
            job.mkdir(parents=True)
            source = job/(top+'.sv')
            shutil.copyfile(root/'rtl/stabilization'/(top+'.sv'), source)
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            (job/'clock.fdc').write_text('create_clock -name clk -period 8.0 [get_ports clk]\n')
            flow = f'set_dir -impl_directory {{{job.as_posix()}}}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow += f'add_design {{{source.as_posix()}}}\nadd_constraint {{{(job/"clock.fdc").as_posix()}}}\n'
            flow += f'compile -top_module {top} -system_verilog\n'
            flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (job/'flow.tcl').write_text(flow)
            jobs.append((label, top, job, source, digest))
    print('MOTION_RESOURCE_PROBE', run, flush=True)
    results = []
    for label, top, job, source, digest in jobs:
        supervised = run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
            '-file', str(job/'flow.tcl'), '-work_dir', str(job)], cwd=job,
            log_path=job/'native.log', monitor_path=job/'monitor.jsonl', timeout_seconds=1200)
        errors = re.findall(r'^E:.*', (job/'native.log').read_text(errors='replace'), re.M)
        snr = job/'synthesize'/(top+'.snr')
        resources = {}
        if snr.exists():
            text = snr.read_text(errors='replace')
            for key, pattern in [('LUT', r'Total LUTs: (\d+)'), ('FF', r'Total Registers: (\d+)')]:
                found = re.search(pattern, text)
                if found:
                    resources[key] = int(found[1])
        intact = hashlib.sha256(source.read_bytes()).hexdigest() == digest
        mapped = False
        passed = supervised['status']=='COMPLETED' and supervised['returncode']==0 and not errors and intact and bool(resources)
        result = dict(label=label, top=top, supervision=supervised, errors=errors, resources=resources,
                      source_sha256=digest, snapshot_intact=intact, mapped=mapped, passed=passed)
        results.append(result)
        (job/'result.json').write_text(json.dumps(result, indent=2))
        (run/'result.json').write_text(json.dumps(dict(jobs=results, routed=False, hardware_tested=False), indent=2))
        print(label, top, resources, 'PASS' if passed else 'FAIL', flush=True)
        # Baseline SIGNDIV is the defect being measured, not a success. Retain
        # its failed native status and resources, but allow current MAP proof.
        expected_baseline_failure = label=='baseline' and bool(resources) and any('bmsSIGNDIV' in error for error in errors) and all('bmsSIGNDIV' in error or 'Failed to execute the script' in error for error in errors)
        if not passed and not expected_baseline_failure:
            raise SystemExit(1)


if __name__ == '__main__':
    main()

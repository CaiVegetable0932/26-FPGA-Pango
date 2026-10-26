"""Freeze production RTL and verify explicit job/result CDC capture boundaries.

Runs independent mailbox agents and a real two-clock geometry/native-memory
byte oracle. This is functional evidence, not physical CDC/timing signoff.
"""
from datetime import datetime
from pathlib import Path
import argparse
import hashlib
import json
import shutil
import subprocess


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--cases', nargs='+', choices=['mailbox', 'geometry', 'geometry_fault', 'geometry_external'])
    parser.add_argument('--rtl-snapshot', type=Path,
                        help='Use an isolated build snapshot for RTL; keep repository fixtures')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    # Candidates can be verified while the production PDS job retains its
    # frozen inputs. Restrict explicit RTL selection to local build evidence.
    origin = args.rtl_snapshot.resolve() if args.rtl_snapshot else fpga
    if args.rtl_snapshot and not origin.is_relative_to(fpga / 'build'):
        raise ValueError('RTL snapshot must be inside fpga/build')
    run = fpga / 'build/core_area_20261023' / datetime.now().strftime('job_snapshot_%H%M%S_%f')
    source = run / 'source'
    source.mkdir(parents=True)
    paths = []
    # Compile the complete local geometry/memory closure with one selected top.
    # Copy before testing so later parallel edits cannot alter a running case.
    for folder in ['rtl/memory', 'rtl/geometry', 'rtl/isp']:
        paths.extend(p for p in (origin / folder).iterdir() if p.suffix in ('.sv', '.v', '.vh'))
    paths.extend(fpga / 'sim' / n for n in [
        'tb_processing_job_snapshot.sv', 'tb_geometry_processing_snapshot.sv'])
    original = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    for p in paths:
        if (source / p.name).exists():
            raise ValueError('Duplicate source basename: ' + p.name)
        shutil.copyfile(p, source / p.name)
    shutil.copyfile(__file__, run / 'verification_script.py')
    hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir()}
    tool = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(passed=False, physical_signed_off=False, rtl_origin=str(origin), source_hashes=hashes,
                  original_hashes=original, tools={str(tool / n): hashlib.sha256((tool / n).read_bytes()).hexdigest()
                  for n in ['iverilog.exe', 'vvp.exe']}, tests=[])
    modules = [source / 'frame_manager_pkg.sv'] + sorted(p for p in source.iterdir()
                if p.suffix in ('.v', '.sv') and p.name != 'frame_manager_pkg.sv')
    cases = []
    for sh, ph, phase in [(4, 3.333, .7), (3.333, 4, 1.1), (5, 3.1, 0), (4, 3.333, 3.9)]:
        cases.append(('mailbox', 'tb_processing_job_snapshot',
                     dict(SOURCE_HALF=sh, PROCESSING_HALF=ph, PROCESSING_PHASE=phase),
                     'PROCESSING_JOB_SNAPSHOT_PASS cases=82 accepted=82 completed=82'))
    for half, phase in [(3.333, .7), (3.333, 3.9), (4.7, 1.1)]:
        cases.append(('geometry', 'tb_geometry_processing_snapshot',
                     dict(PROC_HALF=half, PROC_PHASE=phase), 'GEOMETRY_PROCESSING_SNAPSHOT_PASS frames=2'))
    cases.append(('geometry_fault', 'tb_geometry_processing_snapshot',
                  dict(PROC_HALF=3.333, PROC_PHASE=2.1, W=9, H=7, FAULT_SEQUENCE=1),
                  'GEOMETRY_PROCESSING_SNAPSHOT_PASS frames=5'))
    cases.append(('geometry_external', 'tb_geometry_processing_snapshot',
                  dict(PROC_HALF=3.333, PROC_PHASE=.7, EXTERNAL_PAGES=1),
                  'GEOMETRY_PROCESSING_SNAPSHOT_PASS frames=2'))
    cases.append(('geometry_external', 'tb_geometry_processing_snapshot',
                  dict(PROC_HALF=3.333, PROC_PHASE=2.1, W=9, H=7, FAULT_SEQUENCE=1, EXTERNAL_PAGES=1),
                  'GEOMETRY_PROCESSING_SNAPSHOT_PASS frames=5'))
    try:
        for index, (kind, top, params, marker) in enumerate(cases):
            if args.cases and kind not in args.cases:
                continue
            case = run / f'{index}_{kind}'
            case.mkdir()
            commands = [('compile', [str(tool / 'iverilog.exe'), '-g2012', '-I', str(source), '-s', top,
                        *[f'-P{top}.{k}={v}' for k, v in params.items()], '-o', str(case / 'test.vvp'),
                        *map(str, modules)]), ('run', [str(tool / 'vvp.exe'), str(case / 'test.vvp')])]
            for stage, cmd in commands:
                process = subprocess.run(cmd, cwd=case, input=b'', capture_output=True, timeout=240)
                output = process.stdout + process.stderr
                (case / (stage + '.log')).write_bytes(output)
                if process.returncode:
                    raise RuntimeError(output.decode(errors='replace')[-4000:])
            summary = output.decode(errors='replace').strip()
            if marker not in summary:
                raise RuntimeError('Independent scoreboard did not complete: ' + summary)
            result['tests'].append(dict(kind=kind, parameters=params, passed=True, summary=summary))
            print(case.name, summary, flush=True)
        # Controlled regressions of each repaired boundary must fail the same
        # independent scoreboard. Mutate only a private copy of the frozen RTL.
        if not args.cases or 'mailbox' in args.cases:
            original_mailbox = (source / 'processing_job_cdc.sv').read_text(encoding='utf-8')
            controls = {
                'borrowed_job': (original_mailbox.replace(
                    'output reg [JOB_BITS-1:0] processing_job', 'output wire [JOB_BITS-1:0] processing_job').replace(
                    ' always @(posedge processing_clk)begin\n  if(processing_rst_n && processing_state==P_IDLE && request_sync!=response_toggle)\n   processing_job<=source_job;\n end',
                    ' assign processing_job=source_job;'), 'Destination job borrowed recycled source'),
                'borrowed_result': (original_mailbox.replace(
                    'output reg [RESULT_BITS-1:0] source_result', 'output wire [RESULT_BITS-1:0] source_result').replace(
                    ';source_result<=0', '').replace('source_result<=processing_result;', '').replace(
                    ' localparam S_IDLE', ' assign source_result=processing_result;\n localparam S_IDLE'),
                    'Return borrowed recycled counters'),
            }
            result['negative_controls'] = []
            for name, (mutant, expected_failure) in controls.items():
                case = run / ('negative_' + name)
                case.mkdir()
                (case / 'processing_job_cdc.sv').write_text(mutant, encoding='utf-8')
                cmd = [str(tool / 'iverilog.exe'), '-g2012', '-s', 'tb_processing_job_snapshot',
                       '-o', str(case / 'test.vvp'), str(case / 'processing_job_cdc.sv'),
                       str(source / 'tb_processing_job_snapshot.sv')]
                compiled = subprocess.run(cmd, cwd=case, input=b'', capture_output=True, timeout=60)
                (case / 'compile.log').write_bytes(compiled.stdout + compiled.stderr)
                if compiled.returncode:
                    raise RuntimeError('Negative control failed to compile: ' + name)
                executed = subprocess.run([str(tool / 'vvp.exe'), str(case / 'test.vvp')],
                                          cwd=case, input=b'', capture_output=True, timeout=60)
                output = executed.stdout + executed.stderr
                (case / 'run.log').write_bytes(output)
                if executed.returncode == 0 or expected_failure.encode() not in output:
                    raise RuntimeError('Negative control was not rejected: ' + name)
                result['negative_controls'].append(dict(name=name, rejected=True,
                                                        expected_failure=expected_failure))
                print('negative_' + name, 'REJECTED as expected', flush=True)
        result['passed'] = True
    finally:
        result['snapshot_intact'] = all(hashlib.sha256((source / n).read_bytes()).hexdigest() == h
                                        for n, h in hashes.items())
        result['production_intact'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h
                                          for p, h in original.items())
        result['passed'] &= result['snapshot_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('JOB_SNAPSHOT_PROOF', run, flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

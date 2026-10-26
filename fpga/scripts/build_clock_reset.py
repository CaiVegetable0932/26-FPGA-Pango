"""Snapshot either board project and run offline PDS through timing/bitstream.

Only reads native IP/reference inputs. Every generated file stays in a fresh
FPGA build directory; shared PDS projects and prior evidence remain untouched.
Optional gen_bit_stream creates a candidate SRAM image in the native flow;
failed timing or source checks prevent successful completion and delivery.
No programmer, Flash, JTAG or power measurement is invoked.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess

FPGA = Path(__file__).resolve().parents[1]


def main():
    """Copy exactly the project's dependencies, then retain all failed runs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--project', choices=('mini_camera_diag', 'pango_video_top'), required=True)
    parser.add_argument('--stage', choices=('compile', 'report_timing', 'gen_bit_stream'), default='report_timing')
    parser.add_argument('--pds-home', type=Path, default=Path('E:/PDS_Pangu/PDS_2022.2-SP6.4'))
    args = parser.parse_args()
    build_group = 'bitstream_20261012' if args.stage=='gen_bit_stream' else 'clock_reset_20261012'
    run = FPGA / 'build' / build_group / datetime.now().strftime(args.project+'_%Y%m%d_%H%M%S_%f')
    src = run / 'source'
    src.mkdir(parents=True)
    project = FPGA / f'project/{args.project}/{args.project}.tcl'
    original = project.read_text(encoding='utf-8-sig')
    dependencies = re.findall(r'add_(?:design|constraint) \[file join \$fpga_root ([^\]]+)\]', original)
    # IDF-generated dependencies use relative paths within their IP directories;
    # preserve each directory intact, without regenerating or editing IP HDL.
    for dependency in dependencies:
        relative = Path(*dependency.split())
        path, dest = FPGA / relative, src / relative
        if path.suffix == '.idf':
            if not dest.parent.exists():
                shutil.copytree(path.parent, dest.parent)
        else:
            dest.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(path, dest)
    # gamma ROM seed is a project-owned dependency of native ROM generation.
    shutil.copytree(FPGA / 'config', src / 'config')
    hashes = {p.relative_to(src).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in src.rglob('*') if p.is_file()}
    (run / 'source_hashes.json').write_text(json.dumps(hashes, indent=2)+'\n')
    # Preserve the exact project and orchestration inputs alongside native
    # source hashes. These copies are provenance only, never executable hooks.
    shutil.copyfile(project, run / 'original_project.tcl')
    shutil.copyfile(Path(__file__), run / 'build_script.py')
    top = 'Top' if args.project == 'mini_camera_diag' else args.project
    body = '\n'.join(line for line in original.splitlines()
                     if not line.startswith(('set fpga_root ', 'set_dir ', 'gen_netlist ', 'gen_bit_stream ', 'report_power')))
    body = body.replace('-max_path 10', '-max_path 30')
    if args.stage == 'compile':
        body = body[:body.index('\nsynthesize ')]
    elif args.stage == 'gen_bit_stream':
        # PDS pre-parses project Tcl before running tasks; report file reads
        # cannot be inserted as a runtime gate here. Use the documented native
        # task sequence and verify its same-run results in the host below.
        # Preserve the established configuration-bank voltage option. This
        # writes only a candidate file and does not change a connected board.
        body += '\n# Explicit offline candidate image generation.\ngen_bit_stream -scbv {High Voltage}\n'
    tcl = f'set fpga_root {{{src.as_posix()}}}\nset_dir -impl_directory {{{run.as_posix()}}}\n'+body+'\n'
    (run / 'flow.tcl').write_text(tcl, encoding='utf-8')
    print('CLOCK_RESET_PDS_START '+str(run), flush=True)
    # Preserve launch/timeout failures as explicit results too, even when PDS
    # cannot create a report. A previous successful report is never reused.
    native_exit, launch_error = None, None
    try:
        with (run / 'console.log').open('w', encoding='utf-8') as log:
            process = subprocess.run([str(args.pds_home / 'bin/pds_shell.exe'), '-file', str(run / 'flow.tcl'),
                                      '-work_dir', str(run)], cwd=run, stdout=log, stderr=subprocess.STDOUT,
                                     timeout=1800, creationflags=0x08000000)
            native_exit = process.returncode
    except (OSError, subprocess.TimeoutExpired) as error:
        launch_error = str(error)
    console = (run / 'console.log').read_text(errors='replace')
    report = run / f'report_timing/{top}.rtr'
    summary = dict(project=args.project, stage=args.stage, native_exit=native_exit, launch_error=launch_error, run=str(run),
                   tool_completed=False, internal_timing_met=False, external_timing_verified=False,
                   hardware_tested=False, programmed=False, download_approved=False,
                   bitstream_generated=False)
    summary['errors'] = re.findall(r'^E:.*', console, re.M)
    if args.stage == 'compile':
        summary['tool_completed'] = (run / f'compile/{top}.cmr').exists() and native_exit == 0 and not summary['errors']
    elif report.exists():
        text = report.read_text(errors='replace')
        match = re.search(r'^Design Summary\s*:\s*(.+)$', text, re.M)
        summary['design_summary'] = match[1].strip() if match else None
        summary['tool_completed'] = native_exit == 0 and not summary['errors']
        summary['internal_timing_met'] = summary['tool_completed'] and summary['design_summary'] == 'All Constraints Met.'
        summary['report_sha256'] = hashlib.sha256(report.read_bytes()).hexdigest()
    if args.stage == 'gen_bit_stream':
        bitstream = run / f'generate_bitstream/{top}.sbit'
        summary['bitstream_generated'] = bitstream.is_file() and bitstream.stat().st_size>0
        if summary['bitstream_generated']:
            summary.update(bitstream=str(bitstream),bitstream_bytes=bitstream.stat().st_size,
                           bitstream_sha256=hashlib.sha256(bitstream.read_bytes()).hexdigest())
        summary['tool_completed'] = summary['tool_completed'] and summary['bitstream_generated']
    # Verify copied build inputs remained immutable through native execution.
    summary['snapshot_intact'] = all(hashlib.sha256((src/relative).read_bytes()).hexdigest()==digest
                                     for relative,digest in hashes.items())
    summary['tool_completed'] = summary['tool_completed'] and summary['snapshot_intact']
    summary['candidate_checks_passed'] = (summary['tool_completed'] and summary['internal_timing_met']
                                         and summary['bitstream_generated'])
    (run / 'result.json').write_text(json.dumps(summary, indent=2)+'\n')
    print(json.dumps(summary), flush=True)
    if not summary['tool_completed']:
        raise SystemExit(1)
    if args.stage!='compile' and not summary['internal_timing_met']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()

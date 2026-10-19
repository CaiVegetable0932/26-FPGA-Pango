"""Snapshot the real board video candidate and run installed offline PDS."""
from datetime import datetime
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess
from native_bitgen import generate_from_timed_database
from implementation_readiness import require_whole_design_ready


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--overall-timeout-minutes', type=int, default=120, help='Whole native flow allowance; leaves per-action limits intact')
    parser.add_argument('--pnr-timeout-minutes', type=int, default=30, help='Native per-action limit, not a timing exception')
    parser.add_argument('--control-chain-length', type=int, default=500,
                        help='Official CE/RS routing chain default; independent of STA acceptance')
    parser.add_argument('--stage', choices=['compile', 'synthesize', 'dev_map', 'report_timing', 'gen_bit_stream'], default='report_timing')
    options = parser.parse_args()
    # Compile/SYN/MAP remain available for design review; complete PnR waits
    # until the user's whole-design readiness record has been reviewed.
    if options.stage in ('report_timing','gen_bit_stream'):
        require_whole_design_ready()
    if not 1 <= options.overall_timeout_minutes <= 240:
        parser.error('overall native allowance must be 1..240 minutes')
    if not 1 <= options.pnr_timeout_minutes <= 60:
        parser.error('PDS action timeout must be 1..60 minutes')
    if not 1 <= options.control_chain_length <= 500:
        parser.error('control routing chain length must be 1..500')
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('board_%Y%m%d_%H%M%S_%f')
    source = run / 'source'
    source.mkdir(parents=True)
    # Freeze source directories with their includes. Generated IP is copied in
    # full and never regenerated/modified in the original or official directory.
    names = ['rtl/memory/frame_manager_pkg.sv']
    for group in ['memory', 'input', 'isp', 'geometry', 'network', 'control', 'video']:
        for path in sorted((fpga / 'rtl' / group).glob('*')):
            if path.suffix in ('.v', '.sv', '.vh') and path.name not in (
                    'frame_manager_pkg.sv', 'ip_integration_bank.v', 'algorithm_timing_top.sv', 'hdmi_display_pnr_probe.v'):
                names.append(path.relative_to(fpga).as_posix())
    names += ['rtl/board/' + n for n in ['reset_sync.v', 'video_clock_start.v', 'rgmii_phy_io.v',
              'tmds_serializer.v', 'video_memory_core.sv', 'pango_video_system.sv']]
    names += ['rtl/mini_camera_diag/vendor/camera/SCCB.v', 'rtl/mini_camera_diag/vendor/camera/data_init.v',
              'rtl/mini_camera_diag/vendor/hdmi/tmds_encoder.v']
    constraints = ['constraints/ddr_native.fdc', 'constraints/ddr_board_pins.fdc',
                   'constraints/video_system/board_pins.fdc', 'constraints/video_system/clocks_cdc.fdc',
                   'constraints/placement.fdc', 'constraints/routing.rcf']
    for name in [*names, *constraints]:
        dest = source / name
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fpga / name, dest)
    for name in ['video_pll', 'ddr3_controller']:
        shutil.copytree(fpga / 'ip' / name, source / 'ip' / name)
    shutil.copytree(fpga / 'config', source / 'config')
    hashes = {p.relative_to(source).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
              for p in source.rglob('*') if p.is_file()}
    (run / 'sources.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    shutil.copyfile(Path(__file__), run / 'build_script.py')
    shutil.copyfile(Path(__file__).with_name('native_bitgen.py'), run / 'native_bitgen.py')
    # Native task commands follow the installed PDS 2022.2-SP6.4 flow. Full
    # board timing is a distinct gate; unit-wide abstract ports are not routed.
    flow = '# Offline MINI video integration candidate; no programmer.\n'
    flow += f'set_dir -impl_directory {{{run.as_posix()}}}\n'
    flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
    for name in names:
        if not name.endswith('.vh'):
            flow += f'add_design {{{(source / name).as_posix()}}}\n'
    for name in ['video_pll', 'ddr3_controller']:
        flow += f'add_design {{{(source / "ip" / name / (name + ".idf")).as_posix()}}}\n'
    for name in constraints:
        flow += f'add_constraint {{{(source / name).as_posix()}}}\n'
    flow += f'compile -top_module pango_video_system -system_verilog -include_path [list {{{(source / "rtl/memory").as_posix()}}}]\n'
    if options.stage != 'compile':
        # Installed ADS guide: bound data fanout, preserve RAM read/write checks,
        # and avoid resource-sharing muxes on distinct active pipeline lanes.
        flow += 'synthesize -ads -rw_check_on_ram -resource_sharing false -fanout_guide 64 -selected_syn_tool_opt 2\n'
    if options.stage in ('dev_map', 'report_timing', 'gen_bit_stream'):
        flow += 'dev_map\n'
    if options.stage in ('report_timing', 'gen_bit_stream'):
        # Guide p117 explicitly puts single-thread PG2L100H general/router
        # defaults in the Logos column: CE/RS chain500, congestion iterations200.
        # Physical diagnosis/new expansion/seeds are configurable in the resume
        # driver. These settings never change timing constraints or STA gates.
        flow += f'pnr -congest_overlap_limit 200 -action_timeout {options.pnr_timeout_minutes} -max_ctrl_chain_length {options.control_chain_length} -gplace_seed 7\n'
        flow += 'report_timing -delay_type min_max -max_path 30 -report_exception TRUE\n'
    if options.stage == 'gen_bit_stream':
        # Native options are stored in the project. Ordinary Tcl file reads
        # execute during tcl2prj parsing, before queued STA tasks produce data.
        # The Python host therefore gates a SEPARATE native bitstream run.
        flow += 'gen_bit_stream -scbv {High Voltage}\n'
    (run / 'flow.tcl').write_text(flow, encoding='utf-8')
    print('BOARD_START', run, flush=True)
    generate = run / 'create_project.tcl'
    generate.write_text(f'tcl2prj -tcl {{{(run / "flow.tcl").as_posix()}}}\n', encoding='utf-8')
    shell = 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe'
    with (run / 'generation.log').open('wb') as log:
        generated = subprocess.run([shell, '-file', str(generate), '-work_dir', str(run)], cwd=run,
                                   stdout=log, stderr=subprocess.STDOUT, creationflags=0x08000000, timeout=120)
    generation_text = (run / 'generation.log').read_text(errors='replace')
    if generated.returncode or re.search(r'^E:', generation_text, re.M):
        raise RuntimeError('PDS project generation failed: '+generation_text[-3000:])
    native_stage = 'report_timing' if options.stage == 'gen_bit_stream' else options.stage
    with (run / 'console.log').open('wb') as log:
        process = subprocess.run([shell, '-project', str(run / 'flow.pds'), '-run', native_stage,
                                  '-work_dir', str(run)], cwd=run, stdout=log, stderr=subprocess.STDOUT,
                                 creationflags=0x08000000, timeout=options.overall_timeout_minutes*60)
    if options.stage == 'gen_bit_stream':
        report_path = run / 'report_timing/pango_video_system.rtr'
        timing_text = report_path.read_text(errors='replace') if report_path.exists() else ''
        stage_errors = re.findall(r'^E:.*', (run / 'console.log').read_text(errors='replace'), re.M)
        if process.returncode == 0 and not stage_errors and re.search(r'^Design Summary\s*:\s*All Constraints Met\.', timing_text, re.M):
            # The documented explicit DB action reads the SAME routed image;
            # re-opening a full project can otherwise re-run its prior tasks.
            process = generate_from_timed_database(run, shell, run / 'bitgen_console.log')
    console = (run / 'console.log').read_text(errors='replace')
    if (run / 'bitgen_console.log').exists():
        console += (run / 'bitgen_console.log').read_text(errors='replace')
    errors = re.findall(r'^E:.*', console, re.M)
    report = run / 'report_timing/pango_video_system.rtr'
    match = re.search(r'^Design Summary\s*:\s*(.+)$', report.read_text(errors='replace'), re.M) if report.exists() else None
    intact = all(hashlib.sha256((source / name).read_bytes()).hexdigest() == digest for name, digest in hashes.items())
    result = {'stage': options.stage, 'native_exit': process.returncode, 'errors': errors, 'snapshot_intact': intact,
              'internal_timing_met': bool(match and match[1].strip() == 'All Constraints Met.'),
              'full_function_release': False, 'hardware_tested': False, 'programmed': False,
              'external_timing_verified': False, 'download_approved': False}
    bitstream = run / 'generate_bitstream/pango_video_system.sbit'
    if bitstream.is_file():
        result.update(bitstream=str(bitstream), bitstream_bytes=bitstream.stat().st_size,
                      bitstream_sha256=hashlib.sha256(bitstream.read_bytes()).hexdigest())
    (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result), flush=True)
    if process.returncode or errors or not intact:
        raise SystemExit(1)
    if options.stage in ('report_timing', 'gen_bit_stream') and not result['internal_timing_met']:
        raise SystemExit(2)


if __name__ == '__main__':
    main()

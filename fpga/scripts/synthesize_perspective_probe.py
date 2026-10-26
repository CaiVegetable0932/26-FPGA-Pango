"""Native divider synthesis/STA diagnostic; no board I/O or bitstream claim."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    # This historical transform expects the retired projective architecture.
    raise SystemExit('Retired projective experiment: reproduce from its frozen build/source; current production is affine_lens.')
    """Freeze the exact arithmetic and run installed PDS only in fpga/build."""
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('math_%Y%m%d_%H%M%S_%f')
    source = run / 'source'
    source.mkdir(parents=True)
    names = ['rtl/geometry/perspective_divide.sv', 'rtl/geometry/unsigned_mult32_pipe.sv',
             'rtl/geometry/signed_mult40_unsigned40_pipe.sv', 'sim/perspective_timing_probe.sv']
    hashes = {}
    for name in names:
        target = source / Path(name).name
        shutil.copyfile(fpga / name, target)
        hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    (run / 'sources.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
    # Same installed version/device/speed and synthesis settings as the board.
    # Generic port counts and pre-placement timing are diagnostic only.
    (run / 'clock.fdc').write_text('create_clock -name clk -period 8.0 [get_ports clk]\nset_false_path -from [get_ports rst_n]\n', encoding='utf-8')
    flow = f'set_dir -impl_directory {{{run.as_posix()}}}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
    for name in names:
        flow += f'add_design {{{(source / Path(name).name).as_posix()}}}\n'
    flow += f'add_constraint {{{(run / "clock.fdc").as_posix()}}}\n'
    flow += 'compile -top_module perspective_timing_probe -system_verilog\nsynthesize -ads -selected_syn_tool_opt 2\n'
    (run / 'flow.tcl').write_text(flow, encoding='utf-8')
    print('MATH_START', run, flush=True)
    with (run / 'console.log').open('wb') as log:
        child = subprocess.run(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe', '-file', str(run / 'flow.tcl'), '-work_dir', str(run)],
                               cwd=run, stdout=log, stderr=subprocess.STDOUT, timeout=1800, creationflags=0x08000000)
    errors = re.findall(r'^E:.*', (run / 'console.log').read_text(errors='replace'), re.M)
    result = {'native_exit': child.returncode, 'errors': errors, 'hardware_tested': False,
              'board_routed': False, 'bitstream_generated': False,
              'snapshot_intact': all(hashlib.sha256((source / Path(n).name).read_bytes()).hexdigest() == h for n, h in hashes.items())}
    (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(json.dumps(result), flush=True)
    if child.returncode or errors:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

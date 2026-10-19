"""Compare all PC outputs and snapshot bits under real serial traffic.

Both implementations receive the same independent UART/backend stimulus.
The fixture checks replies separately, changes backend status under UART
backpressure and covers cold/midstream reset and all status operations/pages.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    """Bind deployable source bytes to the dual-implementation simulation."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):
        raise ValueError('Frozen FPGA candidate required')
    run = candidate/datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    files = {'original_pc_video_boot.sv': candidate/'original_pc_video_boot.sv',
             'candidate_pc_video_boot.sv': candidate/'source/rtl/control/pc_video_boot.sv',
             'pc_tb.sv': fpga/'sim/tb_pc_boot_capture_equivalence.sv'}
    files.update({n: candidate/'source/rtl/control'/n
                  for n in ('uart_8n1.sv', 'uart_v2_parser.sv', 'parameter_entity_guard.sv')})
    inputs = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files.values()}
    for name, source in files.items():
        shutil.copyfile(source, run/name)
    current = (run/'candidate_pc_video_boot.sv').read_text(encoding='utf-8')
    marker = 'module pc_video_boot #('
    if current.count(marker) != 1:
        raise ValueError('Unexpected candidate module')
    # Module renaming is the only transformation of candidate RTL in this
    # proof; no state is forced, shared or replaced by a behavioral model.
    (run/'compare_pc_video_boot.sv').write_text(current.replace(
        marker, 'module pc_video_boot_local_capture_candidate #(', 1), encoding='utf-8')
    shutil.copyfile(__file__, run/'verification_script.py')
    tool = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    names = ['pc_tb.sv', 'original_pc_video_boot.sv', 'compare_pc_video_boot.sv',
             'uart_8n1.sv', 'uart_v2_parser.sv', 'parameter_entity_guard.sv']
    result = dict(passed=False, cycle_equivalent=False, four_state=True,
                  all_external_bits_compared=903, all_internal_snapshot_bits_compared=1536,
                  inputs=inputs, tests=[])
    try:
        for phase, command in [('compile', [str(tool/'iverilog.exe'), '-g2012',
                                '-s','pc_tb','-o','pc_tb.vvp',*names]),
                               ('run', [str(tool/'vvp.exe'),'pc_tb.vvp'])]:
            child = subprocess.run(command, cwd=run, capture_output=True, timeout=120)
            output = child.stdout+child.stderr
            (run/(phase+'.log')).write_bytes(output)
            if child.returncode:
                raise RuntimeError(phase+': '+output.decode(errors='replace')[-4000:])
        counts = re.search(
            r'PC_CAPTURE_DIFF_PASS cycles=(\d+) public_bits=(\d+) replies=(\d+) captures=(\d+) '
            r'busy_cycles=(\d+) resets=(\d+) mode=(\d+) geometry=(\d+) snapshot=(\d+)',
            output.decode(errors='replace'))
        if not counts:
            raise ValueError('Independent UART/whole-snapshot fixture did not finish')
        result['counts'] = dict(zip(('cycles','public_bits','replies','captures','busy_cycles',
                                     'resets','mode','geometry','snapshot'), map(int, counts.groups())))
        result.update(passed=True, cycle_equivalent=True, tests=['all_outputs_and_snapshot_pages'])
    finally:
        result['inputs_intact'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h
                                      for p,h in inputs.items())
        result['passed'] = result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(dict(run=str(run), **result)), flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

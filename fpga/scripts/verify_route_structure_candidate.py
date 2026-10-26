"""Freeze and verify structural route candidates without using the PDS slot.

Each run records the exact baseline/candidate RTL, fixtures and commands. Unit
transport tests allow intentional pipeline latency; the configuration test
requires cycle equality. No software result certifies physical routability.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(path):
    """Identify the bytes actually compiled, including testbench dependencies."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Use the installed Icarus runtime and explicit stdin on Windows."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--baseline', action='store_true')
    parser.add_argument('--only', nargs='+', help='Run selected existing benches')
    parser.add_argument('--viewport', type=int, choices=(0, 1), default=1,
                        help='Configuration differential production/default profile')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga / 'build/route_structure_20261024'):
        raise ValueError('An isolated structural candidate is required')
    baseline = Path(json.loads((candidate / 'candidate.json').read_text())['baseline'])
    origin = baseline / 'source' if args.baseline else candidate / 'source'
    label = 'baseline' if args.baseline else 'candidate'
    run = candidate / datetime.now().strftime(label + '_unit_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    memory = ['rtl/memory/' + n for n in (
        'frame_manager_pkg.sv', 'frame_manager_layout.vh', 'frame_pool_bank.sv',
        'frame_manager.sv', 'frame_memory_fabric.sv', 'ddr_native_dma.v',
        'geometry_tile_refill.sv')]
    names = memory + ['rtl/stabilization/motion_config_bank.sv']
    tests = ['tb_motion_config', 'tb_dma_rr_selection', 'tb_ddr_native_dma',
             'tb_frame_memory_fabric', 'tb_geometry_tile_refill']
    if not args.baseline:
        tests += ['tb_motion_config_distribution', 'tb_dma_grant_stage',
                  'tb_refill_elastic_contract']
    if args.only:
        if any(top not in tests for top in args.only):
            raise ValueError('Unknown verification bench')
        tests = [top for top in tests if top in args.only]
    inputs = {}
    for name in names:
        target = run / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(origin / name, target)
        inputs[name] = sha(target)
    for top in tests:
        name = 'sim/' + top + '.sv'
        target = run / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(fpga / name, target)
        inputs[name] = sha(target)
    # The comparison reference is the exact pre-edit L implementation; only
    # its module name changes so both designs can be elaborated in one image.
    reference = baseline / 'source/rtl/stabilization/motion_config_bank.sv'
    baseline_text = reference.read_text().replace('module motion_config_bank #(',
                                                'module motion_config_bank_baseline #(', 1)
    ref_name = 'motion_config_bank_baseline.sv'
    (run / ref_name).write_text(baseline_text)
    inputs[ref_name] = sha(run / ref_name)
    shutil.copyfile(__file__, run / 'verification_script.py')
    binary = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(passed=False, label=label, origin=str(origin), inputs=inputs,
                  baseline_config_sha256=sha(reference), cases=[], pds_run=False,
                  hardware_tested=False, cycle_equivalence_scope='motion_config_bank only')
    result['viewport_profile'] = args.viewport
    print('STRUCTURE_UNIT', run, flush=True)
    try:
        for top in tests:
            image = run / (top + '.vvp')
            command = [str(binary / 'iverilog.exe'), '-g2012', '-I', str(run / 'rtl/memory'),
                       '-s', top, '-o', str(image)]
            # Packaged Icarus parses -P only before the first source filename.
            if top == 'tb_motion_config_distribution':
                command += ['-P' + top + '.SUPPORT_VIEWPORT=' + str(args.viewport)]
            command += [str(run / n) for n in names if not n.endswith('.vh')]
            command += [str(run / ref_name), str(run / ('sim/' + top + '.sv'))]
            (run / (top + '.command.json')).write_text(json.dumps(command, indent=2))
            proc = subprocess.run(command, cwd=run, input=b'', capture_output=True, timeout=120)
            (run / (top + '.compile.log')).write_bytes(proc.stdout + proc.stderr)
            if proc.returncode:
                raise RuntimeError(top + ' compile failed: ' + (proc.stdout + proc.stderr).decode(errors='replace')[-1200:])
            seeds = [42, 1907, 20261024] if top in ('tb_ddr_native_dma', 'tb_motion_config_distribution') else [42]
            for seed in seeds:
                cmd = [str(binary / 'vvp.exe'), str(image), '+seed=' + str(seed)]
                proc = subprocess.run(cmd, cwd=run, input=b'', capture_output=True, timeout=180)
                output = proc.stdout + proc.stderr
                log = top + '.' + str(seed) + '.log'
                (run / log).write_bytes(output)
                passed = proc.returncode == 0 and b'PASS' in output and b'FATAL' not in output
                result['cases'].append(dict(top=top, seed=seed, passed=passed, log=log,
                                            command=cmd, native_exit=proc.returncode))
                print(top, seed, output.decode(errors='replace')[-1200:].strip(), flush=True)
                if not passed:
                    raise RuntimeError(log + ' failed')
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(sha(run / n) == h for n, h in inputs.items())
        result['passed'] &= result['inputs_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2))
        print('STRUCTURE_UNIT_RESULT', run, flush=True)


if __name__ == '__main__':
    main()

"""Reproduce pose storage equivalence and atomic motion configuration tests."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import subprocess


def main():
    """Freeze current inputs and compare against the saved pre-change model."""
    fpga = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path,
                        default=fpga/'build/pose_storage_20261023/pose_affine_model_before.sv')
    options = parser.parse_args()
    run = fpga/'build/pose_storage_20261023'/datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    tool = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    baseline = options.baseline.read_text(encoding='utf-8')
    if baseline.count('module pose_affine_model(') != 1:
        raise ValueError('baseline must contain exactly one unrenamed pose model')
    reference = run/'pose_affine_model_before.sv'
    reference.write_text(baseline.replace('module pose_affine_model(',
                                        'module pose_affine_model_before('), encoding='utf-8')
    cases = [
        ('tb_pose_storage_equivalence', [reference, fpga/'rtl/control/pose_affine_model.sv'], False),
        ('tb_pose_storage_equivalence', [reference, fpga/'rtl/control/pose_affine_model.sv'], True),
        ('tb_motion_algorithms', [fpga/'rtl/control/pose_affine_model.sv',
                                  fpga/'rtl/stabilization/affine_dynamic_compose.sv'], False),
        ('tb_motion_config', [fpga/'rtl/stabilization/motion_config_bank.sv'], False),
    ]
    result = []
    for top, files, prevalidated in cases:
        # Each case owns frozen sources and a manifest; later parallel edits
        # cannot silently change what the reported simulation has exercised.
        case = run/(top+('_prevalidated' if prevalidated else ''))
        case.mkdir()
        files.append(fpga/'sim'/(top+'.sv'))
        frozen = []
        for source in files:
            dest = case/source.name
            dest.write_bytes(source.read_bytes())
            frozen.append(dest)
        commands = [
            [str(tool/'iverilog.exe'), '-g2012', '-s', top, '-o', str(case/'sim.vvp'),
             *(['-P', top+'.PREVALIDATED=1'] if prevalidated else []),
             *map(str, frozen)],
            [str(tool/'vvp.exe'), str(case/'sim.vvp')],
        ]
        for stage, command in zip(('compile', 'simulate'), commands):
            # A real stdin pipe avoids the Windows Icarus invalid-handle crash.
            process = subprocess.run(command, cwd=case, input='', text=True,
                                     capture_output=True, timeout=60)
            (case/(stage+'.log')).write_text(process.stdout+process.stderr, encoding='utf-8')
            if process.returncode:
                raise RuntimeError(f'{top} {stage} failed: {process.stdout} {process.stderr}')
        result.append(dict(top=top, prevalidated=prevalidated, passed=True,
                           sources={p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in frozen}))
        print(top, 'PASS', flush=True)
    (run/'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
    print(run, flush=True)


if __name__ == '__main__':
    main()

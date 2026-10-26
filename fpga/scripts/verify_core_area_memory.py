"""Freeze and test the memory-side area refactor without invoking native PDS."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Retain compiler/runtime evidence and immutable input hashes per run."""
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/core_area_20261023' / datetime.now().strftime('%H%M%S_%f')
    run.mkdir(parents=True)
    sources = ['rtl/memory/' + name for name in (
        'frame_manager_pkg.sv', 'frame_manager_layout.vh', 'frame_pool_bank.sv',
        'frame_manager.sv', 'frame_memory_fabric.sv', 'ddr_native_dma.v')]
    benches = ['tb_dma_rr_selection', 'tb_ddr_native_dma', 'tb_frame_memory_fabric']
    inputs = sources + ['sim/' + b + '.sv' for b in benches]
    hashes = {}
    for name in inputs:
        path = fpga / name
        target = run / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, target)
        hashes[name] = hashlib.sha256(target.read_bytes()).hexdigest()
    shutil.copyfile(__file__, run / 'verification_script.py')
    tool = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(passed=False, hardware_tested=False, synthesis_tested=False, hashes=hashes, cases=[])
    try:
        for bench in benches:
            image = run / (bench + '.vvp')
            compile_command = [str(tool / 'iverilog.exe'), '-g2012', '-I', str(run / 'rtl/memory'),
                               '-s', bench, '-o', str(image)]
            compile_command += [str(run / p) for p in sources if not p.endswith('.vh')]
            compile_command += [str(run / ('sim/' + bench + '.sv'))]
            # Explicit stdin avoids the packaged Windows Icarus invalid-handle crash.
            proc = subprocess.run(compile_command, input=b'', capture_output=True, timeout=60, cwd=run)
            (run / (bench + '.compile.log')).write_bytes(proc.stdout + proc.stderr)
            if proc.returncode:
                raise RuntimeError(bench + ' compile failed')
            for seed in ([42, 1907, 20261012] if bench == 'tb_ddr_native_dma' else [42]):
                proc = subprocess.run([str(tool / 'vvp.exe'), str(image), '+seed=' + str(seed)],
                                      input=b'', capture_output=True, timeout=120, cwd=run)
                output = proc.stdout + proc.stderr
                log = bench + '.' + str(seed) + '.log'
                (run / log).write_bytes(output)
                passed = proc.returncode == 0 and b'_PASS' in output and b'FATAL' not in output
                result['cases'].append(dict(bench=bench, seed=seed, passed=passed, log=log))
                print(bench, seed, output.decode(errors='replace')[-1000:], flush=True)
                if not passed:
                    raise RuntimeError(log + ' failed')
        result['passed'] = True
    finally:
        result['snapshot_intact'] = all(hashlib.sha256((run / p).read_bytes()).hexdigest() == h for p, h in hashes.items())
        result['passed'] = result['passed'] and result['snapshot_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('CORE_AREA_MEMORY_RESULT', run, flush=True)


if __name__ == '__main__':
    main()

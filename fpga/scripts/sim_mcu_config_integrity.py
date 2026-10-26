"""Verify complete MCU configuration digests and borrowed-packet revocation."""
from datetime import datetime
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Freeze inputs and retain all16 compiled/run results without PDS or hardware."""
    fpga = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-snapshot', type=Path,
                        help='Frozen board source directory containing rtl/control')
    options = parser.parse_args()
    rtl_root = options.rtl_snapshot.resolve() if options.rtl_snapshot else fpga
    run = fpga / 'build/core_area_20261023' / datetime.now().strftime('config_borrow_%H%M%S_%f')
    run.mkdir(parents=True)
    tool = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    sources = [rtl_root / 'rtl/control' / name for name in ('mcu_readonly_client.sv', 'uart_v2_parser.sv')]
    benches = ['tb_mcu_config_revocation', 'tb_mcu_config_integrity', 'tb_uart_v2_parser', 'tb_mcu_readonly_client']
    inputs = sources + [fpga / 'sim' / (name + '.sv') for name in benches]
    inputs += list((fpga / 'sim/vectors/network_control').glob('*.hex'))
    hashes = {}
    origins = {}
    for path in inputs:
        shutil.copyfile(path, run / path.name)
        hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        origins[path.name] = str(path)
    shutil.copyfile(__file__, run / 'verification_script.py')
    cases = [('tb_mcu_config_revocation', dict(DIGEST_ONLY=d, REVOKE_STAGE=s, REVOKE_OVERFLOW=o))
             for d in (0, 1) for s in (0, 1, 2) for o in (0, 1)]
    cases += [('tb_mcu_config_integrity', dict(DIGEST_ONLY=d)) for d in (0, 1)]
    cases += [(name, {}) for name in benches[2:]]
    result = dict(passed=False, hardware_tested=False, rtl_snapshot=str(rtl_root),
                  hashes=hashes, origins=origins, tools={}, cases=[])
    try:
        # Compiler/runtime binaries and version output bind the executable tool
        # identity, independently of the frozen RTL/test/vector source hashes.
        for executable in ('iverilog.exe', 'vvp.exe'):
            path = tool / executable
            proc = subprocess.run([str(path), '-V'], input=b'', capture_output=True, timeout=30)
            (run / (executable + '.version.log')).write_bytes(proc.stdout + proc.stderr)
            result['tools'][executable] = dict(path=str(path),
                sha256=hashlib.sha256(path.read_bytes()).hexdigest(), version_exit=proc.returncode)
            if proc.returncode:
                raise RuntimeError(executable + ' version query failed')
        for number, (bench, parameters) in enumerate(cases):
            image = run / (str(number) + '.vvp')
            command = [str(tool / 'iverilog.exe'), '-g2012', '-s', bench, '-o', str(image)]
            command += ['-P' + bench + '.' + key + '=' + str(value) for key, value in parameters.items()]
            command += [str(run / path.name) for path in sources] + [str(run / (bench + '.sv'))]
            record = dict(bench=bench, parameters=parameters, passed=False)
            result['cases'].append(record)
            for phase, arguments in [('compile', command), ('run', [str(tool / 'vvp.exe'), str(image)])]:
                # Valid stdin avoids packaged Windows Icarus invalid-handle faults.
                process = subprocess.run(arguments, input=b'', capture_output=True, cwd=run, timeout=90)
                output = process.stdout + process.stderr
                (run / (str(number) + '.' + phase + '.log')).write_bytes(output)
                if process.returncode or (phase == 'run' and b'_PASS' not in output):
                    raise RuntimeError(bench + ' ' + phase + ': ' + output.decode(errors='replace')[-1000:])
            record['passed'] = True
            print(bench, parameters, 'PASS', flush=True)
        result['passed'] = True
    finally:
        result['snapshot_intact'] = all(hashlib.sha256((run / path).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
        result['inputs_intact'] = all(hashlib.sha256(Path(origins[path]).read_bytes()).hexdigest() == digest for path, digest in hashes.items())
        result['passed'] = result['passed'] and result['snapshot_intact'] and result['inputs_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('MCU_CONFIG_BORROW_RESULT', run, flush=True)


if __name__ == '__main__':
    main()

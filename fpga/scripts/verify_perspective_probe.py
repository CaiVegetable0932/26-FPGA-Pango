"""Check an isolated divider candidate against the original and full-depth model."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    # This historical transform expects the retired projective architecture.
    raise SystemExit('Retired projective experiment: reproduce from its frozen build/source; current production is affine_lens.')
    """Retain exact fixtures and both input versions; failures remain on disk."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    run = args.probe.resolve()
    source = run / 'candidate/source'
    test = run / 'simulation'
    test.mkdir(exist_ok=False)
    shutil.copyfile(Path(__file__), test / 'verification_script.py')
    baseline = (run / 'baseline/source/perspective_divide.sv').read_text(encoding='utf-8')
    if baseline.count('module perspective_divide #') != 1:
        raise ValueError('Original divider identity is ambiguous')
    (test / 'baseline.sv').write_text(baseline.replace('module perspective_divide #',
                                      'module perspective_divide_baseline #'), encoding='utf-8')
    cases = ('tb_perspective_delay_equivalence', 'tb_perspective_domain')
    for top in cases:
        shutil.copyfile(fpga / 'sim' / (top+'.sv'), test / (top+'.sv'))
    runtime = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    design = [source / n for n in ('perspective_divide.sv', 'unsigned_mult32_pipe.sv',
                                  'signed_mult40_unsigned40_pipe.sv')]
    files = design + list(test.glob('*.sv'))
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in files}
    result = dict(passed=False, hardware_tested=False, tests=[], sources=hashes)
    try:
        for top in cases:
            commands = [('compile', [str(runtime / 'iverilog.exe'), '-g2012', '-s', top,
                         '-o', str(test / (top+'.vvp')), *map(str, design),
                         str(test / 'baseline.sv'), str(test / (top+'.sv'))]),
                        ('run', [str(runtime / 'vvp.exe'), str(test / (top+'.vvp'))])]
            for phase, command in commands:
                completed = subprocess.run(command, cwd=test, capture_output=True, timeout=180,
                                           creationflags=0x08000000)
                output = completed.stdout+completed.stderr
                (test / (top+'.'+phase+'.log')).write_bytes(output)
                if completed.returncode or (phase=='run' and b'_PASS' not in output):
                    raise RuntimeError(output.decode(errors='replace'))
                if phase=='run':
                    print(output.decode(errors='replace'), flush=True)
            result['tests'].append(top)
        result['snapshot_intact'] = all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h
                                       for n,h in hashes.items())
        result['passed'] = result['snapshot_intact']
    finally:
        (test / 'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

"""Four-state cycle comparison and independent protocol/cache scoreboards.

The comparison instantiates frozen L and candidate modules with identical
inputs. Public ports are compared every falling edge; private PC payload is
compared only after its resettable publication guard makes it observable.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def ports(text):
    """Read the simple ANSI declarations of these three fixed modules."""
    header = text[text.index('module '):].split(');', 1)[0]
    answer = {}
    direction = None
    for field in header[header.index(')(\n')+3:].split(','):
        field = re.sub(r'//[^\n]*', '', field).strip()
        m = re.search(r'\b(input|output)\b', field)
        if m:
            direction = m[1]
        names = re.findall(r'[A-Za-z_]\w*', re.sub(r'\[[^]]+\]', '', field))
        if not names or direction is None:
            raise ValueError('Unsupported port declaration: ' + field)
        answer[names[-1]] = direction
    return answer


def comparison(bench, rtl, module, instance):
    """Preserve the original scoreboard DUT and add an undriven-output peer."""
    pattern = r'\b' + re.escape(module) + r'\s*#\((.*?)\)\s*' + instance + r'\((.*?)\);'
    found = re.search(pattern, bench, re.S)
    if not found:
        raise ValueError('Fixture instance missing: ' + instance)
    declared = ports(rtl)
    if found[2].strip() == '.*':
        connections = {n: n for n in declared}
    else:
        connections = dict(re.findall(r'\.(\w+)\(([^()]*)\)', found[2]))
    inputs = ['.' + n + '(' + connections.get(n, '') + ')' for n, d in declared.items() if d == 'input']
    outputs = [n for n, d in declared.items() if d == 'output']
    reset = connections['rst_n']
    code = '\n // Compare every public signal against the frozen L implementation.\n'
    code += module + '_baseline #(' + found[1] + ') reference(' + ','.join(inputs) + ');\n'
    code += 'integer block_diff_cycles=0;\n always @(negedge clk) if(' + reset + ')begin\n block_diff_cycles=block_diff_cycles+1;\n'
    for name in outputs:
        code += ' if(' + instance + '.' + name + ' !== reference.' + name + ')$fatal(1,"BLOCK_DIFF ' + module + '.' + name + '");\n'
    if module == 'pc_video_boot':
        code += ' if(' + instance + '.have_snapshot && ' + instance + '.status_snapshot !== reference.status_snapshot)$fatal(1,"SNAPSHOT_PUBLICATION_DIFF");\n'
    if module == 'mcu_readonly_client':
        code += ' if(' + instance + '.state_decision_pending && ' + instance + '.received !== reference.state_buffer)$fatal(1,"MCU_OWNED_PAYLOAD_CHANGED");\n'
    code += ' end\n final $display("BLOCK_DIFF_CHECKED module=' + module + ' cycles=%0d",block_diff_cycles);\n'
    return bench[:found.end()] + code + bench[found.end():]


def main():
    """Freeze scripts, RTL, independent fixtures and vectors for reproducibility."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--only', choices=['mcu', 'pc', 'cache'],
                        help='Repeat only the selected family after a fixture repair')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga / 'build/block_pressure_20261025'):
        raise ValueError('Isolated block-pressure candidate required')
    manifest = json.loads((candidate / 'sources.json').read_text())
    if not all(hashlib.sha256((candidate / 'source' / n).read_bytes()).hexdigest() == h for n, h in manifest.items()):
        raise ValueError('Source manifest drift')
    run = candidate / datetime.now().strftime('software_%Y%m%d_%H%M%S_%f')
    source = run / 'source'
    source.mkdir(parents=True)
    paths = []
    for group in ['control', 'geometry', 'memory', 'isp']:
        for p in (candidate / 'source/rtl' / group).iterdir():
            if p.suffix in ('.sv', '.v', '.vh'):
                target = source / p.name
                if target.exists():
                    raise ValueError('Duplicate RTL basename')
                shutil.copyfile(p, target)
                paths.append(p)
    fixtures = [
        ('tb_mcu_readonly_client', 'mcu_readonly_client', 'control', 'dut', {}),
        ('tb_pc_mcu_link', 'pc_video_boot', 'control', 'pc', {}),
        ('tb_pc_video_boot', 'pc_video_boot', 'control', 'dut', {}),
        ('tb_pc_snapshot_ownership', 'pc_video_boot', 'control', 'pc', {}),
        ('tb_rgb_tile_cache', 'rgb_tile_cache', 'geometry', 'dut', dict(FILL_PIXELS=1)),
        ('tb_rgb_tile_cache', 'rgb_tile_cache', 'geometry', 'dut', dict(FILL_PIXELS=4)),
        ('tb_rgb_tile_cache', 'rgb_tile_cache', 'geometry', 'dut', dict(FILL_PIXELS=4,TILE_X_BITS=5,TILE_Y_BITS=3)),
    ]
    # A capacity change may alter cache miss timing. Validate its pixels and
    # replacement/fault protocol against the independent oracle, not same-cycle
    # equality to a cache with twice as many entries. Default four-way behavior
    # still receives the differential cases above.
    if json.loads((candidate / 'candidate.json').read_text()).get('cache_ways') == 2:
        fixtures += [('tb_rgb_tile_cache_ways', 'rgb_tile_cache', 'geometry', 'dut', p) for p in
            [dict(FILL_PIXELS=1), dict(FILL_PIXELS=4), dict(FILL_PIXELS=4,TILE_X_BITS=5,TILE_Y_BITS=3),
             dict(FILL_PIXELS=4,TILE_X_BITS=5,TILE_Y_BITS=3,SET_BITS=6)]]
    if args.only:
        selected = dict(mcu='mcu_readonly_client', pc='pc_video_boot', cache='rgb_tile_cache')[args.only]
        fixtures = [f for f in fixtures if f[1] == selected]
    for module, group in [('mcu_readonly_client','control'),('pc_video_boot','control'),('rgb_tile_cache','geometry')]:
        old = candidate / 'baseline/rtl' / group / (module + '.sv')
        original = old.read_text(encoding='utf-8')
        (source / (module + '_baseline.sv')).write_text(original.replace('module ' + module, 'module ' + module + '_baseline', 1), encoding='utf-8')
        paths.append(old)
    for vector in (fpga / 'sim/vectors/network_control').glob('*.hex'):
        shutil.copyfile(vector, run / vector.name)
        paths.append(vector)
    shutil.copyfile(__file__, run / 'verification_script.py')
    binary = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    modules = [source / 'frame_manager_pkg.sv'] + sorted(p for p in source.iterdir() if p.suffix in ('.sv','.v') and p.name != 'frame_manager_pkg.sv')
    initial_hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    result = dict(passed=False, four_state=True, pds_run=False, hardware_tested=False, cases=[], origins={})
    print('BLOCK_SOFTWARE', run, flush=True)
    try:
        for index, (bench, module, group, instance, params) in enumerate(fixtures):
            fixture = fpga / 'sim' / (bench + '.sv')
            paths.append(fixture)
            initial_hashes[str(fixture)] = hashlib.sha256(fixture.read_bytes()).hexdigest()
            original = fixture.read_text(encoding='utf-8')
            (run / (str(index) + '_original.sv')).write_text(original, encoding='utf-8')
            test = run / (str(index) + '_comparison.sv')
            differential = bench != 'tb_rgb_tile_cache_ways'
            test.write_text(comparison(original, (source / (module + '.sv')).read_text(), module, instance) if differential else original, encoding='utf-8')
            image = run / (str(index) + '.vvp')
            command = [str(binary / 'iverilog.exe'), '-g2012', '-I', str(source), '-s', bench, '-o', str(image)]
            command += ['-P' + bench + '.' + key + '=' + str(value) for key, value in params.items()]
            command += list(map(str, modules)) + [str(test)]
            record = dict(bench=bench, parameters=params, passed=False, cycle_equivalence=differential, commands=[command, [str(binary / 'vvp.exe'), str(image)]])
            result['cases'].append(record)
            for phase, cmd in zip(['compile', 'run'], record['commands']):
                proc = subprocess.run(cmd, cwd=run, input=b'', capture_output=True, timeout=240)
                output = proc.stdout + proc.stderr
                (run / (str(index) + '_' + phase + '.log')).write_bytes(output)
                if proc.returncode:
                    raise RuntimeError(output.decode(errors='replace')[-2500:])
            if b'PASS' not in output or (differential and b'BLOCK_DIFF_CHECKED' not in output) or b'FATAL' in output:
                raise RuntimeError('Scoreboard or differential did not finish')
            record.update(passed=True, summary=output.decode(errors='replace'))
            print(index, record['summary'][-500:], flush=True)
        result['passed'] = True
    finally:
        result['origins'] = initial_hashes
        result['inputs_intact'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in initial_hashes.items())
        result['passed'] &= result['inputs_intact']
        result['frozen_files'] = {p.relative_to(run).as_posix():hashlib.sha256(p.read_bytes()).hexdigest()
                                  for p in run.rglob('*') if p.is_file() and p.suffix in ('.sv','.v','.vh','.hex','.py')}
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('BLOCK_SOFTWARE_RESULT', run, flush=True)


if __name__ == '__main__':
    main()

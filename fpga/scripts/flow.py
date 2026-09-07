"""Reproducible offline PDS/ModelSim flow. Never opens a hardware programmer."""
import argparse
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[1]
CONFIG = json.loads((ROOT / 'config/toolchain.json').read_text(encoding='utf-8'))
PDS = Path(os.environ.get('PDS_ROOT', CONFIG['pds_root'])) / 'bin/pds_shell.exe'
MSIM = Path(os.environ.get('MODELSIM_BIN', CONFIG['modelsim_bin']))
ERROR = re.compile(r'(?im)^\s*(?:E:|C:|#\s*\*\*\s*(?:Error|Fatal)|\*\*\s*(?:Error|Fatal))|Check license failed|FLOW_SIM_FAIL|FLOW_MISMATCH')


def read_text(path):
    data = path.read_bytes()
    if data.startswith((b'\xff\xfe', b'\xfe\xff')):
        return data.decode('utf-16')
    return data.decode('utf-8', errors='replace')


def redact(text):
    # PDS prints the licence path, which can include a machine identifier.
    text = re.sub(r'(?im)(License checkout:.*? from )[^\r\n]+', r'\1<license_path_redacted>', text)
    value = os.environ.get('PANGO_LICENSE_FILE', '')
    if value:
        for token in [value, value.replace('\\', '/'), Path(value).name]:
            if len(token) > 4:
                text = text.replace(token, '<license_path_redacted>')
    return text


def sanitize_logs(directory):
    for path in directory.rglob('*'):
        if path.is_file() and (path.suffix.lower() in {'.log', '.tcl', '.bat', '.ini', '.pds'} or path.name == 'transcript'):
            data = read_text(path)
            safe = redact(data)
            if safe != data:
                path.write_text(safe, encoding='utf-8')


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load_license():
    if not os.environ.get('PANGO_LICENSE_FILE') and sys.platform == 'win32':
        import winreg
        try:
            with winreg.OpenKey(winreg.HKEY_CURRENT_USER, 'Environment') as key:
                value, _ = winreg.QueryValueEx(key, 'PANGO_LICENSE_FILE')
                os.environ['PANGO_LICENSE_FILE'] = os.path.expandvars(value)
        except FileNotFoundError:
            pass


def tool(exe, args, cwd, label, timeout=600):
    log = cwd / (label + '.log')
    started = time.monotonic()
    print('RUN', label, flush=True)
    with log.open('wb') as output:
        proc = subprocess.Popen([str(exe), *map(str, args)], cwd=cwd, stdout=output,
                                stderr=subprocess.STDOUT, creationflags=0x08000000 if sys.platform == 'win32' else 0)
        try:
            code = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            if sys.platform == 'win32':
                subprocess.run(['taskkill', '/PID', str(proc.pid), '/T', '/F'], capture_output=True)
            else:
                proc.kill()
            proc.wait()
            code = -1
    sanitize_logs(cwd)
    text = read_text(log)
    result = {'returncode': code, 'elapsed_seconds': round(time.monotonic() - started, 3),
              'log': str(log.relative_to(ROOT)), 'error_lines': [line for line in text.splitlines() if ERROR.search(line)]}
    print('DONE', label, 'returncode=', code, 'errors=', len(result['error_lines']), flush=True)
    return result


def doctor(directory):
    result = {'utc': datetime.now(timezone.utc).isoformat(), 'license_configured': bool(os.environ.get('PANGO_LICENSE_FILE')),
              'pds_exists': PDS.is_file(), 'modelsim_exists': (MSIM / 'vsim.exe').is_file(),
              'board': json.loads((ROOT / 'config/board.json').read_text(encoding='utf-8'))}
    for label, exe, arg, expected in [('pds_version', PDS, '-version', CONFIG['pds_expected']),
                                     ('modelsim_version', MSIM / 'vsim.exe', '-version', CONFIG['modelsim_expected'])]:
        if exe.is_file():
            outcome = tool(exe, [arg], directory, label, 30)
            outcome['version_matches'] = expected in read_text(directory / (label + '.log'))
            result[label] = outcome
    result['passed'] = all(result[k] for k in ['license_configured', 'pds_exists', 'modelsim_exists']) and all(
        result.get(k, {}).get('version_matches', False) for k in ['pds_version', 'modelsim_version'])
    result['license_functional_check'] = 'requires actual synthesis; variable existence alone is insufficient'
    (directory / 'doctor.json').write_text(json.dumps(result, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    return result


def simulate(directory, stage, build=None, simlib=None):
    work = directory / stage
    work.mkdir(parents=True, exist_ok=False)
    commands = ['onerror {quit -code 2 -force}', 'onbreak {quit -code 3 -force}', 'vlib work', 'vmap work work']
    library_args = ''
    if stage != 'rtl':
        if not build or not simlib:
            raise ValueError('Gate simulation requires --build-dir and --simlib-dir')
        lib = 'usim' if stage == 'synthesis' else 'vsim'
        commands.append(f'vmap {lib} {{{(simlib / lib).as_posix()}}}')
        library_args = '-L ' + lib
    if stage == 'rtl':
        design = ROOT / 'rtl/flow_smoke_top.v'
    elif stage == 'synthesis':
        design = build / 'synthesize/flow_smoke_top_syn.vm'
    else:
        design = build / 'generate_netlist/flow_smoke_top_sim.v'
    commands.append(f'vlog {{{design.as_posix()}}} {{{(ROOT / "sim/tb_flow_smoke.v").as_posix()}}}')
    sdf_args = ''
    if stage.startswith('timing_'):
        sdf = build / 'generate_netlist/flow_smoke_top_sta.sdf'
        corner = stage.split('_', 1)[1]
        sdf_args = f'-sdf{corner} {{/tb_flow_smoke/dut={sdf.as_posix()}}}'
    commands += [f'vsim -voptargs=+acc -t 1ps {library_args} {sdf_args} work.tb_flow_smoke',
                 'log -r /tb_flow_smoke/*', 'run -all', 'quit -code 0 -force']
    (work / 'run.do').write_text('\n'.join(commands)+'\n', encoding='utf-8')
    # Local ini copy prevents vmap from changing the simulator installation.
    tool(MSIM / 'vmap.exe', ['-c'], work, 'local_ini', 30)
    result = tool(MSIM / 'vsim.exe', ['-c', '-modelsimini', str(work / 'modelsim.ini'), '-l', str(work / 'transcript'), '-do', 'run.do'], work, 'simulate', 180)
    text = read_text(work / 'simulate.log')
    marker = re.search(r'FLOW_SIM_PASS checks=(\d+) toggles=(\d+)', text)
    result['passed'] = result['returncode'] == 0 and not result['error_lines'] and marker is not None
    result['functional_passed'] = result['passed']
    result['design_sha256'] = sha(design)
    result['testbench_sha256'] = sha(ROOT / 'sim/tb_flow_smoke.v')
    if marker:
        result.update(checks=int(marker[1]), toggles=int(marker[2]))
    if stage.startswith('timing_'):
        result['sdf_annotation_requested'] = True
        result['sdf_annotation_completed'] = 'SDF Backannotation Successfully Completed.' in text
        result['sdf_sha256'] = sha(sdf)
        result['timing_warnings'] = [line for line in text.splitlines() if re.search(r'(?i)warning|violation', line)]
        result['passed'] = result['passed'] and result['sdf_annotation_completed'] and not result['timing_warnings']
    (work / 'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    return result


def build(directory):
    inputs = {str(p.relative_to(ROOT)): sha(p) for folder in ['rtl', 'constraints', 'config', 'sim', 'scripts']
              for p in (ROOT / folder).rglob('*') if p.is_file()}
    (directory / 'inputs.json').write_text(json.dumps(inputs, indent=2)+'\n', encoding='utf-8')
    result = tool(PDS, ['-file', ROOT / 'scripts/build.tcl', '-work_dir', directory, '-project_name', 'flow_smoke'], directory, 'console', 900)
    log = read_text(directory / 'console.log')
    stages = ['compile', 'synthesize', 'dev_map', 'pnr', 'report_timing', 'gen_netlist', 'gen_bit_stream', 'report_power']
    result['stages'] = {x: f'FLOW_STAGE_PASS {x}' in log for x in stages}
    artifacts = ['generate_bitstream/flow_smoke_top.sbit', 'synthesize/flow_smoke_top_syn.vm',
                 'generate_netlist/flow_smoke_top_sim.v', 'generate_netlist/flow_smoke_top_sta.sdf',
                 'report_timing/flow_smoke_top.rtr', 'report_power/flow_smoke_top.ppr']
    result['artifacts'] = {x: {'bytes': (directory / x).stat().st_size, 'sha256': sha(directory / x)}
                           for x in artifacts if (directory / x).is_file()}
    from report import timing_summary
    result['timing'] = timing_summary(directory)
    result['passed'] = result['returncode'] == 0 and not result['error_lines'] and all(result['stages'].values()) and len(result['artifacts']) == len(artifacts) and result['timing']['passed']
    result['hardware_acceptance'] = 'not_performed'
    (directory / 'build_result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('action', choices=['doctor', 'test', 'build', 'simlib', 'sanitize'])
    parser.add_argument('--out', type=Path, required=True, help='New directory inside fpga/build')
    parser.add_argument('--stage', choices=['rtl', 'synthesis', 'route_function', 'timing_min', 'timing_max', 'all'], default='rtl')
    parser.add_argument('--build-dir', type=Path)
    parser.add_argument('--simlib-dir', type=Path)
    args = parser.parse_args()
    directory = args.out.resolve()
    if not directory.is_relative_to((ROOT / 'build').resolve()):
        parser.error('--out must remain inside fpga/build')
    load_license()
    if args.action == 'sanitize':
        sanitize_logs(directory)
        return 0
    directory.mkdir(parents=True, exist_ok=False)
    if args.action == 'doctor':
        result = doctor(directory)
    elif args.action == 'build':
        result = build(directory)
    elif args.action == 'simlib':
        os.environ['FLOW_MODELSIM_BIN'] = MSIM.as_posix()
        os.environ['FLOW_SIMLIB_DIR'] = directory.as_posix()
        result = tool(PDS, ['-file', ROOT / 'scripts/simlib.tcl', '-work_dir', directory, '-project_name', 'simlib'], directory, 'console', 900)
        logs = read_text(directory / 'console.log')
        if (directory / 'transcript').is_file():
            logs += '\n' + read_text(directory / 'transcript')
        result['passed'] = result['returncode'] == 0 and not ERROR.search(logs) and 'Compile libraries succeed.' in logs and 'FLOW_SIMLIB_COMMAND_DONE' in logs
        (directory / 'simlib_result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    else:
        stages = ['rtl', 'synthesis', 'route_function', 'timing_min', 'timing_max'] if args.stage == 'all' else [args.stage]
        results = {stage: simulate(directory, stage, args.build_dir.resolve() if args.build_dir else None,
                                   args.simlib_dir.resolve() if args.simlib_dir else None) for stage in stages}
        result = {'passed': all(x['passed'] for x in results.values()), 'stages': results}
        (directory / 'tests.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
    print(json.dumps(result, ensure_ascii=False, indent=2))
    return 0 if result['passed'] else 1


if __name__ == '__main__':
    raise SystemExit(main())

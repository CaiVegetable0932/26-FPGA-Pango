"""Freeze and verify the board MCU adapter and its actual PC UART entry point."""
from datetime import datetime
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Keep inputs, logs and tool identity together; stdin is valid on Windows."""
    fpga = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--peer-vectors', type=Path,
                        help='Directory of verified 22452f3 C-generated hex frames')
    options = parser.parse_args()
    run = fpga / 'build/mcu_link_20261023' / datetime.now().strftime('regression_%Y%m%d_%H%M%S')
    source = run / 'source'
    source.mkdir(parents=True)
    cases = ['mcu_link_adapter', 'mcu_readonly_client', 'pc_mcu_link', 'uart_v2_parser', 'uart_8n1']
    paths = [fpga / 'rtl/memory/frame_manager_pkg.sv'] + list((fpga / 'rtl/control').glob('*.sv'))
    paths += [fpga / f'sim/tb_{case}.sv' for case in cases]
    if options.peer_vectors:
        paths.append(fpga / 'sim/tb_mcu_uart_peer.sv')
    manifest = {}
    for path in paths:
        relative = path.relative_to(fpga)
        dest = source / relative
        dest.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(path, dest)
        manifest[relative.as_posix()] = hashlib.sha256(dest.read_bytes()).hexdigest()
    for path in (fpga / 'sim/vectors/network_control').glob('*.hex'):
        shutil.copyfile(path, run / path.name)
        manifest[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    shutil.copyfile(__file__, run / 'simulation_script.py')
    (run / 'sources.json').write_text(json.dumps(manifest, indent=2))
    home = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    def execute(args, name, timeout=120, cwd=None):
        result = subprocess.run(list(map(str,args)), cwd=cwd or run, input='', capture_output=True,
                                text=True, timeout=timeout)
        output = result.stdout + result.stderr
        (run / name).write_text(output, encoding='utf-8')
        if result.returncode:
            raise RuntimeError(f'{name}: {result.returncode}: {output[-3000:]}')
        return output
    execute([home / 'iverilog.exe', '-V'], 'compiler.log')
    results = {}
    for case in cases:
        image = run / (case + '.vvp')
        execute([home / 'iverilog.exe', '-g2012', '-s', 'tb_'+case, '-o', image,
                 source / 'rtl/memory/frame_manager_pkg.sv',
                 *sorted((source / 'rtl/control').glob('*.sv')), source / f'sim/tb_{case}.sv'], case+'.compile.log')
        output = execute([home / 'vvp.exe', image], case+'.log')
        if 'PASS' not in output or 'FATAL' in output:
            raise RuntimeError(case+': missing PASS')
        results[case] = True
        print(case + ': PASS', flush=True)
    if options.peer_vectors:
        # Keep firmware vectors separate: the synthetic selector/client cases
        # above intentionally use a different STATE fixture with its own hash.
        peer = run / 'peer'
        peer.mkdir()
        hashes = {}
        for name in ('config', 'info', 'open', 'stream', 'sync', 'state', 'reconnect_event'):
            path = options.peer_vectors.resolve() / (name + '.hex')
            shutil.copyfile(path, peer / path.name)
            hashes[path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
        (peer / 'vectors.json').write_text(json.dumps(dict(origin=str(options.peer_vectors.resolve()),
            sha256=hashes), indent=2))
        image = peer / 'uart.vvp'
        execute([home / 'iverilog.exe', '-g2012', '-s', 'tb_mcu_uart_peer', '-o', image,
                 source / 'rtl/memory/frame_manager_pkg.sv',
                 *sorted((source / 'rtl/control').glob('*.sv')), source / 'sim/tb_mcu_uart_peer.sv'],
                'peer.compile.log')
        output = execute([home / 'vvp.exe', image], 'peer.log', timeout=180, cwd=peer)
        if 'MCU_UART_PEER_PASS' not in output or 'FATAL' in output:
            raise RuntimeError('MCU UART peer failed')
        results['mcu_uart_peer'] = True
        print('mcu_uart_peer: PASS', flush=True)
    (run / 'result.json').write_text(json.dumps(dict(passed=True, cases=results,
        hardware_tested=False, bitstream_generated=False), indent=2))
    print('MCU_LINK_REGRESSION_PASS', run, flush=True)


if __name__ == '__main__':
    main()

"""Freeze and verify production DMA write CDC first-capture behavior.

The native timing exception remains subject to a new PDS constraint/netlist
check. This runner only compiles Icarus and never invokes PDS or bitgen.
"""
from datetime import datetime
from pathlib import Path
import hashlib
import json
import re
import shutil
import subprocess


def main():
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/core_area_20261023' / datetime.now().strftime('dma_write_capture_%H%M%S_%f')
    run.mkdir(parents=True)
    paths = [fpga / 'rtl/memory/dma_write_cdc.sv', fpga / 'sim/tb_dma_write_capture.sv',
             fpga / 'constraints/video_system/processing_cdc.fdc']
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    for p in paths:
        shutil.copyfile(p, run / p.name)
    shutil.copyfile(__file__, run / 'verification_script.py')
    tool = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(passed=False, inputs=hashes, tools={str(tool / n): hashlib.sha256((tool / n).read_bytes()).hexdigest()
                  for n in ['iverilog.exe', 'vvp.exe']}, tests=[], physical_signed_off=False, bitstream_generated=False)
    try:
        for ch, mh, phase in [(3.333, 4, .7), (4, 3.333, 1.1), (5, 3.1, 0), (3.333, 4, 3.9)]:
            name = f'c{ch}_m{mh}_p{phase}'
            commands = [('compile', [str(tool / 'iverilog.exe'), '-g2012', '-s', 'tb_dma_write_capture',
                         f'-Ptb_dma_write_capture.CLIENT_HALF={ch}', f'-Ptb_dma_write_capture.MEMORY_HALF={mh}',
                         f'-Ptb_dma_write_capture.MEMORY_PHASE={phase}', '-o', name + '.vvp',
                         'dma_write_cdc.sv', 'tb_dma_write_capture.sv']),
                        ('run', [str(tool / 'vvp.exe'), name + '.vvp'])]
            for stage, command in commands:
                child = subprocess.run(command, cwd=run, input=b'', capture_output=True, timeout=120)
                output = child.stdout + child.stderr
                (run / (name + '_' + stage + '.log')).write_bytes(output)
                if child.returncode:
                    raise RuntimeError(output.decode(errors='replace'))
            match = re.search(rb'DMA_WRITE_CAPTURE_PASS cases=(\d+) requests=(\d+) beats=(\d+) errors=(\d+) cancels=(\d+) stalls=(\d+) first_stalls=(\d+)', output)
            if not match:
                raise RuntimeError('Independent data/ownership scoreboard did not complete')
            result['tests'].append(dict(client_half_ns=ch, memory_half_ns=mh, phase_ns=phase,
                passed=True, counts=dict(zip(['cases', 'requests', 'beats', 'errors', 'cancels', 'stalls', 'first_stalls'],
                                            map(int, match.groups())))))
            print(name, match[0].decode(), flush=True)
        # This validates intended source syntax only; actual object/arc matching
        # must be checked in the next native CCR and synthesized netlist.
        fdc = (run / 'processing_cdc.fdc').read_text(encoding='utf-8')
        result['constraint_source_checks'] = {
            'bounded_first_capture': 'set_max_delay 6.0 -datapath_only -from [get_clocks {processing_clk}] -to [get_cells -hierarchical {core.processor.result_bridge.read_q*}]' in fdc,
            'hold_only_first_capture': 'set_false_path -hold -from [get_clocks {processing_clk}] -to [get_cells -hierarchical {core.processor.result_bridge.read_q*}]' in fdc,
            'capture_retiming_disabled': '(* syn_allow_retiming=0 *) reg [287:0] read_q;' in (run / 'dma_write_cdc.sv').read_text(encoding='utf-8')}
        result['passed'] = all(result['constraint_source_checks'].values())
    finally:
        result['inputs_intact'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest() == h for p, h in hashes.items())
        result['snapshot_intact'] = all(hashlib.sha256((run / Path(p).name).read_bytes()).hexdigest() == h for p, h in hashes.items())
        result['passed'] &= result['inputs_intact'] and result['snapshot_intact']
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print('DMA_WRITE_CAPTURE_PROOF', run, flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

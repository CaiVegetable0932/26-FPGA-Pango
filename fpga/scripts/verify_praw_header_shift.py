"""Run exact old/new PRAW output comparisons without launching PDS.

This gate proves covered packet-engine behavior only. Full integration, host
decoding, native resource evidence and routed STA remain separate requirements.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Freeze both sources and the fixture, retain every log and input digest."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):
        raise ValueError('Frozen FPGA candidate required')
    source = candidate/'source/rtl/network/praw_udp_tx.sv'
    baseline = candidate/'original_praw_udp_tx.sv'
    fixture = fpga/'sim/tb_praw_header_differential.sv'
    golden_fixture = fpga/'sim/tb_praw_packets.sv'
    mac = candidate/'source/rtl/network/ethernet_mac_tx.sv'
    vectors = sorted((fpga/'sim/vectors/network_control').glob('tiny_*.hex'))
    if {p.name for p in vectors} != {'tiny_wire.hex', *(f'tiny_header_{n}.hex' for n in range(4))}:
        raise ValueError('Expected independent host-generated packet vectors')
    run = candidate/datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__, run/'verification_script.py')
    shutil.copyfile(fixture, run/fixture.name)
    shutil.copyfile(golden_fixture, run/golden_fixture.name)
    shutil.copyfile(mac, run/mac.name)
    for vector in vectors:
        shutil.copyfile(vector, run/vector.name)
    shutil.copyfile(source, run/'candidate.sv')
    old = baseline.read_text()
    if old.count('module praw_udp_tx #') != 1:
        raise ValueError('Unexpected reference declaration')
    (run/'baseline.sv').write_text(old.replace('module praw_udp_tx #', 'module baseline_praw_udp_tx #', 1))
    result = dict(passed=False, cycle_equivalent=False, inputs_intact=False,
        inputs={str(p): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in (source, baseline, fixture, golden_fixture, mac, *vectors)},
        jobs=[], native_synthesis_started=False, board_timing_signoff=False)
    tool = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    print('PRAW_DIFFERENTIAL', run, flush=True)
    try:
        for banks in (1, 2):
            image = run/f'compare_{banks}.vvp'
            commands = [('compile', [str(tool/'iverilog.exe'), '-g2012', '-s', 'tb_praw_header_differential',
                f'-Ptb_praw_header_differential.BANKS={banks}', '-o', str(image), str(run/'candidate.sv'),
                str(run/'baseline.sv'), str(run/fixture.name)]), ('run', [str(tool/'vvp.exe'), str(image)])]
            for phase, command in commands:
                log = run/f'{phase}_{banks}.log'
                with log.open('wb') as output:
                    child = subprocess.run(command, cwd=run, stdout=output, stderr=subprocess.STDOUT,
                        timeout=180, creationflags=0x08000000)
                text = log.read_text(errors='replace')
                result['jobs'].append(dict(phase=phase, banks=banks, exit=child.returncode))
                if child.returncode or (phase == 'run' and 'PRAW_HEADER_DIFFERENTIAL_PASS' not in text):
                    raise RuntimeError(text[-2000:])
                if phase == 'run':
                    print(text.strip(), flush=True)
        # The existing host-golden fixture independently checks actual Ethernet
        # bytes, PRAW CRC, odd/even UDP checksums, maximum payload and MAC FCS.
        image = run/'golden.vvp'
        commands = [('golden_compile', [str(tool/'iverilog.exe'), '-g2012', '-s', 'tb_praw_packets',
            '-o', str(image), str(run/'candidate.sv'), str(run/mac.name), str(run/golden_fixture.name)]),
            ('golden_run', [str(tool/'vvp.exe'), str(image)])]
        for phase, command in commands:
            log = run/(phase+'.log')
            with log.open('wb') as output:
                child = subprocess.run(command, cwd=run, stdout=output, stderr=subprocess.STDOUT,
                    timeout=180, creationflags=0x08000000)
            text = log.read_text(errors='replace')
            result['jobs'].append(dict(phase=phase, exit=child.returncode))
            if child.returncode or (phase == 'golden_run' and 'PRAW_PACKETS_PASS bytes=3303 peak_banks=2' not in text):
                raise RuntimeError(text[-2000:])
            if phase == 'golden_run':
                print(text.strip(), flush=True)
                result['host_golden_packet_bytes'] = 3303
        result['inputs_intact'] = all(hashlib.sha256(Path(n).read_bytes()).hexdigest() == h
            for n, h in result['inputs'].items())
        if not result['inputs_intact']:
            raise ValueError('Proof inputs changed')
        result.update(passed=True, cycle_equivalent=True)
    finally:
        (run/'result.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()

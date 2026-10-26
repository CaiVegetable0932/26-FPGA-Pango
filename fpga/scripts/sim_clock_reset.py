"""Run reset/startup and RGMII tests with unchanged installed PDS models.

Icarus can execute the unencrypted GRS/CLKBUF/IDDR/ODDR models. Encrypted
OSERDES is deliberately excluded and requires the separate licensed native
ModelSim runner; this fallback does not establish TMDS/electrical correctness.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

FPGA = Path(__file__).resolve().parents[1]


def main():
    """Record exact source/model hashes and require a pass marker per case."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--icarus-home', type=Path, default=FPGA / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin')
    parser.add_argument('--pds-home', type=Path, default=Path('E:/PDS_Pangu/PDS_2022.2-SP6.4'))
    args = parser.parse_args()
    run = FPGA / 'build/clock_reset_20261012' / datetime.now().strftime('icarus_%Y%m%d_%H%M%S_%f')
    vendor = run / 'vendor'
    vendor.mkdir(parents=True)
    native = args.pds_home / 'arch/vendor/pango/verilog/simulation'
    models = []
    for name in ('GTP_GRS', 'GTP_CLKBUFG', 'GTP_IDDR_E1', 'GTP_ODDR_E1'):
        dest = vendor / (name+'.v')
        shutil.copyfile(native / dest.name, dest)
        models.append(dest)
    sources = [FPGA / name for name in ('rtl/board/reset_sync.v', 'rtl/board/video_clock_start.v',
                'rtl/board/rgmii_phy_io.v', 'sim/tb_board_io.sv', 'sim/tb_video_clock_start.sv')]
    hashes = {str(p): hashlib.sha256(p.read_bytes()).hexdigest() for p in sources+models}
    (run / 'source_hashes.json').write_text(json.dumps(hashes, indent=2)+'\n')
    (run / 'vendor_source.json').write_text(json.dumps(dict(source=str(native), version='2022.2-SP6.4', modifications='none'), indent=2)+'\n')
    summary = dict(passed=False, cases={}, tmds_verified=False, hardware_tested=False, programmed=False)
    # Bounded subprocess execution and saved stdout prevent a timeout, error or
    # bare exit zero from being mistaken for a completed functional regression.
    try:
        for case, marker in (('video_clock_start', 'VIDEO_START_PASS'), ('board_io', 'BOARD_IO_PASS')):
            compile_args = [str(args.icarus_home / 'iverilog.exe'), '-g2012', '-s', 'tb_'+case, '-o', str(run / (case+'.vvp'))]
            compile_args += [str(p) for p in sources+models]
            for step, cmd in (('compile', compile_args), ('run', [str(args.icarus_home / 'vvp.exe'), str(run / (case+'.vvp'))])):
                result = subprocess.run(cmd, cwd=run, capture_output=True, text=True, timeout=120)
                output = result.stdout+result.stderr
                (run / f'{case}.{step}.log').write_text(output, encoding='utf-8')
                if result.returncode or (step=='run' and marker not in output):
                    raise RuntimeError(f'{case} {step} failed: {output[-2000:]}')
            summary['cases'][case] = output.strip()
        summary['passed'] = True
    finally:
        (run / 'result.json').write_text(json.dumps(summary, indent=2)+'\n')
        print(json.dumps(summary), flush=True)
        print('CLOCK_RESET_ICARUS_EVIDENCE '+str(run))


if __name__ == '__main__':
    main()

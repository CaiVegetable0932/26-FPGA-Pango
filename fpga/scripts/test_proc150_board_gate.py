"""Real CLI negative checks: experimental board snapshots can never request PnR/bitgen."""
from pathlib import Path
from datetime import datetime
import hashlib,json,subprocess,sys

def main():
    f=Path(__file__).resolve().parents[1]
    run=f/'build/route_optimization'/datetime.now().strftime('proc150_board_gate_%Y%m%d_%H%M%S_%f');run.mkdir()
    before=set((f/'build/full_integration_20261013').glob('board_*'))
    gate=f/'config/implementation_readiness.json';digest=hashlib.sha256(gate.read_bytes()).hexdigest()
    tests=[]
    for stage in ['report_timing','gen_bit_stream']:
        process=subprocess.run([sys.executable,str(f/'scripts/build_video_system.py'),'--experimental-proc150',
            '--rtl-snapshot',str(run/'intentionally_absent'),'--stage',stage],capture_output=True,timeout=30)
        (run/(stage+'.log')).write_bytes(process.stdout+process.stderr)
        assert process.returncode==2 and b'compile/SYN/MAP only' in process.stderr
        tests.append(dict(stage=stage,rejected_before_native_launch=True))
    assert before==set((f/'build/full_integration_20261013').glob('board_*'))
    assert hashlib.sha256(gate.read_bytes()).hexdigest()==digest
    (run/'result.json').write_text(json.dumps(dict(passed=True,tests=tests,no_new_board_build=True,readiness_unchanged=True),indent=2))
    print('PROC150_BOARD_GATE_PASS',run)

if __name__=='__main__':main()

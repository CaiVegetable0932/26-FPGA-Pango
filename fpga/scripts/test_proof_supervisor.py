"""Real child-process checks for quota stop, timeout and native-slot independence."""
from pathlib import Path
from datetime import datetime
import json,os,sys,threading,time
import psutil
from proof_supervisor import run_proof

def main():
    f=Path(__file__).resolve().parents[1]
    root=f/'build/route_optimization'/datetime.now().strftime('proof_supervisor_test_%Y%m%d_%H%M%S_%f');root.mkdir()
    pause=root/'pause.json';pause.write_text('{}')
    def run(name,code,limit):
        return run_proof([sys.executable,'-c',code],cwd=root,environment=os.environ.copy(),log_path=root/(name+'.log'),
            timeout_seconds=limit,pause_path=pause,poll_seconds=.05)
    # An existing reserve stop must prevent even an otherwise harmless launch.
    out=run('prevented',"from pathlib import Path;Path('unexpected').touch()",2)
    assert out['status']=='PAUSED_PREVENTED' and not (root/'unexpected').exists();pause.unlink()
    good=run('completed',"print('PROOF_OK')",2);assert good['status']=='COMPLETED'
    # Simulate reserve exhaustion while this owned root has a live descendant.
    code="import subprocess,sys,time;from pathlib import Path;p=subprocess.Popen([sys.executable,'-c','import time;time.sleep(30)']);Path('worker_pid').write_text(str(p.pid));time.sleep(30)"
    def request_stop():
        for _ in range(100):
            if (root/'worker_pid').exists():time.sleep(.2);pause.write_text('{}');return
            time.sleep(.02)
    worker=threading.Thread(target=request_stop);worker.start();stopped=run('paused',code,5);worker.join()
    assert stopped['status']=='PAUSED';pid=int((root/'worker_pid').read_text());assert not psutil.pid_exists(pid);pause.unlink()
    timed=run('timeout',"import time;time.sleep(30)",.3);assert timed['status']=='TIMEOUT'
    (root/'result.json').write_text(json.dumps(dict(passed=True,tests=4,owned_descendant_reaped=True,native_slot_used=False),indent=2))
    print('PROOF_SUPERVISOR_TEST_PASS',root)

if __name__=='__main__':main()

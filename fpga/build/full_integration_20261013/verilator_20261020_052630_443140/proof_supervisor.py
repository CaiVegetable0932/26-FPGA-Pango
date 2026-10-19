"""Bound software proof processes without taking the exclusive native PDS slot."""
from pathlib import Path
from datetime import datetime,timezone
import json,os,subprocess,time
from route_supervisor import process_resources,live_descendants,stop_owned

def run_proof(command,*,cwd,environment,log_path,timeout_seconds,pause_path,poll_seconds=2):
    """Observe a session reserve stop and reap only this proof's owned PID tree."""
    if timeout_seconds<=0 or poll_seconds<=0:raise ValueError('Positive proof budgets required')
    log_path=Path(log_path);monitor=log_path.with_suffix('.monitor.jsonl')
    policy=dict(timeout_seconds=timeout_seconds,pause_path=str(pause_path),poll_seconds=poll_seconds,native_slot_used=False)
    log_path.with_suffix('.policy.json').write_text(json.dumps(policy,indent=2))
    start=time.monotonic();known={};child=None;last_record=-30
    with log_path.open('wb') as log,monitor.open('a',encoding='utf-8') as stream:
        def record(status,code):
            row=dict(at=datetime.now(timezone.utc).isoformat(),status=status,returncode=code,
                elapsed_seconds=time.monotonic()-start,pid=child.pid if child else None)
            stream.write(json.dumps(row)+'\n');stream.flush();return row
        if pause_path and Path(pause_path).exists():return record('PAUSED_PREVENTED',130)
        options=dict(creationflags=0x08000000) if os.name=='nt' else dict(start_new_session=True)
        child=subprocess.Popen(command,cwd=cwd,env=environment,stdout=log,stderr=subprocess.STDOUT,**options)
        try:
            while True:
                resources=process_resources(child.pid)
                for row in resources.get('processes',[]):
                    if row['pid']!=child.pid:known[row['pid']]=row
                code=child.poll();elapsed=time.monotonic()-start
                if code is not None:
                    if live_descendants(known):
                        stop_owned(child,known);return record('ORPHANED',1)
                    return record('COMPLETED' if code==0 else 'FAILED',code)
                status='PAUSED' if pause_path and Path(pause_path).exists() else 'TIMEOUT' if elapsed>=timeout_seconds else None
                if status:
                    stop_owned(child,known);return record(status,130 if status=='PAUSED' else 124)
                if elapsed-last_record>=30:record('RUNNING',None);last_record=elapsed
                time.sleep(min(poll_seconds,max(.01,timeout_seconds-elapsed)))
        except BaseException:
            stop_owned(child,known);raise

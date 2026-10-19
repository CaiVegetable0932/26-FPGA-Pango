"""Run reviewed unit screens after a complete route reaches a terminal state.

Only the two source-bound unit screens in this campaign are accepted. No seed
sweep, replacement of running builds or automatic promotion is performed.
Account reserve and the session stop file apply between and during jobs.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import subprocess
import sys
import time
from observe_video_routes import process_inventory
from optimization_status import latest_quota


def write_state(path, state):
    """Atomically publish the ledger so observers never read partial JSON."""
    state['updated_at'] = datetime.now(timezone.utc).isoformat()
    temporary = path.with_suffix('.tmp')
    temporary.write_text(json.dumps(state,indent=2)+'\n',encoding='utf-8')
    temporary.replace(path)


def main():
    """Enforce a single native queue without bypassing prior campaign state."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--plan',type=Path,required=True)
    parser.add_argument('--check',action='store_true')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    path = args.plan.resolve()
    if not path.is_relative_to(fpga/'build/route_optimization'):
        raise ValueError('Reviewed queue plans belong under route_optimization')
    plan = json.loads(path.read_text(encoding='utf-8'))
    allowed = {'probe_dma_owner_mapping.py','probe_boot_capture_mapping.py'}
    if not 1 <= len(plan['jobs']) <= 2 or any(j['script'] not in allowed for j in plan['jobs']):
        raise ValueError('A review round permits at most these two unit screens')
    session = path.parent
    campaign = Path(plan['wait_for_campaign']).resolve()
    if not campaign.is_relative_to(session) or not (session/'session.json').is_file():
        raise ValueError('Queue must bind to this authorized session and route campaign')
    if args.check:
        print(json.dumps(plan,indent=2))
        return
    ledger = session/'unit_queue.json'
    if ledger.exists():
        raise ValueError('Queue already has a ledger; review it rather than rerunning silently')
    state = dict(status='WAITING_FOR_ROUTE',jobs=[],plan=str(path),wait_for_campaign=str(campaign))
    write_state(ledger,state)
    stop = session/'stop_requested.json'

    def reserve_allows():
        """Require a recent explicit account observation before starting work."""
        quota = latest_quota(Path.home()/'.codex/sessions')
        state['quota'] = quota
        if not quota['available']:
            return False
        age = (datetime.now(timezone.utc)-datetime.fromisoformat(quota['at'].replace('Z','+00:00'))).total_seconds()
        if quota['remaining_percent'] <= 10:
            stop.write_text(json.dumps(dict(reason='Codex quota reserve reached',quota=quota)))
        return age < 300 and quota['remaining_percent'] > 10

    # Wait for the authoritative campaign ledger, not a disappearing console
    # window or a partially emitted native result. Observe other user jobs too.
    while True:
        allowed_now = reserve_allows()
        if stop.exists():
            state['status']='STOPPED';write_state(ledger,state);return
        try:
            prior=json.loads(campaign.read_text(encoding='utf-8'))
        except (FileNotFoundError,json.JSONDecodeError):
            prior={}
        terminal=prior.get('phase') in ('native_failed','packaged','package_failed')
        if terminal and allowed_now and not process_inventory() and not (fpga/'build/route_optimization/native_phase.lock').exists():
            break
        state['status']='WAITING_FOR_ROUTE' if not terminal else 'WAITING_FOR_QUOTA_OR_NATIVE_SLOT'
        write_state(ledger,state)
        time.sleep(30)
    for job in plan['jobs']:
        while not reserve_allows():
            if stop.exists():
                state['status']='STOPPED';write_state(ledger,state);return
            state['status']='WAITING_FOR_FRESH_QUOTA';write_state(ledger,state);time.sleep(30)
        if stop.exists() or process_inventory():
            state['status']='STOPPED_BEFORE_NEXT_JOB';write_state(ledger,state);return
        command=[sys.executable,str(fpga/'scripts'/job['script']),*job['arguments'],
                 '--pause-file',str(stop)]
        record=dict(id=job['id'],command=command,status='RUNNING',
                    started_at=datetime.now(timezone.utc).isoformat())
        state['jobs'].append(record);state['status']='RUNNING_UNIT_SCREEN'
        log_path=session/(job['id']+'.log')
        with log_path.open('wb') as log:
            child=subprocess.Popen(command,cwd=fpga.parent,stdout=log,stderr=subprocess.STDOUT,
                                   creationflags=0x08000000)
            record['pid']=child.pid;write_state(ledger,state)
            while child.poll() is None:
                reserve_allows()
                # The child supervisor owns native cleanup. Never kill this
                # Python driver and leave its native worker unsupervised.
                write_state(ledger,state);time.sleep(30)
            record.update(exit=child.returncode,status='PASSED' if child.returncode==0 else 'FAILED',
                          finished_at=datetime.now(timezone.utc).isoformat())
            print(json.dumps(record),flush=True)
            write_state(ledger,state)
        if stop.exists():
            state['status']='STOPPED';write_state(ledger,state);return
    state['status']='SCREENS_FINISHED_REVIEW_REQUIRED'
    write_state(ledger,state)


if __name__ == '__main__':
    main()

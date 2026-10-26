"""Wait for the existing native owner, then screen area candidates serially.

This foreground task runner never stops another PDS process, changes a gate,
or removes a lock. A local pause file cancels only this queue between jobs.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import time


def sha(p):
    """Detect script/proof drift while another task owns the native tool."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Run each reviewed proof-bound SYN pair only after exclusive ownership."""
    # Native/tool diagnostics may contain non-GBK characters. Preserve raw log
    # bytes and use UTF-8 for this process and its Python screen children so a
    # diagnostic print cannot hide the actual native failure/result record.
    sys.stdout.reconfigure(encoding='utf-8',errors='backslashreplace')
    os.environ['PYTHONIOENCODING']='utf-8'
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--jobs-json',type=Path,required=True)
    parser.add_argument('--wait-for-result',type=Path,help='Wait for the complete external task, including all of its native phases')
    parser.add_argument('--wait-for-passed-result',type=Path,help='Wait for a preceding owned queue to finish successfully')
    parser.add_argument('--screen-script',type=Path,help='Explicit supplemental screen driver, frozen by hash before waiting')
    a=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    jobs=json.loads(a.jobs_json.read_text());script=a.screen_script.resolve() if a.screen_script else fpga/'scripts/screen_area60_candidate.py'
    if not script.is_relative_to(fpga):raise ValueError('Screen driver must remain inside fpga')
    run=fpga/'build/area60_20261025'/datetime.now().strftime('screen_queue_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(a.jobs_json,run/'jobs.json');shutil.copyfile(__file__,run/'queue_script.py')
    origins={str(p):sha(p) for p in (script,fpga/'scripts/route_supervisor.py',fpga/'scripts/regional_scan_wrapper.py')}
    for job in jobs:
        p=Path(job['proof'])/'result.json';proof=json.loads(p.read_text());assert proof['passed'] and proof['inputs_intact'];origins[str(p)]=sha(p)
    result=dict(passed=False,jobs=[],origins=origins,other_native_stopped=False,wait_for_result=str(a.wait_for_result) if a.wait_for_result else None,
                wait_for_passed_result=str(a.wait_for_passed_result) if a.wait_for_passed_result else None)
    (run/'identity.json').write_text(json.dumps(dict(queue_pid=__import__('os').getpid(),origins=origins),indent=2))
    print('SCREEN_QUEUE',run,flush=True)
    try:
        for number,job in enumerate(jobs):
            deadline=time.monotonic()+7200
            # A released lock between PnR and STA is not completion of the
            # external task. Its final result must exist before this queue
            # competes for the shared native phase lock.
            def predecessor_passed():
                # A queue writes intermediate results with passed=false. Do not
                # steal the native slot between its individual SYN comparisons.
                if not a.wait_for_passed_result:return True
                try:return json.loads(a.wait_for_passed_result.read_text()).get('passed') is True
                except (FileNotFoundError,json.JSONDecodeError):return False
            def physical_gate_closed():
                # A physical result may precede its owner's final cleanup.
                # Wait for the scoped route permission to close as well, so
                # that cleanup cannot race with this queue's newly owned lock.
                try:return read_gate().get('whole_design_route_allowed') is False
                except (FileNotFoundError,json.JSONDecodeError):return False
            read_gate=lambda:json.loads((fpga/'config/implementation_readiness.json').read_text(encoding='utf-8'))
            waiting=lambda:(fpga/'build/route_optimization/native_phase.lock').exists() or (a.wait_for_result and not a.wait_for_result.exists()) or not predecessor_passed() or not physical_gate_closed()
            if waiting():print('WAIT_FOR_NATIVE_OWNER',number,job['top'],flush=True)
            while waiting():
                if (run/'pause.json').exists():raise RuntimeError('Queue paused between native jobs')
                if time.monotonic()>deadline:raise TimeoutError('Existing native owner retained after bounded wait')
                time.sleep(2)
            if (run/'pause.json').exists():raise RuntimeError('Queue paused between native jobs')
            assert all(sha(Path(n))==h for n,h in origins.items())
            cmd=[sys.executable,str(script),'--candidate',job['candidate'],'--proof',job['proof'],'--top',job['top']]
            print('SCREEN_BEGIN',number,job['top'],job['candidate'],flush=True)
            proc=subprocess.run(cmd,cwd=fpga.parent,input=b'',capture_output=True,timeout=2100)
            out=proc.stdout+proc.stderr;(run/(str(number)+'.log')).write_bytes(out)
            text=out.decode(errors='replace');print(text[-3000:],flush=True)
            entry=dict(job=job,returncode=proc.returncode,command=cmd);result['jobs'].append(entry)
            for line in text.splitlines():
                if line.startswith('AREA_SCREEN '):entry['screen']=line[len('AREA_SCREEN '):]
            (run/'result.json').write_text(json.dumps(result,indent=2))
            if proc.returncode:raise RuntimeError('Screen failed; inspect before continuing native work')
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items());result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()

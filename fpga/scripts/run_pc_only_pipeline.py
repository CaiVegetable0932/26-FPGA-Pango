"""Finish the reviewed PC-only build, then monitor one unlimited PnR/STA."""
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def main():
    """Serialize native phases and fail closed on any unrecognized diagnostic."""
    fpga=Path(__file__).resolve().parents[1];root=fpga.parent
    record=fpga/'build/pc_only_20261026/campaign.json'
    state=json.loads(record.read_text(encoding='utf-8'))
    run=record.parent/datetime.now().strftime('pipeline_%H%M%S_%f');run.mkdir()
    state.update(pipeline=str(run),pipeline_pid=os.getpid(),pipeline_started_at=datetime.now().astimezone().isoformat(),
                 status='BUILDING_CLEAN_CONSTRAINT_PROFILE',terminal=False)

    def publish():
        """Atomic campaign records prevent a monitor reading a partial write."""
        state['updated_at']=datetime.now().astimezone().isoformat()
        fd,name=tempfile.mkstemp(dir=record.parent,prefix='.campaign-');os.close(fd)
        Path(name).write_text(json.dumps(state,indent=2,ensure_ascii=False),encoding='utf-8');os.replace(name,record)

    def execute(label,args,marker=None):
        """Stream complete output to disk; retain only explicit result markers."""
        command=[sys.executable,'-u',str(fpga/'scripts'/args[0])]+args[1:]
        state['phase']=label;state['phase_command']=command;publish()
        with (run/(label+'.log')).open('wb') as log:
            p=subprocess.Popen(command,cwd=root,stdin=subprocess.DEVNULL,stdout=log,stderr=subprocess.STDOUT)
            state['phase_pid']=p.pid;publish();code=p.wait()
        content=(run/(label+'.log')).read_text(encoding='utf-8',errors='replace')
        if marker:
            match=re.search(r'^'+marker+r' (.+)$',content,re.M)
            if not match:raise RuntimeError(label+' has no completed input/output marker: '+content[-1200:])
            return code,Path(match[1].strip())
        return code,None

    publish();print('PC_PIPELINE',run,flush=True)
    try:
        code,build=execute('synthesis_map',['build_video_system.py','--stage','dev_map','--resource-sharing','true',
            '--overall-timeout-minutes','60','--pause-file',str(record.parent/'pipeline_stop.json')],'BOARD_START')
        state['current_build']=str(build);publish()
        native=json.loads((build/'result.json').read_text(encoding='utf-8'))
        if native['native_exit']!=0 or native['errors'] or not native['snapshot_intact'] or native['unmatched_timing_constraints']:
            raise RuntimeError('Native SYN/MAP failed or still has unmatched timing paths')
        # This installed project flow omits the already-verified reset SCF.
        # Only that exact known gate failure permits an explicit-SCF remap.
        if code and (code!=1 or 'missing 10/10 reset SCF exceptions' not in (native.get('native_constraint_gate_error') or '')):
            raise RuntimeError('Unexpected original MAP gate failure')
        code,mapping=execute('explicit_scf_map',['map_postsyn_candidate.py','--build',str(build)],'POSTSYN_CANDIDATE')
        if code:raise RuntimeError('Explicit SCF MAP failed')
        state['mapping']=str(mapping);state['status']='VALIDATING_FINAL_MAPPING';publish()
        code,review=execute('review',['review_pc_only_design.py','--mapping',str(mapping),
            '--full',str(root/state['full']),'--protocol',str(root/state['protocol']),'--host',str(root/state['host'])],'PC_ONLY_REVIEW')
        if code:raise RuntimeError('Source-bound physical review failed')
        audited=json.loads(review.read_text(encoding='utf-8'))
        state.update(review=str(review),mapped=audited['mapped'],synthesis=audited['synthesis'],
            lut_below_60_percent=audited['lut_below_60_percent'],status='PNR_STA_MONITOR_ONLY',stop_file=audited['scope']['options']['pause_file'])
        publish()
        code,_=execute('route',['review_pc_only_design.py','--review',str(review),'--launch'])
        result=json.loads((mapping/'result.json').read_text(encoding='utf-8'))
        state.update(route_result=str(mapping/'result.json'),resume_evidence=result.get('resume_evidence'),
            route_exit=code,internal_timing_met=result.get('internal_timing_met',False),
            status='PHYSICAL_ATTEMPT_FINISHED',terminal=True)
    except BaseException as error:
        state.update(status='PIPELINE_FAILED',terminal=True,error=str(error));publish();raise
    finally:publish()
    print('PC_PIPELINE_FINISHED',state['status'],flush=True)


if __name__=='__main__':main()

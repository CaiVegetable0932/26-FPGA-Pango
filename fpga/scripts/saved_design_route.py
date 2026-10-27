"""Prepare or launch the saved 22dfcb06 design with unlimited observation."""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget, validate_route_scope, close_route_scope


def sha(p):
    """Bind preserved design and executable monitoring inputs to exact bytes."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def read(p):
    """Read Windows and Python evidence without rewriting the originals."""
    return json.loads(p.read_text(encoding='utf-8-sig'))


def main():
    """Preparation never starts PDS or leaves a global permission open."""
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--bundle',type=Path)
    ap.add_argument('--launch',action='store_true')
    a=ap.parse_args();fpga=Path(__file__).resolve().parents[1]
    if a.bundle is None:
        if a.launch:ap.error('prepare the bundle before launching it')
        parent=fpga/'build/full_integration_20261013/board_postsyn_20261025_162347_361985'
        candidate=fpga/'build/area60_20261025/combined_20261025_160537_700472'
        prior=parent/'resume_20261025_181607_149012/prior_result.json'
        proof=candidate/'handoff_20261025_165641_982673/result.json'
        assert read(proof)['passed'] and all(read(proof)['checks'].values())
        assert read(prior)['native_exit']==0 and read(prior)['syn_intact']
        manifest=read(parent/'sources.json');assert manifest==read(candidate/'sources.json')
        assert all(sha(parent/'source'/n)==h for n,h in manifest.items())
        assert all(sha(fpga/n)==h for n,h in manifest.items() if n.startswith('rtl/'))
        assert sha(parent/'device_map/pango_video_system_map.adf')==read(prior)['mapped_database_sha256']
        # Reuse intact source-bound proofs. The parent's latest result is a
        # later routing TIMEOUT; the archived MAP result is its proper record.
        for label,item in read(proof)['evidence'].items():
            p=Path(item['path'])
            # The resume archives the exact successful MAP result before
            # replacing its latest status with the later PnR outcome.
            if label=='mapping':assert sha(prior)==item['result_sha256']
            elif 'result_sha256' in item:assert sha(p/'result.json')==item['result_sha256']
            elif 'sha256' in item:assert sha(p)==item['sha256']
        target=fpga/'build/full_integration_20261013'/datetime.now().strftime('saved_monitor_%Y%m%d_%H%M%S_%f')
        target.mkdir()
        for name in ['source','synthesize','device_map','constraint_check']:
            shutil.copytree(parent/name,target/name)
        for name in ['sources.json','console.log']:shutil.copyfile(parent/name,target/name)
        shutil.copyfile(prior,target/'result.json')
        for name in ['flow.tcl','flow.pds']:
            t=(parent/name).read_text(encoding='utf-8').replace(parent.as_posix(),target.as_posix()).replace(str(parent),str(target))
            (target/name).write_text(t,encoding='utf-8')
        options=dict(stop_after_timing=True,monitor_only=True,from_placement=False,pnr_timeout_minutes=0,phase_timeout_minutes=0,
            placement_seed=13,placement_decongestion=1,mode='normal',control_chain_length=500,congestion_iterations=200,
            dump_congestion=True,logic_optimize='enabled',lut6d_strategy=3,cell_duplication='default',macro_placement=None,
            planning_before_place=False,installed_pnr_help=None,pin_cost_increasing_speed=None,pause_file=str(target/'stop_requested.json'))
        names=['sources.json','flow.tcl','flow.pds','device_map/pango_video_system_map.adf','device_map/pango_video_system.dmr',
               'device_map/pango_video_system.pcf','synthesize/pango_video_system_syn.adf','synthesize/pango_video_system.snr','result.json']
        scripts=['resume_video_system.py','route_supervisor.py','implementation_readiness.py','constraint_report.py','native_bitgen.py']
        bundle=dict(commit='22dfcb060158d0fc686f190713446415f59e2bc3',parent=str(parent),build=str(target),
            scope=dict(id=target.name,build=str(target),options=options,files={n:sha(target/n) for n in names}),
            scripts={n:sha(fpga/'scripts'/n) for n in scripts},constraints=require_native_constraints(target),
            mapped=require_mapped_lut_budget(target),proof=str(proof),proof_sha256=sha(proof),native_launched=False)
        (target/'monitor_handoff.json').write_text(json.dumps(bundle,indent=2),encoding='utf-8')
        print('SAVED_HANDOFF',target/'monitor_handoff.json',flush=True);return
    bundle=read(a.bundle);build=Path(bundle['build']);scope=bundle['scope'];options=scope['options']
    assert all(sha(fpga/'scripts'/n)==h for n,h in bundle['scripts'].items())
    assert all(sha(build/'source'/n)==h for n,h in read(build/'sources.json').items())
    validate_route_scope(dict(pre_route_review_complete=True,bitstream_generation_allowed=False,route_scope=scope),build,SimpleNamespace(**options))
    require_native_constraints(build);require_mapped_lut_budget(build)
    if not a.launch:print('SAVED_HANDOFF_VERIFIED',build);return
    # Inventory is required on the native Windows host. Never steal a lock or
    # overwrite a different active route permission while launching this job.
    inventory=subprocess.run(['powershell','-NoProfile','-Command',
        "@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in @('pds_shell.exe','ads.exe','pnr.exe') } | Select-Object ProcessId,Name) | ConvertTo-Json -Compress"],capture_output=True,check=True)
    assert not inventory.stdout.strip() or json.loads(inventory.stdout) == []
    gatepath=fpga/'config/implementation_readiness.json';gate=read(gatepath)
    assert not gate['whole_design_route_allowed'] and not (fpga/'build/route_optimization/native_phase.lock').exists()
    shutil.copyfile(gatepath,build/'readiness_before_launch.json')
    gate.update(design_complete=True,selected_source_simulation_passed=True,resource_and_constraints_reviewed=True,
        whole_design_route_allowed=True,pre_route_review_complete=True,bitstream_generation_allowed=False,
        route_scope=scope,route_scope_status='UNLIMITED_MONITOR_ONLY',reason='User requested unlimited monitored routing of saved design.')
    fd,name=tempfile.mkstemp(dir=gatepath.parent,prefix='.monitor-');os.close(fd)
    Path(name).write_text(json.dumps(gate,indent=2),encoding='utf-8');os.replace(name,gatepath)
    cmd=[sys.executable,str(fpga/'scripts/resume_video_system.py'),'--build',str(build)]
    for n,v in options.items():
        if v is None or v is False:continue
        cmd.append('--'+n.replace('_','-'))
        if v is not True:cmd.append(str(v))
    try:
        subprocess.run(cmd+['--check-only'],check=True)
        with (build/'monitor_driver.log').open('wb') as log:
            result=subprocess.run(cmd,cwd=fpga.parent,stdout=log,stderr=subprocess.STDOUT)
        print('SAVED_ROUTE_EXIT',result.returncode,flush=True)
    finally:close_route_scope(scope['id'],build/'result.json')


if __name__=='__main__':main()

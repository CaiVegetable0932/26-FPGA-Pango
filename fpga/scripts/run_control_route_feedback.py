"""Review and run one bounded same-options physical diagnostic of a proven candidate."""
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
from prepare_area60_route_ready import scope_tests


def sha(p):
    """Freeze exactly the artifacts and entrypoints covered by this run."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def read(p):
    """Accept existing UTF-8 and PowerShell BOM evidence."""
    return json.loads(p.read_text(encoding='utf-8-sig'))


def main():
    """User-requested routing diagnosis never enables bitstream generation."""
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--audit',type=Path,required=True)
    ap.add_argument('--decongestion',type=int,choices=[0,1],default=1)
    ap.add_argument('--baseline',type=Path,help='Prior resume evidence for a same-MAP expansion study')
    ap.add_argument('--mode',choices=['normal','performance'],default='normal')
    ap.add_argument('--study-option',choices=['placement_decongestion','mode'],default='placement_decongestion')
    a=ap.parse_args();fpga=Path(__file__).resolve().parents[1]
    audit=read(a.audit);assert audit['passed'] and all(audit['checks'].values())
    if (a.decongestion!=1 or a.mode!='normal') and a.baseline is None:raise ValueError('Changed physical policy requires an explicit same-MAP baseline')
    mapping=Path(audit['mapping']);candidate=Path(audit['candidate'])
    run=candidate/datetime.now().strftime('physical_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(__file__,run/'physical_driver.py');shutil.copyfile(a.audit,run/'reviewed_audit.json')
    gate_path=fpga/'config/implementation_readiness.json';gate=read(gate_path)
    assert not gate['whole_design_route_allowed'] and not gate['bitstream_generation_allowed']
    assert not (fpga/'build/route_optimization/native_phase.lock').exists()
    hashes=read(mapping/'sources.json')
    assert all(sha(mapping/'source'/n)==h for n,h in hashes.items())
    assert read(candidate/'sources.json')==hashes
    assert all(sha(mapping/n)==h for n,h in audit['artifacts'].items())
    for item in audit['evidence'].values():assert sha(Path(item['path']))==item['sha256']
    constraints=require_native_constraints(mapping);budget=require_mapped_lut_budget(mapping)
    # This process runs in the ordinary Windows environment used by native
    # PDS. Never infer an empty inventory from the restricted sandbox view.
    inventory_cmd=['powershell','-NoProfile','-Command',
        "@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in @('pds_shell.exe','ads.exe','pnr.exe') } | Select-Object ProcessId,ParentProcessId,Name,CommandLine) | ConvertTo-Json -Compress"]
    proc=subprocess.run(inventory_cmd,input=b'',capture_output=True,timeout=30)
    if proc.returncode:raise RuntimeError('Native process inventory unavailable')
    output=proc.stdout.decode('utf-8-sig').strip();inventory=json.loads(output) if output else []
    if inventory:raise RuntimeError('Another native process is active')
    (run/'process_inventory.json').write_text(json.dumps(dict(checked_at=datetime.now().astimezone().isoformat(),processes=inventory),indent=2))
    options=dict(stop_after_timing=True,from_placement=False,pnr_timeout_minutes=30,phase_timeout_minutes=30,
        placement_seed=13,placement_decongestion=a.decongestion,mode=a.mode,control_chain_length=500,
        congestion_iterations=200,dump_congestion=True,logic_optimize='enabled',lut6d_strategy=3,
        cell_duplication='default',macro_placement=None,planning_before_place=False,
        installed_pnr_help=None,pin_cost_increasing_speed=None,pause_file=str(run/'route_stop.json'))
    files=list(audit['artifacts'])+['result.json']
    scope=dict(id=run.name,build=str(mapping),options=options,files={n:sha(mapping/n) for n in files})
    tests=scope_tests(run);assert len(tests)==11
    review=dict(passed=True,scope=scope,scope_tests=tests,audit_sha256=sha(a.audit),
        constraints=constraints,mapped=budget,user_priority='Physical routing convergence and interconnect locality, not minimum LUT.',
        decision='One 30-minute PnR diagnostic; unchanged constraints and router options. '+
            ('Only '+a.study_option+' changes against the identical MAP baseline.' if a.baseline else 'Baseline physical options retained.')+' No signoff or bitgen.',
        comparison_baseline=str(a.baseline.resolve()) if a.baseline else None)
    (run/'review.json').write_text(json.dumps(review,indent=2))
    shutil.copyfile(gate_path,run/'readiness_before_release.json')
    gate.update(whole_design_route_allowed=True,pre_route_review_complete=True,bitstream_generation_allowed=False,
        regional_physical_checks_allowed=False,pre_route_timing_review=str(run/'review.json'),
        physical_constraint_inheritance_review=str(run/'review.json'),route_scope=scope,
        route_scope_status='READY_FOR_ONE_30_MINUTE_PHYSICAL_COMPARISON',
        reason='User explicitly prioritizes routing feedback; this exact proven candidate may run one bounded diagnostic.',
        updated_at=datetime.now().astimezone().isoformat())
    validate_route_scope(gate,mapping,SimpleNamespace(**options))
    command=[sys.executable,str(fpga/'scripts/resume_video_system.py'),'--build',str(mapping)]
    for n,v in options.items():
        if v is None or v is False:continue
        command.append('--'+n.replace('_','-'))
        if v is not True:command.append(str(v))
    (run/'launch_command.json').write_text(json.dumps(command,indent=2))
    scripts=['resume_video_system.py','implementation_readiness.py','route_supervisor.py','constraint_report.py','native_bitgen.py','control_route_feedback.py']
    for n in scripts:shutil.copyfile(fpga/'scripts'/n,run/n)
    frozen={n:sha(run/n) for n in scripts}
    # Publish the reviewed gate atomically so an interrupted Windows write
    # cannot leave a truncated readiness record for another entrypoint.
    fd,temporary_name=tempfile.mkstemp(prefix='.physical-review-',dir=gate_path.parent)
    os.close(fd);temporary=Path(temporary_name)
    try:
        temporary.write_text(json.dumps(gate,indent=2)+'\n',encoding='utf-8')
        os.replace(temporary,gate_path)
    finally:
        if temporary.exists():temporary.unlink()
    result=dict(passed=False,mapping=str(mapping),candidate=str(candidate),review_sha256=sha(run/'review.json'),scripts=frozen,
        production_selected=False,bitstream_generated=False,hardware_tested=False)
    print('PHYSICAL_EVALUATION',run,flush=True)
    try:
        preflight=subprocess.run(command+['--check-only'],input=b'',capture_output=True,cwd=fpga.parent,timeout=120)
        (run/'preflight.log').write_bytes(preflight.stdout+preflight.stderr)
        if preflight.returncode:raise RuntimeError('Physical preflight failed')
        with (run/'native_driver.log').open('wb') as log:
            proc=subprocess.run(command,input=b'',stdout=log,stderr=subprocess.STDOUT,cwd=fpga.parent)
        result['native_exit']=proc.returncode
        native=read(mapping/'result.json');result['physical_result']=native['resume_evidence']
        assert Path(result['physical_result']).parent==mapping and native['snapshot_intact']
        # Preserve a timeout as a diagnostic outcome, never a routing pass.
        result['native_status']=native['optimization_status']
        baseline=a.baseline.resolve() if a.baseline else fpga/'build/full_integration_20261013/board_postsyn_20261025_162347_361985/resume_20261025_181607_149012'
        feedback_cmd=[sys.executable,str(fpga/'scripts/control_route_feedback.py'),'--baseline',str(baseline),
            '--candidate',result['physical_result'],'--output',str(run/'feedback.json'),'--seconds','1800']
        if a.baseline:feedback_cmd.extend(['--study-option',a.study_option])
        feedback=subprocess.run(feedback_cmd,input=b'',capture_output=True,cwd=fpga.parent,timeout=120)
        (run/'feedback.log').write_bytes(feedback.stdout+feedback.stderr)
        if feedback.returncode:raise RuntimeError('Physical comparison failed')
        result['feedback']=str(run/'feedback.json');result['passed']=read(run/'feedback.json')['passed']
    finally:
        # The native resume normally closes its scope; preserve any newer
        # owner and also close this one if launch/preflight failed early.
        close_route_scope(scope['id'],run/'result.json')
        result['inputs_intact']=all(sha(mapping/'source'/n)==h for n,h in hashes.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
    print('PHYSICAL_RESULT',json.dumps(result),flush=True)


if __name__=='__main__':main()

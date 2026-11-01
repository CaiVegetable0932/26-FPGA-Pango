"""Verify and relocate the frozen DE release; launch one unlimited PLC route/STA.

Native and host timeouts are zero; monitor-only disables stall termination.
Native algorithm errors/iteration limits and explicit user stops still apply.

No synthesis, source edits, bitstream or programming command is provided.
The release inputs remain immutable; generated projects live under fpga/build.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget
from resume_video_system import verified_planning_help

FPGA=Path(__file__).resolve().parents[1]
RELEASE=FPGA/'release/DE_20261031'
INPUTS=RELEASE/'inputs'
ORIGINAL='D:/XDU/concept/26-FPGA-Pango/fpga/build/full_integration_20261013/gray_DE_verified_pnr_20261031_203121'
DISPATCH=FPGA/'build/portable_de/dispatch.json'


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def save(path,value):
    """Publish complete state atomically so monitor readers never see half JSON."""
    path.parent.mkdir(parents=True,exist_ok=True)
    temporary=path.with_suffix('.pending.json')
    temporary.write_text(json.dumps(value,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
    os.replace(temporary,path)


def audit():
    """Require original native bytes, all source hashes and actual MAP constraints."""
    manifest=json.loads((RELEASE/'manifest.json').read_text(encoding='utf-8'))
    for name,digest in manifest['files'].items():
        target=(FPGA.parent/name).resolve()
        if not target.is_relative_to(FPGA.parent) or sha(target)!=digest:
            raise ValueError('Release integrity mismatch: '+name)
    sources=json.loads((INPUTS/'sources.json').read_text())
    for name,digest in sources.items():
        if sha(INPUTS/'source'/name)!=digest:raise ValueError('Frozen source mismatch: '+name)
    resources=require_mapped_lut_budget(INPUTS)
    if resources['total_lut']!=37592:raise ValueError('Wrong MAP revision')
    constraints=require_native_constraints(INPUTS)
    if set(constraints['constraint_check']['diagnostic_counts'])-{'ConstraintEditor-2002'}:
        raise ValueError('Unreviewed CCR diagnostics')
    return dict(source_count=len(sources),mapped_lut=37592,plc_sha256=sha(INPUTS/'place_route/pango_video_system_plc.adf'),constraints=constraints)


def pds_processes():
    """Do not infer availability from restricted/failed process discovery."""
    p=subprocess.run(['powershell','-NoProfile','-Command',
        "Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object {$_.Name -eq 'pds_shell.exe'} | Select-Object ProcessId,CreationDate,CommandLine | ConvertTo-Json -Compress"],
        capture_output=True,text=True,check=True,creationflags=0x08000000)
    return json.loads(p.stdout) if p.stdout.strip() else []


def relocate(target):
    """Relocate project registrations only; do not patch binary checkpoints/IPs."""
    shutil.copytree(INPUTS,target)
    for name in ['flow.tcl','flow.pds']:
        p=target/name;s=p.read_text(encoding='utf-8')
        s=s.replace(ORIGINAL,target.as_posix()).replace(ORIGINAL.replace('/','\\'),str(target))
        p.write_text(s,encoding='utf-8')
    flow=(target/'flow.tcl').read_text(encoding='utf-8').split('\ncompile ',1)[0]
    # Every registered physical source/constraint must now exist locally.
    for name in re.findall(r'(?m)^add_(?:design|constraint)\s+\{([^}]+)\}',flow):
        if not Path(name).is_file():raise ValueError('Missing relocated dependency: '+name)
    if ORIGINAL in flow:raise ValueError('Old project root survived relocation')


def prepare(pds_root):
    """Prepare a new scope once on the destination host, after installed help check."""
    review=audit()
    if os.name!='nt':raise ValueError('This frozen PDS flow requires Windows')
    import psutil  # Required for creation-time/descendant monitoring on this host.
    if DISPATCH.exists():raise ValueError('Dispatch already exists; inspect it, do not restart automatically')
    if pds_processes():raise ValueError('A native PDS task is already present; leave it untouched')
    shell=pds_root.resolve()/'bin/pds_shell.exe'
    if not shell.is_file():raise ValueError('PDS shell executable missing')
    target=FPGA/'build/portable_de'/datetime.now().strftime('route_%Y%m%d_%H%M%S')
    relocate(target)
    # Only read target-specific installed command help, not a build action.
    help_tcl=target/'installed_help.tcl'
    help_tcl.write_text('set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\nhelp pnr\n',encoding='utf-8')
    probe=subprocess.run([str(shell),'-file',str(help_tcl),'-work_dir',str(target)],capture_output=True,timeout=120,creationflags=0x08000000)
    help_log=target/'installed_pnr_help.log';help_log.write_bytes(probe.stdout+probe.stderr)
    if probe.returncode:raise ValueError('Installed PDS help/license probe failed; see '+str(help_log))
    verified_planning_help(help_log)
    if '-input_place_db_file' not in help_log.read_text(errors='replace'):raise ValueError('PLC input not supported')
    options=dict(stop_after_timing=True,monitor_only=True,from_placement=True,
        pnr_timeout_minutes=0,phase_timeout_minutes=0,placement_seed=7,
        placement_decongestion=1,mode='normal',control_chain_length=500,
        congestion_iterations=200,dump_congestion=True,logic_optimize='default',
        lut6d_strategy=None,cell_duplication='default',macro_placement=None,
        planning_before_place=False,installed_pnr_help=None,pin_cost_increasing_speed=None,
        pause_file=str(target/'stop_requested.json'),pds_shell=str(shell))
    # Unlimited runtime is explicit user policy: keep native timeout=0 and
    # monitor-only host supervision together; do not terminate on slow progress.
    # Placement choices belong to the saved PLC. Do not apply new planning,
    # packing or expansion to an already placed design through this entrypoint.
    names=['installed_pnr_help.log','sources.json','flow.tcl','flow.pds','result.json','device_map/pango_video_system_map.adf',
           'device_map/pango_video_system.pcf','device_map/pango_video_system.dmr',
           'synthesize/pango_video_system_syn.adf','synthesize/pango_video_system.snr',
           'place_route/pango_video_system_plc.adf']
    scope=dict(id=target.name,build=str(target),options=options,files={n:sha(target/n) for n in names})
    gate=dict(design_complete=True,selected_source_simulation_passed=True,resource_and_constraints_reviewed=True,
        whole_design_route_allowed=True,pre_route_review_complete=True,bitstream_generation_allowed=False,
        user_gui_approval_required=False,route_scope=scope,route_scope_status='READY_FOR_ONE_UNLIMITED_ATTEMPT',
        user_route_approval='User explicitly requested DE cloud publication and another computer to route with no time limit, 2026-10-31',
        original_review=str(RELEASE/'evidence/original_physical_review.json'))
    command=[sys.executable,'-B',str(FPGA/'scripts/resume_video_system.py'),'--build',str(target)]
    for name,value in options.items():
        if value is None or value is False:continue
        command.append('--'+name.replace('_','-'))
        if value is not True:command.append(str(value))
    save(FPGA/'config/implementation_readiness.json',gate)
    save(target/'physical_review.json',dict(audit=review,scope=scope,placement_reused=True,partial_route_resumed=False,bitstream_allowed=False))
    save(target/'launch_command.json',command)
    pre=subprocess.run(command+['--check-only'],capture_output=True,timeout=120)
    (target/'preflight.log').write_bytes(pre.stdout+pre.stderr)
    if pre.returncode:
        gate.update(whole_design_route_allowed=False,route_scope_status='PREPARATION_FAILED')
        save(FPGA/'config/implementation_readiness.json',gate)
        raise ValueError('Preflight failed; no route started: '+str(target))
    save(DISPATCH,dict(status='PREPARED',build=str(target),command=command))
    print('PREPARED',target,flush=True)


def launch():
    """Exactly one launch; record the precise resume path instead of newest-dir guesses."""
    audit()
    state=json.loads(DISPATCH.read_text(encoding='utf-8'))
    if state['status']!='PREPARED':raise ValueError('This dispatch was already used; no automatic retry')
    if pds_processes():raise ValueError('A native PDS task is already running')
    target=Path(state['build'])
    # Exclusive marker protects against two launchers racing on this project.
    with (target/'attempt_claim.json').open('x',encoding='utf-8') as stream:
        json.dump(dict(pid=os.getpid(),at=datetime.now().astimezone().isoformat()),stream)
    state.update(status='STARTING',wrapper_pid=os.getpid());save(DISPATCH,state)
    env=os.environ.copy();env['PYTHONUTF8']='1';env['PYTHONIOENCODING']='utf-8'
    with (target/'launch.log').open('w',encoding='utf-8') as log:
        child=subprocess.Popen(state['command'],stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,encoding='utf-8',errors='replace',env=env)
        state.update(status='RUNNING',resume_wrapper_pid=child.pid);save(DISPATCH,state)
        for line in child.stdout:
            log.write(line);log.flush();print(line,end='',flush=True)
            if line.startswith('RESUME '):
                paths=list(target.glob('resume_*'))
                if len(paths)!=1:raise ValueError('Unexpected resume evidence count')
                state.update(resume=str(paths[0]),phase=line.split()[1]);save(DISPATCH,state)
        code=child.wait()
    save(target/'launch_exit.json',dict(returncode=code))
    state.update(status='COMPLETE' if code==0 else 'FAILED',returncode=code);save(DISPATCH,state)
    raise SystemExit(code)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    group=parser.add_mutually_exclusive_group(required=True)
    group.add_argument('--audit',action='store_true')
    group.add_argument('--prepare',action='store_true')
    group.add_argument('--run',action='store_true')
    parser.add_argument('--pds-root',type=Path)
    args=parser.parse_args()
    if args.audit:print(json.dumps(audit(),indent=2,ensure_ascii=False))
    elif args.prepare:
        if args.pds_root is None:parser.error('--prepare requires --pds-root')
        prepare(args.pds_root)
    else:launch()


if __name__=='__main__':main()

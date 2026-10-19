"""Run one source-bound physical attempt in a five-attempt review campaign.

Each attempt gets its own MAP/PCF/source copy. Actual route and min/max STA
remain mandatory before bitgen; packaging also checks frozen host/model inputs.
After five completed unsuccessful attempts, record a review-required boundary
instead of silently starting a sixth seed. A new reviewed batch must be explicit.
"""
import argparse
from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
from package_video_system import verified_geometry_budget, verified_display_evidence
from resume_video_system import verified_planning_help
from implementation_readiness import require_whole_design_ready


def now():
    """Use the project's Shanghai timezone independently of host settings."""
    return datetime.now(timezone(timedelta(hours=8))).isoformat()


def read_json(path):
    """Load persisted evidence without changing its original bytes."""
    return json.loads(path.read_text(encoding='utf-8'))


def manifest(directory):
    """Check actual immutable bytes, not just equality of two manifests."""
    result = read_json(directory/'sources.json')
    for name,digest in result.items():
        if hashlib.sha256((directory/'source'/name).read_bytes()).hexdigest()!=digest:
            raise ValueError('Source changed: '+str(directory/name))
    return result


def main():
    """Validate one reviewed candidate and preserve every native failure."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--campaign',type=Path,required=True)
    parser.add_argument('--map-build',type=Path,required=True)
    parser.add_argument('--model',type=Path,required=True)
    parser.add_argument('--host-report',type=Path,required=True)
    parser.add_argument('--regression',type=Path,required=True)
    parser.add_argument('--differential',type=Path,required=True)
    parser.add_argument('--additional-differential',type=Path,action='append',default=[],
                        help='Bind additional control-path equivalence evidence to this MAP')
    parser.add_argument('--seed',type=int,required=True)
    # A complete engineering attempt must have an external wall-time bound;
    # native action timeout alone does not supervise Python/native descendants.
    parser.add_argument('--phase-timeout-minutes',type=int,default=60)
    parser.add_argument('--pause-file',type=Path)
    parser.add_argument('--decongestion',type=int,default=1)
    parser.add_argument('--macro',choices=('Greedy','Global','Grouped','Close'),default='Grouped')
    parser.add_argument('--duplication',choices=('default','enabled','disabled'),default='default')
    parser.add_argument('--planning-before-place',action='store_true',
                        help='Enable installed PG2L100H module planning in this complete attempt')
    parser.add_argument('--installed-pnr-help',type=Path,
                        help='Frozen target-specific native help required with module planning')
    args=parser.parse_args()
    # Do not launch a complete design while regional design work is pending.
    require_whole_design_ready()
    if not 1 <= args.phase_timeout_minutes <= 1440:
        parser.error('--phase-timeout-minutes must be 1..1440')
    # Reject unverified optional policies before creating a campaign or lock.
    # Planning changes only placement; the same five-attempt and release gates
    # still apply, with the exact capability evidence retained by the driver.
    if args.planning_before_place != (args.installed_pnr_help is not None):
        parser.error('--planning-before-place and --installed-pnr-help must be supplied together')
    planning_help_sha256=verified_planning_help(args.installed_pnr_help) if args.planning_before_place else None
    fpga=Path(__file__).resolve().parents[1]
    # One heavy implementation per machine. Read the native process inventory
    # before cloning so an existing user job is left entirely untouched.
    from observe_video_routes import process_inventory
    if process_inventory():
        raise ValueError('Another PDS task is active; wait for its authoritative terminal state')
    campaign=args.campaign.resolve(); mapped=args.map_build.resolve(); model=args.model.resolve()
    if any(not p.is_relative_to(fpga/'build') for p in (campaign,mapped,model)):
        raise ValueError('Campaign, MAP and model must remain under fpga/build')
    campaign.mkdir(parents=True,exist_ok=True)
    # Exclusive lock prevents duplicate attempts after an interrupted chat.
    # A stale lock must be investigated against native process identity first.
    lock=campaign/'active_attempt.lock'
    with lock.open('x',encoding='utf-8') as stream:
        stream.write(json.dumps(dict(at=now(),arguments=vars(args)),default=str))
    state_path=campaign/'campaign.json'
    attempt=None
    safe_unlock=True
    try:
        state=read_json(state_path) if state_path.exists() else dict(
            started_at=now(),minimum_corrected_fps=30,width=1920,height=1080,
            review_interval='five complete place-and-route attempts',attempts=[],passed=False)
        if state.get('passed') or state.get('review_required'):
            raise ValueError('Campaign is complete or requires a new reviewed batch')
        # An independently reserved parallel job owns one global number and
        # one private campaign file. It must not rewrite the first running
        # driver's in-memory ledger. The parent batch index counts completions
        # across these files and enforces the five-attempt review boundary.
        global_number=state.get('global_attempt_number')
        if global_number is not None:
            if not isinstance(global_number,int) or not 1<=global_number<=5 or state['attempts']:
                raise ValueError('A reserved parallel attempt runs once, numbered 1..5')
            index=read_json(Path(state['batch_index']))
            members=index['members']
            if not 1<=len(members)<=5 or len({m['number'] for m in members})!=len(members):
                raise ValueError('Invalid five-attempt parent batch index')
            own=[m for m in members if m['number']==global_number and Path(m['campaign']).resolve()==state_path]
            if len(own)!=1 or index.get('review_required') or index.get('passed'):
                raise ValueError('Parallel job is not reserved in the active parent batch')
        board_result=read_json(mapped/'result.json')
        if board_result.get('native_exit')!=0 or board_result.get('errors') or not board_result.get('map_completed'):
            raise ValueError('Completed successful MAP is required')
        board_sources,model_sources=manifest(mapped),manifest(model)
        shared=board_sources.keys() & model_sources.keys()
        if len(board_sources)!=290 or len(shared)!=70 or any(board_sources[n]!=model_sources[n] for n in shared):
            raise ValueError('Full native/model source identity mismatch')
        model_result=read_json(model/'result.json')
        if not all(model_result.get(k) for k in ('passed','full_frame','control_test','snapshot_test','snapshot_intact','display_test')):
            raise ValueError('Full-frame/control/snapshot/display model must pass')
        # Reuse the release gate: the job overlapping later capture/network
        # traffic must meet the same deadline as the final quiet-tail job.
        geometry_budget=verified_geometry_budget(model)
        display_evidence=verified_display_evidence(model)
        cycles=geometry_budget['frame_cycles']
        for path in (args.regression.resolve(),args.differential.resolve()):
            result=read_json(path/'result.json')
            if not result.get('passed'):
                raise ValueError('Local regression/differential did not pass')
        # A latency-changing metadata candidate must add independent accepted-
        # operation/descriptor checks, not claim whole-bank cycle equivalence
        # from the separate DMA and snapshot-controller differential tests.
        regression_result=read_json(args.regression.resolve()/'result.json')
        required={'tb_frame_snapshot_pair','tb_frame_memory_fabric','tb_frame_ticket_rollover',
            'tb_video_memory_core','tb_geometry_native_integration','tb_geometry_frame_processor',
            'tb_frame_pixel_writer','tb_geometry_tile_refill'}
        if regression_result.get('acquire_wait_cycles',0):
            required|={'tb_frame_metadata_read','tb_frame_manager_pressure'}
        if not required.issubset(regression_result['tests']):
            raise ValueError('Required ownership/data-path regression coverage is missing')
        differential=read_json(args.differential.resolve()/'result.json')
        if not differential.get('cycle_equivalent') or not differential.get('inputs_intact'):
            raise ValueError('Cycle-equivalence proof is required for address repair')
        # Bind differential candidate bytes to this actual MAP. Reference/test
        # files are also rehashed to reject a stale PASS after source edits.
        for name,digest in differential['inputs'].items():
            p=Path(name)
            if hashlib.sha256(p.read_bytes()).hexdigest()!=digest:
                raise ValueError('Differential input changed: '+name)
            if '/source/rtl/' in p.as_posix():
                relative='rtl/'+p.as_posix().split('/source/rtl/',1)[1]
                if board_sources.get(relative)!=digest:
                    raise ValueError('Differential/MAP mismatch: '+relative)
        # Later candidates can carry independent ownership/control proofs in
        # addition to the address/refill proof. Rehash every proof input and
        # require every tested candidate RTL file to equal the actual MAP.
        for extra in args.additional_differential:
            proof=read_json(extra.resolve()/'result.json')
            if not all(proof.get(k) for k in ('passed','cycle_equivalent','inputs_intact')):
                raise ValueError('Additional differential did not pass: '+str(extra))
            for name,digest in proof['inputs'].items():
                p=Path(name)
                if hashlib.sha256(p.read_bytes()).hexdigest()!=digest:
                    raise ValueError('Additional differential input changed: '+name)
                if '/source/rtl/' in p.as_posix():
                    relative='rtl/'+p.as_posix().split('/source/rtl/',1)[1]
                    if board_sources.get(relative)!=digest:
                        raise ValueError('Additional differential/MAP mismatch: '+relative)
        regression=read_json(args.regression.resolve()/'sources.json')
        for name,digest in regression.items():
            fixture=args.regression.resolve()/'source'/Path(name).name
            if hashlib.sha256(fixture.read_bytes()).hexdigest()!=digest:
                raise ValueError('Frozen local regression input changed: '+name)
            if name.startswith('rtl/') and board_sources.get(name)!=digest:
                raise ValueError('Regression/MAP mismatch: '+name)
        host=read_json(args.host_report.resolve())
        if not host.get('passed') or not host.get('companion_snapshot_intact') or Path(host['input_directory']).resolve()!=model:
            raise ValueError('Host decode must bind to this exact model')
        # The clone command verifies immutable MAP/PCF inputs and rebases the
        # native project while preserving complete DDR IP constraint context.
        cloned=subprocess.run([sys.executable,str(fpga/'scripts/clone_mapped_video_system.py'),
            '--build',str(mapped)],capture_output=True,text=True,check=True,creationflags=0x08000000)
        copy= json.loads(cloned.stdout)
        build=Path(copy['build'])
        identity=dict(build=str(build),source_build=str(mapped),model=str(model),
            host_report=str(args.host_report.resolve()),shared_rtl_count=len(shared),
            actual_shared_hashes_match=True,model_geometry_cycles=max(cycles),
            modeled_geometry_budget=geometry_budget,
            modeled_display=display_evidence,
            regression_cases=regression_result['tests'],
            acquire_wait_cycles=regression_result.get('acquire_wait_cycles',0),
            regression=str(args.regression.resolve()),differential=str(args.differential.resolve()),
            additional_differentials=[str(p.resolve()) for p in args.additional_differential],
            checkpoint_sha256=copy['checkpoint_sha256'],programmed=False,
            planning_before_place=True if args.planning_before_place else None,
            planning_help_sha256=planning_help_sha256)
        (build/'source_identity.json').write_text(json.dumps(identity,indent=2),encoding='utf-8')
        attempt=dict(number=global_number or len(state['attempts'])+1,started_at=now(),build=str(build),
            source_build=str(mapped),options=dict(seed=args.seed,decongestion=args.decongestion,
            macro=args.macro,duplication=args.duplication,
            planning_before_place=True if args.planning_before_place else None),
            phase='route_sta_bitgen',complete=False,passed=False)
        state['attempts'].append(attempt)

        def record():
            """Persist explicit phase and provenance before each native action."""
            state['updated_at']=now()
            state['phase']=attempt['phase']
            state_path.write_text(json.dumps(state,indent=2),encoding='utf-8')
            print(json.dumps(attempt),flush=True)

        record()
        shutil.copyfile(__file__,build/'campaign_attempt_script.py')
        command=[sys.executable,str(fpga/'scripts/resume_video_system.py'),'--build',str(build),
            '--pnr-timeout-minutes',str(min(args.phase_timeout_minutes,180)),
            '--phase-timeout-minutes',str(args.phase_timeout_minutes),'--placement-seed',str(args.seed),
            '--placement-decongestion',str(args.decongestion),'--macro-placement',args.macro,
            '--cell-duplication',args.duplication,'--mode','normal','--control-chain-length','500',
            '--congestion-iterations','200','--dump-congestion']
        if args.pause_file:
            command+=['--pause-file',str(args.pause_file.resolve())]
        if args.planning_before_place:
            command+=['--planning-before-place','--installed-pnr-help',str(args.installed_pnr_help.resolve())]
        with (build/'campaign_route.log').open('wb') as log:
            safe_unlock=False
            child=subprocess.run(command,cwd=fpga.parent,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
            safe_unlock=True
        attempt.update(native_driver_exit=child.returncode,finished_at=now())
        result=read_json(build/'result.json')
        phases=result.get('native_runs',[])
        attempt['complete']=bool(phases and phases[0].get('phase')=='place_route')
        attempt['native_result']=result
        if child.returncode:
            attempt['phase']='native_failed'
        else:
            attempt['phase']='packaging';record()
            with (build/'campaign_package.log').open('wb') as log:
                package=subprocess.run([sys.executable,str(fpga/'scripts/package_video_system.py'),
                    '--board-build',str(build),'--simulation',str(model),
                    '--host-verification',str(args.host_report.resolve())],cwd=fpga.parent,
                    stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
            attempt['package_exit']=package.returncode
            attempt['passed']=package.returncode==0
            attempt['phase']='packaged' if attempt['passed'] else 'package_failed'
            state['passed']=attempt['passed']
        completed=sum(bool(a.get('complete')) for a in state['attempts'])
        state['completed_attempts']=completed
        state['review_required']=completed>=5 and not state['passed']
        record()
        if not attempt['passed']:
            raise SystemExit(1)
    finally:
        # Keep the lock after an interrupted native wait: its child may still
        # own the database. A later continuation must inspect process identity
        # before clearing that stale lock or counting the attempt as finished.
        if safe_unlock:
            lock.unlink(missing_ok=True)


if __name__=='__main__':
    main()

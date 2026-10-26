"""Review and authorize one frozen area candidate for bounded PnR/STA only.

No native implementation is launched. Existing functional/MAP evidence is
revalidated; negative gate tests use temporary local fixtures, never real input.
"""
import argparse
from copy import deepcopy
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile
from types import SimpleNamespace
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget,validate_route_scope,close_route_scope
from package_block_pressure_handoff import synthesis


def read(p):
    """Handle both Python UTF-8 and PowerShell's UTF-8 BOM evidence."""
    return json.loads(p.read_text(encoding='utf-8-sig'))


def sha(p):
    """Identify fixed inputs and the exact reviewed tool entrypoints."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def scope_tests(out):
    """Exercise authorization boundaries without editing any actual MAP."""
    results=[]
    with tempfile.TemporaryDirectory(prefix='scope-test-',dir=out) as temp:
        base=Path(temp);(base/'input').write_text('original')
        state=dict(pre_route_review_complete=True,bitstream_generation_allowed=False,
            route_scope=dict(id='test',build=str(base),options={'stop_after_timing':True,'phase_timeout_minutes':90},files={'input':sha(base/'input')}))
        options=SimpleNamespace(stop_after_timing=True,phase_timeout_minutes=90)
        validate_route_scope(state,base,options);results.append('correct_candidate_accepted')
        cases=[('different_build',state,base/'other',options),('fresh_build',state,None,None),
               ('missing_options',state,base,None),
               ('bitgen_request',state,base,SimpleNamespace(stop_after_timing=False,phase_timeout_minutes=90)),
               ('unbounded_budget',state,base,SimpleNamespace(stop_after_timing=True,phase_timeout_minutes=1440))]
        for name,key,value in [('review_missing','pre_route_review_complete',False),('bitgen_gate_open','bitstream_generation_allowed',True)]:
            changed=deepcopy(state);changed[key]=value;cases.append((name,changed,base,options))
        tampered=deepcopy(state);tampered['route_scope']['files']['input']='0'*64
        cases.append(('changed_input',tampered,base,options))
        for name,s,b,o in cases:
            try:validate_route_scope(s,b,o)
            except ValueError:results.append(name+'_rejected')
            else:raise RuntimeError('Scope test failed: '+name)
        # Completion closes only its own permission, not a replacement owner.
        record=base/'gate.json';state['whole_design_route_allowed']=True
        record.write_text(json.dumps(state),encoding='utf-8')
        assert not close_route_scope('other',base/'result.json',record)
        assert read(record)['whole_design_route_allowed'];results.append('newer_owner_preserved')
        assert close_route_scope('test',base/'result.json',record)
        assert not read(record)['whole_design_route_allowed'] and not read(record)['bitstream_generation_allowed']
        results.append('own_permission_closed')
    return results


def main():
    """Require complete current evidence before opening the narrow allowance."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--review',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];root=fpga.parent;out=args.review.resolve()
    assert out.is_relative_to(fpga/'build/area60_route_ready_20261025')
    if (out/'release.json').exists():raise ValueError('Review already released; do not silently reauthorize')
    candidate=fpga/'build/area60_20261025/combined_20261025_160537_700472'
    mapping=fpga/'build/full_integration_20261013/board_postsyn_20261025_162347_361985'
    baseline=fpga/'build/full_integration_20261013/board_postsyn_20261025_005840_892166'
    gate_path=fpga/'config/implementation_readiness.json';gate=read(gate_path)
    assert not gate['whole_design_route_allowed'] and not gate['bitstream_generation_allowed']
    assert not (fpga/'build/route_optimization/native_phase.lock').exists()
    inventory=read(out/'process_inventory.json');assert inventory['count']==0
    assert (datetime.now().astimezone()-datetime.fromisoformat(inventory['checked_at'])).total_seconds()<900
    checks={};hashes=read(mapping/'sources.json')
    checks['frozen_321_sources']=len(hashes)==321 and all(sha(mapping/'source'/n)==h for n,h in hashes.items())
    checks['production_rtl_exact']=all(sha(fpga/n)==h for n,h in hashes.items() if n.startswith('rtl/'))
    checks['candidate_manifest_equal']=read(candidate/'sources.json')==hashes
    old=read(baseline/'sources.json')
    checks['constraints_unchanged']=all(old.get(n)==h for n,h in hashes.items() if n.startswith('constraints/'))
    normalize=lambda path,pattern:{' '.join(s.split()) for s in path.read_text(errors='replace').splitlines() if re.match(pattern,s)}
    checks['mapped_timing_commands_equal']=normalize(mapping/'device_map/pango_video_system.dmr',r'^\s*(create_clock|create_generated_clock|set_\w+) ')==normalize(baseline/'device_map/pango_video_system.dmr',r'^\s*(create_clock|create_generated_clock|set_\w+) ')
    pcf=normalize(mapping/'device_map/pango_video_system.pcf',r'^def_')
    checks['physical_ports_and_sites_equal']=pcf==normalize(baseline/'device_map/pango_video_system.pcf',r'^def_')
    prefix=(mapping/'flow.tcl').read_text(encoding='utf-8').split('\ncompile ',1)[0]
    registered=re.findall(r'^(?:add_design|add_constraint) \{([^}]+)\}',prefix,re.M)
    checks['source_ip_registration_intact']=all(Path(p).is_relative_to(mapping/'source') and Path(p).is_file() and hashes.get(Path(p).relative_to(mapping/'source').as_posix())==sha(Path(p)) for p in registered)
    checks['three_ip_eight_constraints']=sum(p.endswith('.idf') for p in registered)==3 and len(re.findall(r'^add_constraint ',prefix,re.M))==8
    constraints=require_native_constraints(mapping);budget=require_mapped_lut_budget(mapping)
    checks['map_native_complete']=read(mapping/'result.json')['native_exit']==0 and read(mapping/'result.json')['syn_intact']
    # Reuse byte-identical functional evidence but re-run its integrity checks.
    arguments=read(candidate/'handoff_arguments.json');cmd=[sys.executable,str(fpga/'scripts/package_area60_handoff.py')]
    for name,value in arguments.items():cmd+=['--'+name]+(value if isinstance(value,list) else [value])
    proc=subprocess.run(cmd,input=b'',capture_output=True,cwd=root,timeout=120)
    (out/'evidence_recheck.log').write_bytes(proc.stdout+proc.stderr)
    if proc.returncode:raise RuntimeError('Prior functional/source evidence recheck failed')
    line=next(x for x in proc.stdout.decode('utf-8').splitlines() if x.startswith('AREA_HANDOFF '))
    recheck=Path(line[len('AREA_HANDOFF '):])/'result.json';proof=read(recheck)
    checks['functional_and_map_32_checks']=proof['passed'] and all(proof['checks'].values())
    tests=scope_tests(out);checks['scope_boundaries']=len(tests)==11
    if not all(checks.values()):raise ValueError(str(checks))
    files=['sources.json','device_map/pango_video_system_map.adf','device_map/pango_video_system.dmr',
           'device_map/pango_video_system.pcf','synthesize/pango_video_system_syn.adf',
           'synthesize/pango_video_system.snr','source/constraints/video_system/reset_fsm_postsyn.scf',
           'flow.tcl','result.json']
    pause=out/'route_stop.json'
    options=dict(stop_after_timing=True,from_placement=False,pnr_timeout_minutes=90,phase_timeout_minutes=90,
        placement_seed=13,placement_decongestion=1,mode='normal',control_chain_length=500,
        congestion_iterations=200,dump_congestion=True,logic_optimize='enabled',lut6d_strategy=3,
        cell_duplication='default',macro_placement=None,planning_before_place=False,
        installed_pnr_help=None,pin_cost_increasing_speed=None,pause_file=str(pause))
    scope=dict(id=out.name,build=str(mapping),options=options,files={n:sha(mapping/n) for n in files})
    syn=synthesis(mapping/'synthesize/pango_video_system.snr');syn.pop('modules')
    review=dict(passed=True,checks=checks,scope_tests=tests,functional_recheck=str(recheck),
        functional_recheck_sha256=sha(recheck),constraints=constraints,mapped=budget,synthesis=syn,
        physical_port_count=sum(x.startswith('def_port ') for x in pcf),fixed_site_count=sum(x.startswith('def_inst_site ') for x in pcf),
        permission_scope=scope,decision='Permit bounded PnR/min-max STA diagnosis despite negative synthesis setup; no timing or hardware signoff.',
        accepted_open_items=['DDR synthesis setup WNS -1.555 ns / TNS -1718.586 ns',
            '33 shared-pin critical warnings need board review','Vendor hold and post-synthesis removal require physical STA',
            'External IO timing, MCU calibration, throughput, power and HDMI identity remain unverified'],
        routed=False,native_launched=False,bitstream_allowed=False)
    (out/'review.json').write_text(json.dumps(review,indent=2),encoding='utf-8')
    # This user's request authorizes preparing the design for routing. The
    # reviewed allowance applies only to this MAP and ends after one attempt.
    shutil.copyfile(gate_path,out/'readiness_before_release.json')
    gate.update(whole_design_route_allowed=True,bitstream_generation_allowed=False,regional_physical_checks_allowed=False,
        pre_route_review_complete=True,pre_route_timing_review=str((out/'review.json').relative_to(root)),
        physical_constraint_inheritance_review=str((out/'review.json').relative_to(root)),
        review_document='fpga/reports/LUT60可执行布线交接_20261025.md',route_task='fpga/reports/LUT60可执行布线交接_20261025.md',
        route_scope=scope,route_scope_status='READY_FOR_ONE_BOUNDED_ATTEMPT',
        latest_physical_status='READY_FOR_SCOPED_PNR_NOT_STARTED',
        reason='User requested a route-ready design and handoff; reviewed frozen MAP authorized for bounded PnR/STA only. Negative synthesis timing remains open.',
        updated_at=datetime.now().astimezone().isoformat())
    validate_route_scope(gate,mapping,SimpleNamespace(**options))
    # Check-only uses the same CLI/parser and gates as the future real run.
    command=[sys.executable,str(fpga/'scripts/resume_video_system.py'),'--build',str(mapping)]
    for name,value in options.items():
        if value is None or value is False:continue
        command.append('--'+name.replace('_','-'))
        if value is not True:command.append(str(value))
    (out/'launch_command.json').write_text(json.dumps(command,indent=2),encoding='utf-8')
    scripts={n:sha(fpga/'scripts'/n) for n in ['resume_video_system.py','implementation_readiness.py','route_supervisor.py','constraint_report.py','native_bitgen.py']}
    for n in scripts:shutil.copyfile(fpga/'scripts'/n,out/n)
    gate_path.write_text(json.dumps(gate,indent=2)+'\n',encoding='utf-8')
    preflight=subprocess.run(command+['--check-only'],input=b'',capture_output=True,cwd=root,timeout=120)
    (out/'preflight.log').write_bytes(preflight.stdout+preflight.stderr)
    if preflight.returncode:
        # A failing preflight cannot leave an unusable permission enabled.
        shutil.copyfile(out/'readiness_before_release.json',gate_path)
        raise RuntimeError('Preflight failed; original closed gate restored')
    (out/'release.json').write_text(json.dumps(dict(ready=True,native_launched=False,
        review_sha256=sha(out/'review.json'),readiness_sha256=sha(gate_path),scripts_sha256=scripts,
        command_sha256=sha(out/'launch_command.json'),
        preflight=json.loads(preflight.stdout),scope=scope),indent=2),encoding='utf-8')
    print('ROUTE_READY',out,flush=True)


if __name__=='__main__':main()

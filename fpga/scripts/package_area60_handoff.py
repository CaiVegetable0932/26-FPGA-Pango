"""Bind the selected area candidate to complete software and explicit-SCF MAP.

Optional promotion copies only hash-checked RTL, saves all previous bytes, and
keeps route/bitstream gates closed. It never launches native implementation.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import tempfile
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget
from package_block_pressure_handoff import synthesis


def read(p):
    """Read exact evidence without modifying historical reports."""
    return json.loads(p.read_text(encoding='utf-8'))


def sha(p):
    """Bind manifests, evidence and reversible production changes."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def install_rtl(source,target,expected):
    """Replace a verified file atomically, including files mapped by editors.

    Windows can reject truncation of an open memory-mapped RTL file with EINVAL.
    A same-directory temporary file avoids partial contents and permits an
    atomic replacement while the complete prior bytes remain in the handoff.
    """
    fd,name=tempfile.mkstemp(prefix='.'+target.name+'.area60-',dir=target.parent)
    os.close(fd);temporary=Path(name)
    try:
        shutil.copyfile(source,temporary)
        if sha(temporary)!=expected:raise RuntimeError('Candidate changed during install')
        os.replace(temporary,target)
    finally:
        if temporary.exists():temporary.unlink()


def main():
    """Reject source drift, missing constraints or unfinished verification."""
    parser=argparse.ArgumentParser(description=__doc__)
    for n in ('candidate','mapping','full','network','host','integrity','cdc'):
        parser.add_argument('--'+n,type=Path,required=True)
    parser.add_argument('--software',type=Path,nargs='+',required=True)
    parser.add_argument('--promote',action='store_true')
    a=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    candidate=a.candidate.resolve();mapping=a.mapping.resolve()
    if not candidate.is_relative_to(fpga/'build/area60_20261025'):raise ValueError('Area candidate required')
    hashes=read(candidate/'sources.json');baseline=Path(read(candidate/'candidate.json')['baseline'])
    baseline_hashes=read(baseline/'sources.json')
    checks={'candidate_intact':all(sha(candidate/'source'/n)==h for n,h in hashes.items()),
            'mapping_exact_manifest':read(mapping/'sources.json')==hashes,
            'constraints_unchanged':all(hashes.get(n)==h for n,h in baseline_hashes.items() if n.startswith('constraints/'))}
    evidence={};covered=set()
    for label,folder in (('full',a.full),('network',a.network),('mapping',mapping)):
        folder=folder.resolve();r=read(folder/'result.json');compiled=read(folder/'sources.json')
        checks[label+'_binding']=all(sha(folder/'source'/n)==h and (not n.startswith('rtl/') or hashes.get(n)==h) for n,h in compiled.items())
        checks[label+'_completed']=(r['native_exit']==0 and not r['errors'] if label=='mapping' else r['passed']) and r['snapshot_intact']
        if label=='full':checks['full_profile']=all(r.get(n) for n in ('full_frame','control_test','display_test','board_manual_profile'))
        if label=='network':checks['network_profile']=r.get('network_test') and r.get('board_manual_profile')
        if label!='mapping':
            fixture=(folder/'source/sim/tb_video_memory_core.sv').read_text(encoding='utf-8')
            checks[label+'_board_specialization']=all(token in fixture for token in (
                '.CCM_PREVALIDATED(BOARD_MANUAL_PROFILE)',
                '.TONE_LUT_PREVALIDATED(BOARD_MANUAL_PROFILE)'))
        if label!='mapping':covered.update(n for n in compiled if n.startswith('rtl/') and hashes.get(n)==compiled[n])
        evidence[label]={'path':str(folder),'result_sha256':sha(folder/'result.json')}
    require_native_constraints(mapping);resources=require_mapped_lut_budget(mapping)
    checks['map_budget']=resources['total_lut']<45921
    # Compare normalized native timing commands, not just unchanged input files.
    baseline_map=fpga/'build/full_integration_20261013/board_postsyn_20261025_005840_892166'
    def timing(folder):
        text=(folder/'device_map/pango_video_system.dmr').read_text(errors='replace')
        return {' '.join(line.split()) for line in text.splitlines() if re.match(r'^\s*(create_clock|create_generated_clock|set_\w+) ',line)}
    checks['native_timing_inventory_unchanged']=timing(mapping)==timing(baseline_map)
    for i,folder in enumerate(a.software):
        folder=folder.resolve();r=read(folder/'result.json')
        checks['software_'+str(i)]=r['passed'] and r['inputs_intact'] and all(sha(folder/n)==h for n,h in r['frozen_files'].items()) and all(sha(Path(n))==h for n,h in r['origins'].items())
        # Independent candidates are reusable only for byte-identical modules;
        # an overlapping composition must supply its own functional evidence.
        for origin,h in r['origins'].items():
            normalized=Path(origin).as_posix()
            if '/source/rtl/' in normalized:
                n='rtl/'+normalized.split('/source/rtl/',1)[1]
                if hashes.get(n)==h:covered.add(n)
        evidence['software_'+str(i)]={'path':str(folder),'result_sha256':sha(folder/'result.json')}
    integrity=read(a.integrity/'result.json');cdc=read(a.cdc/'result.json')
    for label,folder,r,key in [('integrity',a.integrity,integrity,'hashes'),('cdc',a.cdc,cdc,'source_hashes')]:
        checks[label+'_complete']=r['passed'] and r['snapshot_intact']
        selected=r[key]
        # These suites freeze a flat RTL subset. Their path may name an earlier
        # candidate; only exact matching module bytes permit evidence reuse.
        checks[label+'_binding']=all(selected[Path(n).name]==h for n,h in hashes.items() if n.startswith('rtl/') and Path(n).name in selected)
        if label=='integrity':checks[label+'_frozen']=r['inputs_intact'] and all(sha(folder/n)==h for n,h in selected.items())
        else:checks[label+'_frozen']=all(sha(folder/'source'/n)==h for n,h in selected.items())
        evidence[label]={'path':str(folder.resolve()),'result_sha256':sha(folder/'result.json')}
    host=read(a.host)
    checks['host_decode']=host['passed'] and host['companion_snapshot_intact'] and Path(host['input_directory']).resolve()==a.network.resolve()
    checks['host_input_binding']=all(sha(a.network/n)==h for n,h in host['input_sha256'].items())
    checks['host_decoder_binding']=all(sha(Path(host['companion_snapshot_directory'])/n)==h for n,h in host['companion_files_sha256'].items())
    evidence['host']={'path':str(a.host.resolve()),'sha256':sha(a.host)}
    changed=[n for n,h in hashes.items() if n.startswith('rtl/') and baseline_hashes.get(n)!=h]
    # The board wrapper is elaborated by native compile; its parameter pairing
    # is additionally exercised by the frozen boot/upload/consumer fixture.
    uncovered=sorted(set(changed)-covered-{'rtl/board/pango_video_system.sv'})
    checks['changed_rtl_functional_coverage']=not uncovered
    syn=synthesis(mapping/'synthesize/pango_video_system.snr')
    result=dict(passed=all(checks.values()),checks=checks,uncovered=uncovered,evidence=evidence,
                candidate=str(candidate),mapping=str(mapping),sources_sha256=sha(candidate/'sources.json'),
                mapped=resources,synthesis=syn,target_lut=39960,target_achieved=resources['total_lut']<=39960,
                production_selected=False,routed=False,hardware_tested=False,bitstream_generated=False)
    stamp=datetime.now().strftime('handoff_%Y%m%d_%H%M%S_%f');out=candidate/stamp;out.mkdir()
    shutil.copyfile(__file__,out/'package_script.py')
    (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print('AREA_HANDOFF',out,flush=True)
    if not result['passed']:raise RuntimeError('Incomplete handoff: '+str([k for k,v in checks.items() if not v]))
    if a.promote:
        gate_path=fpga/'config/implementation_readiness.json';gate=read(gate_path)
        if gate['whole_design_route_allowed'] or gate['bitstream_generation_allowed'] or (fpga/'build/route_optimization/native_phase.lock').exists():
            raise RuntimeError('Promotion waits for external native work and closed physical gates')
        old_l=fpga/'build/full_integration_20261013/board_postsyn_20261023_221908_913042'
        l_hashes=read(old_l/'sources.json');copies=[]
        # Check all preimages before the first write. Preserve unrelated edits,
        # constraints, IP and the independent control experiment's frozen input.
        for n,h in hashes.items():
            if not n.startswith('rtl/'):continue
            current=sha(fpga/n)
            if current==h:continue
            if current not in (l_hashes.get(n),baseline_hashes.get(n)):
                raise RuntimeError('Production RTL drift: '+n)
            copies.append((n,current,h))
        for n,before,after in copies:
            backup=out/'before'/n;backup.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(fpga/n,backup)
        shutil.copyfile(gate_path,out/'readiness_before.json')
        (out/'promotion_manifest.json').write_text(json.dumps([dict(path=n,before=b,after=h) for n,b,h in copies],indent=2))
        for n,before,after in copies:
            if sha(fpga/n)!=before:raise RuntimeError('Concurrent RTL write: '+n)
            install_rtl(candidate/'source'/n,fpga/n,after)
            assert sha(fpga/n)==after
        # Historical L/OFF timing and physical counters describe a different
        # netlist. Preserve them explicitly before installing current evidence;
        # no old route or pre-route approval may attach to the new RTL.
        replaced=('latest_mapped_candidate','latest_routed_unrouted_nets',
                  'pre_route_timing_review','pre_route_review_complete',
                  'physical_constraint_inheritance_review','route_task',
                  'synthesis_estimated_ddr_setup_wns_ns','completed_simulation_scope',
                  'completed_simulation_group_count','mcu_config_revocation_evidence',
                  'constraint_diagnostics_review','latest_mapped_below_target')
        gate['area60_prior_selection']={n:gate.get(n) for n in replaced}
        gate.update(whole_design_route_allowed=False,bitstream_generation_allowed=False,
                    selected_source_simulation_passed=True,compile_synthesize_map_allowed=True,
                    completed_mapping_evidence=str((mapping/'result.json').relative_to(fpga.parent)),
                    latest_resource_evidence=str((out/'result.json').relative_to(fpga.parent)),
                    completed_simulation_evidence=str((out/'result.json').relative_to(fpga.parent)),
                    completed_simulation_scope=['full_frame','control_test','display_test',
                        'network_test','host_raw8_decode','mcu_config_integrity',
                        'job_result_cdc','independent_module_oracles'],
                    completed_simulation_group_count=len(evidence)-1,
                    mcu_config_revocation_evidence=str((a.integrity.resolve()/'result.json').relative_to(fpga.parent)),
                    constraint_diagnostics_review=str((mapping/'result.json').relative_to(fpga.parent)),
                    selected_native_build=str(mapping.relative_to(fpga.parent)),
                    latest_mapped_candidate=str(mapping.relative_to(fpga.parent)),
                    latest_mapped_lut=resources['total_lut'],latest_mapped_utilization_percent=resources['utilization_percent'],
                    latest_mapped_target_percent=60,
                    latest_mapped_below_target=result['target_achieved'],
                    latest_mapped_below_strict_70_percent=resources['below_70_percent'],
                    area60_target_achieved=result['target_achieved'],
                    latest_physical_status='NOT_RUN_AREA60_SELECTED',physical_signoff_pending=True,
                    latest_routed_unrouted_nets=None,pre_route_review_complete=False,
                    pre_route_timing_review=None,physical_constraint_inheritance_review=None,
                    synthesis_estimated_ddr_setup_wns_ns=syn['ddr_domain_setup_wns_ns'],
                    internal_timing_met=False,
                    route_task='fpga/reports/LUT60结构优化布线交接_20261025.md',
                    reason='Area candidate selected after bound software and explicit-SCF MAP; new routing and bitstream remain gated.',
                    updated_at=datetime.now().astimezone().isoformat())
        gate_path.write_text(json.dumps(gate,indent=2)+'\n',encoding='utf-8')
        result['production_selected']=True;result['promoted_rtl_count']=len(copies);result['readiness_sha256']=sha(gate_path)
        (out/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print('AREA_PROMOTED',len(copies),flush=True)


if __name__=='__main__':main()

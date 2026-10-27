"""Bind PC-only functional proofs and MAP before one monitored physical run."""
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
import tempfile
from types import SimpleNamespace
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget,validate_route_scope,close_route_scope
from package_block_pressure_handoff import synthesis


def sha(p):
    """Hash real inputs/evidence; no result is inferred from a path name."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def read(p):
    """Keep preserved Windows UTF-8 evidence readable without mutation."""
    return json.loads(p.read_text(encoding='utf-8-sig'))


def main():
    """Prepare a closed review or launch its exact no-bitgen physical scope."""
    ap=argparse.ArgumentParser(description=__doc__)
    for n in ['mapping','full','protocol','host','review']:ap.add_argument('--'+n,type=Path)
    # The first congestion experiment changes only placement expansion. Keep
    # the legacy baseline default; a trial must name the reviewed same-MAP
    # baseline instead of silently changing seeds, timing or iteration limits.
    ap.add_argument('--placement-decongestion',type=int,choices=[1,2],default=None,
                    help='Prepare only: baseline 1 or single-variable expansion trial 2')
    ap.add_argument('--baseline-review',type=Path,
                    help='Required for expansion 2; binds the same MAP and functional proofs')
    ap.add_argument('--launch',action='store_true');a=ap.parse_args()
    if a.review is not None and (a.placement_decongestion is not None or a.baseline_review is not None):
        ap.error('Verify/launch uses the frozen review options; prepare a new review to change strategy')
    decongestion=a.placement_decongestion if a.placement_decongestion is not None else 1
    if (decongestion==2)!=(a.baseline_review is not None):
        ap.error('Expansion 2 requires --baseline-review; baseline 1 does not use it')
    fpga=Path(__file__).resolve().parents[1]
    if a.review is None:
        if a.launch:ap.error('Prepare and inspect --review before --launch')
        if any(getattr(a,n) is None for n in ['mapping','full','protocol','host']):ap.error('All four evidence paths are required')
        mapping=a.mapping.resolve();manifest=read(mapping/'sources.json');checks={}
        checks['frozen_sources']=all(sha(mapping/'source'/n)==h for n,h in manifest.items())
        checks['working_sources']=all(sha(fpga/n)==h for n,h in manifest.items() if n.startswith(('rtl/','constraints/')))
        m=read(mapping/'result.json');checks['map_complete']=m['native_exit']==0 and not m['errors'] and m['syn_intact']
        constraints=require_native_constraints(mapping);resources=require_mapped_lut_budget(mapping)
        base=fpga/'build/full_integration_20261013/board_postsyn_20261025_162347_361985'
        prior=read(base/'sources.json')
        changed=sorted(n for n,h in manifest.items() if prior.get(n)!=h)
        # The frozen closure includes documentation and the historical gate
        # record as evidence; neither is registered as an RTL/timing input.
        checks['only_declared_inputs_changed']=changed==sorted(['rtl/board/pango_video_system.sv','rtl/board/video_memory_core.sv',
            'rtl/control/pc_video_boot.sv','constraints/video_system/clocks_cdc.fdc',
            'config/implementation_readiness.json','config/integration/ENTITY_CONTROL.md',
            'constraints/video_system/processing_cdc.fdc'])
        commands=lambda p:{' '.join(s.split()) for s in p.read_text().splitlines() if s.strip() and not s.lstrip().startswith('#')}
        old=commands(base/'source/constraints/video_system/clocks_cdc.fdc');new=commands(mapping/'source/constraints/video_system/clocks_cdc.fdc')
        checks['only_absent_mcu_cdc_removed']=not(new-old) and len(old-new)==2 and all('mcu_link.uart.rx_meta' in s for s in old-new)
        old=commands(base/'source/constraints/video_system/processing_cdc.fdc');new=commands(mapping/'source/constraints/video_system/processing_cdc.fdc')
        checks['only_absent_counter_cdc_removed']=not(new-old) and len(old-new)==2 and all('job_mailbox.source_result*' in s for s in old-new)
        # The removed diagnostics were the sole consumers. A synthesized
        # surviving counter capture would invalidate this constraint removal.
        vm=(mapping/'synthesize/pango_video_system_syn.vm').read_text(errors='replace')
        checks['counter_capture_absent_in_netlist']='source_result' not in vm
        pcf=lambda p:{' '.join(s.split()) for s in p.read_text().splitlines() if s.startswith('def_')}
        checks['physical_ports_sites_unchanged']=pcf(base/'device_map/pango_video_system.pcf')==pcf(mapping/'device_map/pango_video_system.pcf')
        full=read(a.full/'result.json');full_sources=read(a.full/'sources.json')
        checks['full_frame_passed']=full['passed'] and full['snapshot_intact'] and full['board_manual_profile'] and full['display_test'] and full['control_test']
        checks['full_frame_source_binding']=all(sha(a.full/'source'/n)==h and (not n.startswith('rtl/') or manifest.get(n)==h) for n,h in full_sources.items())
        checks['pc_only_full_fixture']='.PC_ONLY_CONTROL(BOARD_MANUAL_PROFILE)' in (a.full/'source/sim/tb_video_memory_core.sv').read_text()
        protocol=read(a.protocol/'result.json')
        checks['protocol_complete']=protocol['passed'] and protocol['inputs_intact'] and len(protocol['cases'])==8 and all(x['passed'] for x in protocol['cases'])
        checks['protocol_frozen']=all(sha(a.protocol/n)==h for n,h in protocol['frozen'].items())
        # Unit compilation also freezes historical standalone modules omitted
        # by the board build. Bind every module actually in the board closure.
        checks['protocol_source_binding']=all(sha(Path(n))==h and (not Path(n).is_relative_to(fpga/'rtl') or manifest.get(Path(n).relative_to(fpga).as_posix(),h)==h) for n,h in protocol['origins'].items())
        host=read(a.host);hostroot=fpga.parent/'host'
        checks['host_complete']=host['passed'] and host['inputs_intact'] and len(host['cases'])==3 and all(c['passed'] for c in host['cases'])
        checks['host_frozen']=all(sha(Path(host['source'])/n)==h and sha(hostroot/n)==h for n,h in host['origins'].items())
        board=(mapping/'source/rtl/board/pango_video_system.sv').read_text()
        checks['actual_board_profile']=all(t in board for t in [".ENTITY_MASK(16'h028a)",'.SUMMARY_READBACK(1)','.PC_ONLY_CONTROL(1)']) and 'mcu_link_adapter #(' not in board
        # Native SYN hierarchy confirms actual removal, independently of masks.
        syn=synthesis(mapping/'synthesize/pango_video_system.snr')
        modules=syn.pop('modules')
        checks['mcu_and_motion_hierarchy_removed']=not any(any(token in row['path'].split('/') for token in ['mcu_link','motion_control','pose_model','selector']) for row in modules)
        logs=(a.full/'run.log').read_text()
        cycles=[int(v) for v in re.findall(r'FRAME_GEOMETRY job=\d+ geometry_cycles=(\d+)',logs)]
        checks['frame_budget']=len(cycles)==3 and max(cycles)/125000000<1/30
        checks['hdmi_pixels']='checked_pixels=8294400 failed=0 underflow=0' in logs
        checks['raw_frames']='TB_VIDEO_MEMORY_CORE_PASS bytes=6220800 good=3 processed=3' in logs
        out=fpga/'build/pc_only_20261026'/datetime.now().strftime('review_%H%M%S_%f');out.mkdir(parents=True)
        options=dict(stop_after_timing=True,monitor_only=True,from_placement=False,pnr_timeout_minutes=0,phase_timeout_minutes=0,
            placement_seed=13,placement_decongestion=decongestion,mode='normal',control_chain_length=500,congestion_iterations=200,
            dump_congestion=True,logic_optimize='enabled',lut6d_strategy=3,cell_duplication='default',macro_placement=None,
            planning_before_place=False,installed_pnr_help=None,pin_cost_increasing_speed=None,pause_file=str(out/'stop_requested.json'))
        names=['sources.json','flow.tcl','flow.pds','device_map/pango_video_system_map.adf','device_map/pango_video_system.dmr',
               'device_map/pango_video_system.pcf','synthesize/pango_video_system_syn.adf','synthesize/pango_video_system.snr','result.json']
        scripts=['resume_video_system.py','route_supervisor.py','implementation_readiness.py','constraint_report.py','native_bitgen.py']
        evidence={n:dict(path=str(p.resolve()),sha256=sha(p)) for n,p in [('full',a.full/'result.json'),('protocol',a.protocol/'result.json'),('host',a.host)]}
        # Validate the baseline bytes while the existing job may still be
        # routing. A strategy trial uses an isolated MAP copy so completion
        # of the running job cannot invalidate or overwrite its inputs.
        # Preparation never publishes a gate or interrupts the current job.
        strategy=dict(placement_decongestion=decongestion,measured_improvement=False)
        if a.baseline_review is not None:
            baseline=read(a.baseline_review);prior=baseline['scope']
            original=Path(prior['build']).resolve()
            validate_route_scope(dict(pre_route_review_complete=True,bitstream_generation_allowed=False,
                                     route_scope=prior),original,SimpleNamespace(**prior['options']))
            checks['strategy_baseline_passed']=baseline['passed'] and all(baseline['checks'].values())
            checks['strategy_same_proofs']=evidence==baseline['evidence']
            checks['strategy_isolated']=mapping!=original
            checks['strategy_same_inputs']=all(sha(mapping/n)==h for n,h in prior['files'].items()
                                              if n not in ['flow.tcl','flow.pds'])
            checks['strategy_only_project_paths_rebased']=all(
                (mapping/n).read_text(encoding='utf-8')==
                (original/n).read_text(encoding='utf-8').replace(original.as_posix(),mapping.as_posix()).replace(str(original),str(mapping))
                for n in ['flow.tcl','flow.pds'])
            # Each review owns a separate stop path; that bookkeeping change
            # is excluded from the single physical-parameter comparison.
            changed_options=sorted(n for n in set(options)|set(prior['options'])
                                   if n!='pause_file' and options.get(n)!=prior['options'].get(n))
            checks['strategy_only_expansion_changed']=(changed_options==['placement_decongestion']
                                                       and prior['options']['placement_decongestion']==1)
            strategy.update(baseline_review=str(a.baseline_review.resolve()),baseline_sha256=sha(a.baseline_review),
                            changed_physical_options=changed_options,
                            official_basis='PDS 2022.2-SP6.4 User Guide printed p111: expansion can improve routing at a timing cost')
        review=dict(passed=all(checks.values()),checks=checks,changed_inputs=changed,mapping=str(mapping),mapped=resources,synthesis=syn,
            lut_below_60_percent=resources['total_lut']<39960,target_exclusive=39960,frame_cycles=cycles,
            evidence=evidence,constraints=constraints,scope=dict(id=out.name,build=str(mapping),options=options,files={n:sha(mapping/n) for n in names}),
            scripts={n:sha(fpga/'scripts'/n) for n in scripts},strategy=strategy,routed=False,bitstream_generated=False,hardware_tested=False,
            decision='Permit PnR and min/max STA diagnosis; synthesis slack is an estimate, not routed signoff. No bitgen.',
            open_items=['33 existing shared-pin critical warnings require board review','External IO timing and hardware throughput unverified'])
        shutil.copyfile(__file__,out/'review_script.py')
        (out/'review.json').write_text(json.dumps(review,indent=2),encoding='utf-8')
        print('PC_ONLY_REVIEW',out/'review.json',flush=True)
        if not review['passed']:raise RuntimeError(str([n for n,v in checks.items() if not v]))
        return
    review=read(a.review);assert review['passed'] and all(review['checks'].values())
    mapping=Path(review['mapping']);out=a.review.resolve().parent;scope=review['scope'];options=scope['options']
    assert all(sha(fpga/'scripts'/n)==h for n,h in review['scripts'].items())
    assert all(sha(Path(v['path']))==v['sha256'] for v in review['evidence'].values())
    assert all(sha(mapping/'source'/n)==h for n,h in read(mapping/'sources.json').items())
    validate_route_scope(dict(pre_route_review_complete=True,bitstream_generation_allowed=False,route_scope=scope),mapping,SimpleNamespace(**options))
    if not a.launch:print('PC_ONLY_REVIEW_VERIFIED',mapping);return
    inventory=subprocess.run(['powershell','-NoProfile','-Command',
        "@(Get-CimInstance Win32_Process -ErrorAction Stop | Where-Object { $_.Name -in @('pds_shell.exe','ads.exe','pnr.exe') } | Select-Object ProcessId,Name) | ConvertTo-Json -Compress"],capture_output=True,check=True)
    assert not inventory.stdout.strip() or json.loads(inventory.stdout)==[]
    gatepath=fpga/'config/implementation_readiness.json';gate=read(gatepath)
    assert not gate['whole_design_route_allowed'] and not (fpga/'build/route_optimization/native_phase.lock').exists()
    shutil.copyfile(gatepath,out/'readiness_before_launch.json')
    gate.update(design_complete=True,selected_source_simulation_passed=True,resource_and_constraints_reviewed=True,
        whole_design_route_allowed=True,pre_route_review_complete=True,bitstream_generation_allowed=False,
        route_scope=scope,route_scope_status='PC_ONLY_UNLIMITED_MONITOR',reason='User-requested PC-only resource and routing optimization; functional/MAP proof passed.',
        pre_route_timing_review=str(a.review.resolve()),physical_constraint_inheritance_review=str(a.review.resolve()),
        completed_simulation_evidence=str(a.review.resolve()),completed_simulation_scope=['PC UART compact profile','1080p control and HDMI','RAW bytes','host control codecs'],
        completed_simulation_group_count=4,completed_mapping_evidence=str(mapping/'result.json'),latest_resource_evidence=str(a.review.resolve()),
        selected_native_build=str(mapping),latest_mapped_candidate=str(mapping),constraint_diagnostics_review=str(a.review.resolve()),
        latest_mapped_lut=review['mapped']['total_lut'],latest_mapped_utilization_percent=review['mapped']['utilization_percent'],
        latest_mapped_below_target=review['lut_below_60_percent'],area60_target_achieved=review['lut_below_60_percent'],
        synthesis_estimated_ddr_setup_wns_ns=review['synthesis']['ddr_domain_setup_wns_ns'],
        mcu_simulation_evidence=None,mcu_config_revocation_evidence=None,internal_timing_met=False,
        physical_signoff_pending=True,latest_physical_status='PC_ONLY_ROUTE_STARTING',
        review_document='fpga/reports/PC动态控制精简与布线优化_20261026.md',route_task='fpga/reports/PC动态控制精简与布线优化_20261026.md',
        updated_at=datetime.now().astimezone().isoformat())
    fd,name=tempfile.mkstemp(dir=gatepath.parent,prefix='.pc-only-');os.close(fd)
    Path(name).write_text(json.dumps(gate,indent=2),encoding='utf-8');os.replace(name,gatepath)
    command=[sys.executable,str(fpga/'scripts/resume_video_system.py'),'--build',str(mapping)]
    for n,v in options.items():
        if v is None or v is False:continue
        command.append('--'+n.replace('_','-'))
        if v is not True:command.append(str(v))
    (out/'launch.json').write_text(json.dumps(dict(pid=os.getpid(),at=datetime.now().astimezone().isoformat(),command=command),indent=2))
    try:
        subprocess.run(command+['--check-only'],check=True)
        with (out/'driver.log').open('wb') as log:
            result=subprocess.run(command,cwd=fpga.parent,stdout=log,stderr=subprocess.STDOUT)
        print('PC_ONLY_ROUTE_EXIT',result.returncode,flush=True)
        # Preserve native driver failure for the campaign instead of reporting
        # a successful launcher merely because the monitoring process ended.
        if result.returncode:raise SystemExit(result.returncode)
    finally:close_route_scope(scope['id'],mapping/'result.json')


if __name__=='__main__':main()

"""Bind exact parent unit proofs and fresh GH2 integration evidence.

Reused tests retain their original identity: no test is described as rerun.
The new full-video run must include both modified RTL modules. Native callers
use functional_proof(), which only reads and validates an existing review.
"""
from datetime import datetime
import json
from pathlib import Path
import re

from evaluate_g_candidate import frozen_sources, functional_proof as g_proof, read, sha
from evaluate_h2_candidate import functional_proof as h2_proof, constraint_adaptation

FPGA=Path(__file__).resolve().parents[1]
ROOT=FPGA/'build/gh2_integration_20261101'
BANK='rtl/control/frame_parameter_bank.sv'
BRIDGE='rtl/memory/dma_write_cdc.sv'
CDC='constraints/video_system/processing_cdc.fdc'


def actual_video_configuration(run, candidate, fixture, manifest):
    """Bind the executed command and generated Verilator target, not only flags.

    Source membership and each elaboration parameter are checked explicitly;
    duplicate or unexpected parameter overrides require independent review.
    """
    command_path=ROOT/'full_video/command.json'
    command=read(command_path)
    expected=['-B',str(FPGA/'scripts/sim_video_verilator.py'),
        '--rtl-snapshot',str(candidate/'source'),'--fixture-snapshot',str(fixture),
        '--full-frame','--board-manual-profile','--source-gamma','--projective','--fixed-gray',
        '--control-test','--display-test','--stop-to-update','--build-jobs','2',
        '--run-timeout-seconds','2400','--pause-file',str(ROOT/'full_video/stop_requested.json')]
    assert command[1:]==expected,'Video invocation differs from reviewed profile'
    cmake_path=run/'CMakeLists.txt';cmake=cmake_path.read_text(encoding='utf-8')
    assert re.findall(r'TOP_MODULE\s+(\w+)',cmake)==['tb_video_memory_core']
    params=re.findall(r'-G(\w+)=(\d+)',cmake)
    expected_params=dict(WIDTH='1920',HEIGHT='1080',CONTROL_TEST='1',DISPLAY_TEST='1',
        BOARD_MANUAL_PROFILE='1',STOP_TO_UPDATE='1',PROJECTIVE='1',GRAYSCALE_FIXED='1',SOURCE_GAMMA='1')
    assert len(params)==len(expected_params) and dict(params)==expected_params
    source_text=cmake.split('\n SOURCES\n',1)[1].split('\n INCLUDE_DIRS',1)[0]
    actual_sources=re.findall(r'"([^"\n]+)"',source_text)
    # The layout header is text-included by fabric/pool, not a separate HDL
    # compilation unit. Its bytes remain part of the frozen video manifest.
    header='rtl/memory/frame_manager_layout.vh'
    assert header in manifest
    for consumer in ('frame_memory_fabric.sv','frame_pool_bank.sv'):
        contents=(run/'source/rtl/memory'/consumer).read_text(encoding='utf-8')
        assert '`include "frame_manager_layout.vh"' in contents
    assert f'INCLUDE_DIRS "{(run/"source/rtl/memory").as_posix()}"' in cmake
    expected_sources={(run/'source'/name).as_posix() for name in manifest if name!=header}
    assert len(actual_sources)==len(expected_sources) and set(actual_sources)==expected_sources
    return dict(command_sha256=sha(command_path),cmake_sha256=sha(cmake_path),
        top='tb_video_memory_core',parameters=expected_params,source_membership_verified=True)


def collect(candidate):
    """Fail on changed dependencies, wrong fixtures or incomplete combined video."""
    assert candidate.resolve()==(ROOT/'candidate').resolve()
    manifest=frozen_sources(candidate)
    g=FPGA/'build/parameter_ce_20261031/G_integration/candidate'
    h=FPGA/'build/write_cdc_owned_read_20261031/H2_candidate'
    de=FPGA/'build/DE_optimization_20261031/candidate'
    gm,gp=g_proof(g); hm,hp=h2_proof(h); dm=frozen_sources(de)
    assert set(manifest)==set(gm)==set(hm)==set(dm)
    assert manifest==dict(hm, **{BANK:gm[BANK]})
    assert {n for n in dm if dm[n]!=manifest[n]}=={BANK,BRIDGE,CDC}
    g_final=g.parent/'netlist_review.json'
    h_final=h.parent/'final_review_20261101/final_review.json'
    assert read(g_final)['status']=='G_SYN_MAP_NETLIST_REVIEW_COMPLETE'
    assert read(h_final)['status']=='H2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE'
    frozen=read(candidate/'state.json')
    assert frozen['sources_sha256']==sha(candidate/'sources.json')
    assert frozen['parents']==dict(G=gp,H2=hp)
    for name,digest in frozen['parent_final_review_sha256'].items():
        assert sha(Path(name))==digest
    # Parent leaf tests remain applicable by exact byte identity. Check every
    # RTL dependency of the separately tested G consumers against GH2 as well.
    gr=read(Path(gp['path']));hr=read(Path(hp['path']))
    consumers=[]
    for entry in gr['affected_integrations']:
        run=Path(entry['path']); inputs=read(run/'sources.json'); matched=[]
        for name,item in inputs.items():
            if name.startswith('rtl/'):
                assert item['sha256']==manifest[name], 'Changed consumer dependency: '+name
                assert sha(run/'source'/name)==manifest[name]
                matched.append(name)
        consumers.append(dict(top=entry['top'],path=str(run),rtl_matched=matched,
            sources_sha256=sha(run/'sources.json'),reused=True,rerun=False))
    unit_g=Path(gr['unit_proof'])
    assert sha(unit_g/'source/candidate_original.sv')==manifest[BANK]
    unit_h=Path(hr['unit_proof']['path'])
    assert sha(unit_h/'dma_write_cdc.sv')==manifest[BRIDGE]
    vs=read(ROOT/'full_video/state.json')
    assert vs['status']=='VIDEO_PASSED_SOURCE_REVIEW_REQUIRED'
    assert vs['sources_sha256']==sha(candidate/'sources.json')
    run=Path(vs['build']);vr=read(run/'result.json'); vm=read(run/'sources.json')
    fixture=Path(vs['fixture'])
    assert fixture==FPGA/'build/full_integration_20261013/verilator_20261031_151216_378724/source'
    assert run not in [Path(gr['full_video']['path']),Path(hr['full_video']['path'])]
    assert sha(run/'result.json')==vs['result_sha256']
    for flag in ('passed','full_frame','display_test','control_test','board_manual_profile',
                 'source_gamma','fixed_gray','stop_to_update','projective','snapshot_intact'):
        assert vr[flag],flag
    assert {BANK,BRIDGE}.issubset(vm)
    for name,digest in vm.items():
        assert sha(run/'source'/name)==digest
        assert digest==(manifest[name] if name.startswith('rtl/') else sha(fixture/name))
    configuration=actual_video_configuration(run,candidate,fixture,vm)
    log=(run/'run.log').read_text(encoding='utf-8',errors='replace')
    match=re.search(r'DISPLAY_CORE_PASS new=(\d+) repeat=(\d+) checked_pixels=(\d+) failed=(\d+) underflow=(\d+)',log)
    assert match and tuple(map(int,match.groups()))==(3,5,16588800,0,0)
    for marker in ('STOP_TO_UPDATE_PASS','old_matrix_frozen=1','UPDATE_HOLD_PASS','TB_VIDEO_MEMORY_CORE_PASS'):
        assert marker in log
    bound=[candidate/'sources.json',Path(gp['path']),Path(hp['path']),g_final,h_final,
        unit_g/'result.json',unit_g/'sources.json',unit_h/'result.json',unit_h/'sources.json',
        run/'result.json',run/'sources.json',run/'run.log',run/'CMakeLists.txt',
        ROOT/'full_video/command.json',ROOT/'full_video/state.json']
    return manifest,dict(candidate=str(candidate),candidate_manifest_sha256=sha(candidate/'sources.json'),
        source_count=327,changes_vs_DE=[BANK,BRIDGE,CDC],parent_proofs=dict(G=gp,H2=hp),
        reused_unit_proofs=dict(G=dict(path=str(unit_g),exact_bank_bytes=True,rerun=False),
                               H2=dict(path=str(unit_h),exact_bridge_bytes=True,rerun=False)),
        reused_consumers=consumers,constraint_adaptation=constraint_adaptation(candidate),
        full_video=dict(path=str(run),fresh_run=True,source_count=len(vm),new_frames=3,
            repeated_frames=5,checked_pixels=16588800,underflow=0,old_frame_and_drain_passed=True,
            actual_configuration=configuration,
            result_sha256=sha(run/'result.json'),sources_sha256=sha(run/'sources.json')),
        bound_evidence={str(p):sha(p) for p in bound},
        solver_note='DE solver bytes unchanged; exact G UART consumer dependencies reused. Full-video top does not instantiate the UART solver.',
        native_board_RAM_FSM_and_CE_gate_required=True,physical_signoff=False,
        promoted=False,routing_started=False)


def functional_proof(candidate):
    """Native preflight verifies the fixed review without changing its hash."""
    manifest,core=collect(candidate)
    path=ROOT/'functional_review.json';review=read(path)
    assert review['passed'] and all(review[k]==value for k,value in core.items())
    return manifest,dict(path=str(path),sha256=sha(path),sources_sha256=sha(candidate/'sources.json'),
        source_count=327,combined_full_video_fresh=True,parent_unit_proofs_reused=True)


def main():
    """Create one review only after the combined run has actually completed."""
    manifest,core=collect(ROOT/'candidate')
    result=dict(core,passed=True,checked_at=datetime.now().astimezone().isoformat())
    path=ROOT/'functional_review.json'
    with path.open('x',encoding='utf-8') as out:
        json.dump(result,out,indent=2)
    functional_proof(ROOT/'candidate')
    print(json.dumps(dict(status='GH2_FUNCTIONAL_REVIEW_PASSED',source_count=len(manifest),
        sources_sha256=sha(ROOT/'candidate/sources.json'),full_video=core['full_video']),indent=2))


if __name__=='__main__':main()

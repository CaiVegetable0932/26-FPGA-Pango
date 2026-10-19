"""Select the proven tile-boundary architecture without permitting whole PnR."""
from pathlib import Path
from datetime import datetime
import hashlib,json,re,sys
R=Path(__file__).resolve().parents[4];F=R/'fpga';S=Path(__file__).parent
sys.path.insert(0,str(F/'scripts'));from prepare_processing_fixture import adapt
def load(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def write(p,data):
    p.parent.mkdir(parents=True,exist_ok=True)
    if p.exists():
        with p.open('r+b') as out:out.write(data);out.truncate()
    else:p.write_bytes(data)
c=F/'build/route_optimization/proc150_board_20261020_044427_625524'
model_input=F/'build/route_optimization/proc150_video_model_20261020_043529_242103'
m=F/'build/full_integration_20261013/verilator_20261020_044250_609135'
mapping=F/'build/route_optimization/proc150_board_mapping_20261020_050951_080852'
fixture=F/'build/route_optimization/proc150_fixture_20261020_052157_013140'
host=R/'host/reports/fpga_rgb_vectors_20261020_052259_836952.json'
base=load(S/'recovery_finalist/sources.json');new=load(c/'sources.json')
assert all(sha(F/n)==v for n,v in base.items()) and all(sha(c/'source'/n)==v for n,v in new.items())
mr=load(m/'result.json');assert all(mr[k] for k in ['passed','snapshot_intact','full_frame','control_test','snapshot_test','display_test'])
for n,v in load(m/'sources.json').items():
    assert sha(m/'source'/n)==v
    if n.startswith('rtl/'):assert new[n]==v
for tag,full,network,snapshot in [('050821_373307',False,False,True)]:
    p=F/('build/full_integration_20261013/sim_20261020_'+tag);d=load(p/'result.json')
    assert d['passed'] and len(d['tests'])==20
    for n,v in load(p/'sources.json').items():
        assert sha(p/'source'/Path(n).name)==v
        if n.startswith('rtl/'):assert new[n]==v
for tag in ['051856_347330','052214_318729']:
    p=F/('build/full_integration_20261013/verilator_20261020_'+tag);d=load(p/'result.json')
    assert d['passed'] and d['network_test'] and d['snapshot_intact']
    for n,v in load(p/'sources.json').items():
        assert sha(p/'source'/n)==v
        if n.startswith('rtl/'):assert new[n]==v
# A guarded test-only hierarchy reference is the sole fixture adaptation;
# snapshot-enabled observations/assertions remain the exact original oracle.
tb='sim/tb_video_memory_core.sv';final_tb=(fixture/'source'/tb).read_bytes()
assert final_tb==adapt((model_input/'source'/tb).read_text()).encode()
default=F/'build/full_integration_20261013/sim_20261020_052124_365537'
assert load(default/'result.json')['passed'] and len(load(default/'result.json')['tests'])==20
assert load(default/'sources.json')[tb]==hashlib.sha256(final_tb).hexdigest()
assert sha(F/tb)==sha(F/'build/full_integration_20261013/verilator_20261020_043518_857947/source'/tb)
native=load(mapping/'mapping_validation.json');audit=load(mapping/'processing_mapping_audit.json')
assert native['passed'] and native['inputs_intact'] and audit['passed']
native_build=Path(native['source_build'])
for n,v in native['source_hashes'].items():assert new[n]==v==sha(native_build/'source'/n)
for n,v in native['validated_artifacts'].items():assert sha(mapping/n)==v
assert sha(mapping/'device_map/pango_video_system.dmr')==audit['map_report_sha256']
assert not audit['routed_timing_signed_off'] and not audit['new_critical_warnings']
reset=F/'build/route_optimization/proc150_reset_20261020_040449_764699'
rd=load(reset/'result.json');assert rd['passed']
assert rd['inputs_intact'] and all(sha(Path(n))==v and sha(reset/Path(n).name)==v for n,v in rd['inputs'].items())
assert new['rtl/board/processing_domain_reset.sv']==sha(reset/'processing_domain_reset.sv')
hr=load(host);assert hr['passed'] and hr['companion_snapshot_intact'] and Path(hr['input_directory'])==m
for n,v in hr['companion_files_sha256'].items():assert sha(Path(hr['companion_snapshot_directory'])/n)==v
for n,v in hr['input_sha256'].items():assert sha(m/n)==v==sha(F/'build/full_integration_20261013/verilator_20261020_043518_857947'/n)
log=(m/'run.log').read_text();cycles=list(map(int,re.findall(r'FRAME_GEOMETRY job=\d+ geometry_cycles=(\d+)',log)))
assert len(cycles)==3 and max(cycles)<125000000/30
assert 'DISPLAY_CORE_PASS new=3 repeat=8 checked_pixels=22809600 failed=0 underflow=0' in log
changes=['rtl/board/pango_video_system.sv','rtl/board/video_memory_core.sv','constraints/video_system/clocks_cdc.fdc',
 'constraints/video_system/processing_cdc.fdc','rtl/board/processing_domain_reset.sv',
 'rtl/geometry/geometry_frame_processor_external_refill.sv','rtl/geometry/geometry_processing_domain.sv',
 'rtl/geometry/geometry_processing_domain_external_refill.sv','rtl/memory/dma_write_cdc.sv',
 'rtl/memory/processing_job_cdc.sv','rtl/memory/tile_refill_cdc.sv',tb]
actual={n for n,v in new.items() if not (F/n).exists() or sha(F/n)!=v}
assert actual==set(changes)
backup=S/'processing_promotion_20261020';backup.mkdir()
for n in changes:
    if (F/n).exists():write(backup/'before'/n,(F/n).read_bytes())
for n in changes:write(F/n,final_tb if n==tb else (c/'source'/n).read_bytes())
profile=dict(architecture='tile_refill_boundary',processing_mhz=150,memory_mhz=125,
    selected_change_count=15,model_proof=str(m.relative_to(R)),mapping_proof=str(mapping.relative_to(R)),
    common_controller_and_client_cold_reset=True,whole_design_route_allowed=False,
    unused_reference_adapter='geometry_processing_domain retained for frozen source coherence; not instantiated')
profile_name='config/integration/processing_domain.json';write(F/profile_name,(json.dumps(profile,indent=2)+'\n').encode())
expected={**new,tb:hashlib.sha256(final_tb).hexdigest(),profile_name:sha(F/profile_name)}
assert all(sha(F/n)==v for n,v in expected.items())
record=dict(at=datetime.now().astimezone().isoformat(),selected_change_count=15,
    changed_files=changes,profile=profile_name,board_candidate=str(c),full_model=str(m),host_report=str(host),
    mapping=str(mapping),native_sources_bound=len(native['source_hashes']),selected_source_files=len(expected),
    geometry_ddr_cycles=cycles,per_frame_budget_cycles=125000000/30,
    worst_case_headroom_cycles=125000000/30-max(cycles),worst_case_headroom_percent=100*(1-max(cycles)/(125000000/30)),
    mapped_resources=audit['mapped_resources'],legacy_critical_warnings=61,new_critical_warnings=0,
    snapshot_bytes_identical=True,whole_design_routed=False,bitstream_generated=False,
    routed_timing_signed_off=False,physical_validation_owner='User-designated routing agent')
(backup/'promotion.json').write_text(json.dumps(record,indent=2))
final=S/'processing_finalist';final.mkdir();(final/'sources.json').write_text(json.dumps(expected,indent=2))
(final/'selection.json').write_text(json.dumps(record,indent=2))
# Production entry point smoke tests are still required before design closure.
g=F/'config/implementation_readiness.json';d=load(g)
assert not d['whole_design_route_allowed']
d['simulation_note']='Selected 15-change tile-boundary 150MHz architecture passed 20-case regression, full 1080p control/snapshot/display, link recovery, native MAP and structural clock/CDC audit. Root entry-point composition checks pending; whole routing remains prohibited.'
d['updated_at']=record['at'];write(g,(json.dumps(d,indent=2)+'\n').encode())
print('PROMOTED_PROCESSING',json.dumps(record))

"""Promote only the writer after complete source, byte, latency and STA gates."""
from pathlib import Path
from datetime import datetime
import hashlib,json,os,re,sys
ROOT=Path(__file__).resolve().parents[4]
F=ROOT/'fpga';S=Path(__file__).resolve().parent
sys.path.insert(0,str(F/'scripts'))
from regional_phase_budget import native_pnr_seconds
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def load(p):return json.loads(p.read_text(encoding='utf-8'))
candidate=F/'build/route_optimization/writer_span_pipeline_20261020_031048_641108'
model=F/'build/full_integration_20261013/verilator_20261020_033308_185785'
regression=F/'build/full_integration_20261013/sim_20261020_031100_679289'
host=ROOT/'host/reports/fpga_rgb_vectors_20261020_035641_996920.json'
screen=F/'build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen'
name='rtl/memory/frame_pixel_writer.sv'
closure=load(candidate/'sources.json');old=load(S/'unpack_finalist/sources.json')
assert len(closure)==len(old)==290
assert all(sha(candidate/'source'/n)==h for n,h in closure.items())
assert all(sha(F/n)==h for n,h in old.items()),'Unexpected live main change'
assert [n for n,h in closure.items() if h!=old[n]]==[name]
semantic=load(candidate/'semantic_20261020_031342_175996/result.json')
assert all(semantic[k] for k in ['passed','inputs_intact','semantic_equivalent','independent_byte_scoreboards','range_and_abort_tests'])
assert not semantic['cycle_equivalent'] and len(semantic['tests'])==50
assert semantic['extra_frame_startup_cycles']==semantic['measured_legal_and_invalid_startup_extra_cycles']==2
assert semantic['declared_per_segment_added_cycles']==0
assert all(sha(Path(p))==h for p,h in semantic['inputs'].items())
math=load(Path(semantic['upstream_full_product_proof'])/'result.json');assert math['passed']
mr=load(model/'result.json');assert all(mr[k] for k in ['passed','snapshot_intact','full_frame','control_test','snapshot_test','display_test'])
ms=load(model/'sources.json')
assert all(sha(model/'source'/n)==h for n,h in ms.items())
assert all(closure[n]==h for n,h in ms.items() if n.startswith('rtl/'))
rr=load(regression/'result.json');rs=load(regression/'sources.json')
assert rr['passed'] and len(rr['tests'])==20
assert all(sha(regression/'source'/Path(n).name)==h for n,h in rs.items())
assert all(closure[n]==h for n,h in rs.items() if n.startswith('rtl/'))
hr=load(host);assert hr['passed'] and hr['companion_snapshot_intact'] and Path(hr['input_directory'])==model
assert all(sha(Path(hr['companion_snapshot_directory'])/n)==h for n,h in hr['companion_files_sha256'].items())
comparison={}
for n in ['snapshot_datagrams.bin','snapshot_descriptors.bin']:
    before=F/'build/full_integration_20261013/verilator_20261020_001232_095496'/n
    assert sha(before)==sha(model/n)==hr['input_sha256'][n]
    comparison[n]=dict(identical=True,bytes=(model/n).stat().st_size,sha256=sha(model/n))
records=[];wrapper=None;pins=None
for case in sorted(screen.glob('regional_route_*')):
    d=load(case/'result.json');assert d['completed'] and d['clock_period_ns']==8 and d['placement_decongestion']==1
    assert len(d['jobs'])==1
    if wrapper is None:wrapper=d['wrapper_sha256'];pins=d['fixed_pin_configuration_sha256']
    assert wrapper==d['wrapper_sha256'] and pins==d['fixed_pin_configuration_sha256']
    j=d['jobs'][0]
    assert all(j[k] for k in ['completed','inputs_intact','fixed_pin_map_verified','all_internal_constraints_met'])
    build=case/'candidate'
    assert all(sha(build/n)==h for n,h in j['inputs'].items())
    assert sha(build/'report_timing/regional_wrapper.rtr')==j['report_sha256']
    records.append(dict(seed=d['seed'],case=str(case),timing_clean=True,
        native_pnr_seconds=native_pnr_seconds((build/'physical.log').read_text(errors='replace')),
        result_sha256=sha(case/'result.json'),wirelength=j['wirelength']))
assert sorted(r['seed'] for r in records)==[7,11,13]
summary=dict(sample_count=3,all_candidate_internal_sta_pass=True,records=records,
             baseline_timing_clean=False,acceleration_ratio=None,whole_design_signoff=False)
(S/'writer_three_seed_0358.json').write_text(json.dumps(summary,indent=2))
(model/'snapshot_baseline_comparison.json').write_text(json.dumps(comparison,indent=2))
# All validation precedes a single atomic replacement, with a byte backup.
backup=S/'writer_pipeline_promotion_20261020';backup.mkdir()
target=F/name;before=target.read_bytes();(backup/'before_frame_pixel_writer.sv').write_bytes(before)
temporary=target.with_suffix('.promotion.tmp');temporary.write_bytes((candidate/'source'/name).read_bytes());os.replace(temporary,target)
try:assert all(sha(F/n)==h for n,h in closure.items())
except BaseException:
    temporary.write_bytes(before);os.replace(temporary,target);raise
record=dict(at=datetime.now().astimezone().isoformat(),promoted_file=name,before_sha256=hashlib.sha256(before).hexdigest(),
    after_sha256=sha(target),selected_change_count=13,source_files_bound=290,
    candidate=str(candidate),model=str(model),regression=str(regression),host_report=str(host),
    startup_added_cycles=2,per_segment_added_cycles=0,geometry_cycles_unchanged=True,
    snapshot_bytes_identical=True,all_three_seeds_internal_sta_pass=True,
    native_reference_timing_failed=True,acceleration_ratio=None,whole_design_route_allowed=False)
(backup/'promotion.json').write_text(json.dumps(record,indent=2))
finalist=S/'writer_pipeline_finalist';finalist.mkdir()
(finalist/'sources.json').write_text(json.dumps(closure,indent=2))
(finalist/'selection.json').write_text(json.dumps(dict(status='PROMOTED_SINGLE_FILE',**record),indent=2))
config=F/'config/implementation_readiness.json';gates=load(config)
assert not any(gates[k] for k in ['design_complete','selected_source_simulation_passed','resource_and_constraints_reviewed','whole_design_route_allowed'])
gates['simulation_note']='Canonical 13-change design includes unpack locality and the writer two-cycle admission pipeline. 20-case regression, full 1080p control/snapshot/actual-display model and host decoding passed with identical snapshot bytes. Three isolated writer seeds met internal timing. Entire plan, actual 150MHz integration and final composition are incomplete; whole routing remains prohibited.'
gates['updated_at']=datetime.now().astimezone().isoformat()
config.write_text(json.dumps(gates,indent=2)+'\n')
print('PROMOTED',name,sha(target),'selected_changes',13)

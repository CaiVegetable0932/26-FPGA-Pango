"""Promote one verified fault-recovery fix, with immutable input binding."""
from pathlib import Path
from datetime import datetime
import hashlib,json
R=Path(__file__).resolve().parents[4];F=R/'fpga';S=Path(__file__).parent
def load(p):return json.loads(p.read_text(encoding='utf-8'))
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
c=F/'build/route_optimization/geometry_recovery_20261020_042541_182177'
m=F/'build/full_integration_20261013/verilator_20261020_043518_857947'
r=F/'build/full_integration_20261013/sim_20261020_043508_583868'
h=R/'host/reports/fpga_rgb_vectors_20261020_050710_104188.json'
old=load(S/'writer_pipeline_finalist/sources.json');new=load(c/'sources.json')
name='rtl/geometry/geometry_rgb_pipeline.sv'
assert len(old)==len(new)==290 and [n for n in new if new[n]!=old[n]]==[name]
assert all(sha(F/n)==v for n,v in old.items())
assert all(sha(c/'source'/n)==v for n,v in new.items())
assert all(load(m/'result.json').get(k) for k in ['passed','snapshot_intact','full_frame','control_test','snapshot_test','display_test'])
assert load(r/'result.json')['passed'] and len(load(r/'result.json')['tests'])==20
for proof,flat in [(m,False),(r,True)]:
    for n,v in load(proof/'sources.json').items():
        assert sha(proof/'source'/(Path(n).name if flat else n))==v
        if n.startswith('rtl/'):assert new[n]==v
faults=[]
for tag,count in [('042552_100909',1),('042552_140908',3)]:
    p=F/('build/route_optimization/proc150_tile_faults_20261020_'+tag)
    d=load(p/'result.json')
    assert d['passed'] and d['inputs_intact'] and d['completion_fault_kinds']==6
    assert d['independent_recovery_byte_scoreboard'] and len(d['tests'])==count
    assert sha(Path(d['pipeline_source']))==new[name]
    for n,v in load(p/'sources.json').items():assert sha(p/'source'/n)==v
    faults.append(str(p))
hr=load(h);assert hr['passed'] and hr['companion_snapshot_intact'] and Path(hr['input_directory'])==m
for n,v in hr['companion_files_sha256'].items():assert sha(Path(hr['companion_snapshot_directory'])/n)==v
for n,v in hr['input_sha256'].items():
    assert sha(m/n)==v==sha(F/'build/full_integration_20261013/verilator_20261020_033308_185785'/n)
b=S/'geometry_recovery_promotion_20261020';b.mkdir()
(b/'before_geometry_rgb_pipeline.sv').write_bytes((F/name).read_bytes())
(F/name).write_bytes((c/'source'/name).read_bytes())
assert all(sha(F/n)==v for n,v in new.items())
record=dict(at=datetime.now().astimezone().isoformat(),promoted_file=name,selected_change_count=14,
    before_sha256=old[name],after_sha256=new[name],source_files_bound=290,
    regression=str(r),full_model=str(m),host_report=str(h),fault_proofs=faults,
    snapshot_bytes_identical=True,latency_added_cycles=0,whole_design_route_allowed=False)
(b/'promotion.json').write_text(json.dumps(record,indent=2))
f=S/'recovery_finalist';f.mkdir();(f/'sources.json').write_text(json.dumps(new,indent=2))
(f/'selection.json').write_text(json.dumps(record,indent=2))
g=F/'config/implementation_readiness.json';d=load(g)
assert not any(d[k] for k in ['design_complete','selected_source_simulation_passed','resource_and_constraints_reviewed','whole_design_route_allowed'])
d['simulation_note']='Canonical 14-change 125MHz design passed 20-case regression, full 1080p control/snapshot/display and host decoding with unchanged raw snapshot bytes. Six completion fault types and subsequent frame recovery passed. Experimental 150MHz final composition and board resource/CDC review remain incomplete; no whole routing.'
d['updated_at']=record['at'];g.write_text(json.dumps(d,indent=2)+'\n')
print(json.dumps(record))

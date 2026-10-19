"""Archive final verified artifacts and exact authorized Git scope only."""
from pathlib import Path
import hashlib,json,subprocess,sys,zipfile
S=Path(__file__).parent;R=S.parents[3];F=R/'fpga';B=F/'build/full_integration_20261013';O=F/'build/route_optimization'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
mapping=O/'proc150_board_mapping_20261020_050951_080852'
archive=mapping/'native_mapping_0535.zip';members={}
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for folder in ['synthesize','device_map','constraint_check']:
        for p in sorted((mapping/folder).rglob('*')):
            if p.is_file() and p.suffix.lower() in ['.adf','.vm','.snr','.dmr','.prt','.pcf','.ccr']:
                n=p.relative_to(mapping).as_posix();z.write(p,n);members[n]=dict(bytes=p.stat().st_size,sha256=sha(p))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None and all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
am=mapping/'native_mapping_0535_manifest.json';am.write_text(json.dumps(dict(archive_sha256=sha(archive),members=members),indent=2))
handoff=B/'handoff_20261020_053147_229875'
reconstruction=dict(archive=str(archive.relative_to(R)),extract_to=str(mapping.relative_to(R)),
    copy_after_verification={str((handoff/'device_map'/Path(n).name).relative_to(R)):n for n in members if n.startswith('device_map/')},
    overwrite_existing_files=False,all_member_hashes=str(am.relative_to(R)))
(handoff/'restore_native_artifacts.json').write_text(json.dumps(reconstruction,indent=2))
doc=F/'reports/route_optimization_handoff_20261020.md';t=doc.read_text(encoding='utf-8')
t+='\n云端恢复原生大文件：校验`proc150_board_mapping_20261020_050951_080852/native_mapping_0535.zip`及其manifest，解压到该mapping目录，再按handoff工程`restore_native_artifacts.json`核验并复制device_map成员到handoff的device_map目录。已有文件须先核对哈希，不能覆盖不同的运行结果。源码、工程、日志及小型证明直接随Git保存。\n'
with doc.open('r+b') as o:o.write(t.encode());o.truncate()
attrs=R/'host/reports/.gitattributes';t=attrs.read_text().replace('\r\n','\n')
t+='\nfpga_rgb_vectors_20261020_052259_836952* -text\nfpga_rgb_vectors_20261020_052259_836952_companions/** -text\n'
attrs.write_bytes(t.encode())
partial=B/'verilator_20261020_052123_816076'
(partial/'generation_failure.json').write_text(json.dumps(dict(status='FIXTURE_BUNDLE_INCOMPLETE',
    rtl_simulation_launched=False,reason='Explicit fixture override lacked display helper before native configure; regenerated complete two-file bundle'),indent=2))
proofs=[B/n for n in ['verilator_20261020_044250_609135','verilator_20261020_051829_233742',
 'verilator_20261020_051856_347330','verilator_20261020_052214_318729','verilator_20261020_052630_443140',
 'sim_20261020_052124_365537','sim_20261020_052620_282958']]
proofs += [O/'proc150_board_gate_20261020_051951_032131']
trees=[mapping,handoff,B/'board_20261020_052640_715990',partial,
 O/'proc150_fixture_20261020_052115_686158',O/'proc150_fixture_20261020_052157_013140',
 S/'processing_promotion_20261020',S/'processing_finalist',
 R/'host/reports/fpga_rgb_vectors_20261020_052259_836952_companions']
files=[Path(__file__).resolve(),archive,am,attrs,R/'host/reports/fpga_rgb_vectors_20261020_052259_836952.json']
files += [S/n for n in ['promote_processing_0525.py','close_design_stage_0535.py','design_stage_completion.json',
 'session_complete.json','final_whole_route_gate_test.json','final_gate_0.log','final_gate_1.log','quota_observations.jsonl']]
files += [F/'scripts'/n for n in ['audit_processing_mapping.py','validate_completed_processing_map.py',
 'prepare_processing_fixture.py','prepare_processing_handoff.py','continue_proc150_mapping.py','build_video_system.py','resume_video_system.py']]
promotion=json.loads((S/'processing_promotion_20261020/promotion.json').read_text())
files += [F/n for n in promotion['changed_files']+[promotion['profile'],'config/implementation_readiness.json']]
files += [F/'reports'/n for n in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md',
 'regional_verification_plan_20261019.md','control_locality_review_20261020.md']]
files += [F/'experiments/proc150/README.md']
for proof in proofs:
    files += list(proof.glob('*.bin'))
    files += [p for p in [proof/'CMakeLists.txt',proof/'build_anchor.cpp'] if p.exists()]
subprocess.run([sys.executable,str(F/'scripts/freeze_regional_checkpoint.py'),'--label','0535','--session',str(S),
 '--proof',*map(str,proofs),'--input-tree',*map(str,trees),'--file',*map(str,files)],cwd=R,check=True)

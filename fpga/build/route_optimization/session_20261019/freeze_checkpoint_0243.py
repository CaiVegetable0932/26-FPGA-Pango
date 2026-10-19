"""Freeze terminal proofs/screens; exclude the active pool regional route."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[4]
S=Path(__file__).resolve().parent
REGION=ROOT/'fpga/build/route_optimization'
files={Path(__file__).resolve(),S/'refresh_handoff_0240.py'}

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def small_files(folder,recursive=False):
    for p in (folder.rglob('*') if recursive else folder.iterdir()):
        if p.is_file() and p.suffix.lower() in {'.json','.jsonl','.log','.py','.tcl','.v','.sv','.vh','.fdc','.pds','.csv','.hex','.md','.idf','.gitkeep'}:
            files.add(p)

def native_archive(folder,builds):
    archive=folder/'native_checkpoints_0243.zip';members={}
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for build in builds:
            for p in sorted(build.rglob('*')):
                if p.is_file() and (p.suffix.lower() in {'.adf','.vm','.snr','.dmr','.prr','.rtr','.prt','.netlist','.pcf'} or 'CongestionNetInfo' in p.name):
                    name=p.relative_to(folder).as_posix();z.write(p,name)
                    members[name]=dict(bytes=p.stat().st_size,sha256=sha(p))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
    manifest=folder/'native_checkpoints_0243_manifest.json'
    manifest.write_text(json.dumps(dict(archive_sha256=sha(archive),members=members),indent=2))
    files.update([archive,manifest])

dma=REGION/'dma_stats_only_20261020_013741_777089'
case=dma/'owner_unit_probe_20261020_013831_335662/regional_route_20261020_020455_952987'
assert json.loads((case/'result.json').read_text())['jobs'][0]['supervision']['status']=='STALLED'
small_files(case,True);native_archive(case,[case/'candidate'])
files.add(dma/'terminal_review_20261020.json')
model=ROOT/'fpga/build/full_integration_20261013/verilator_20261020_020619_078621'
assert json.loads((model/'result.json').read_text())['passed']
small_files(model);small_files(model/'source',True)
for name in ['snapshot_datagrams.bin','snapshot_descriptors.bin','CMakeLists.txt','build_anchor.cpp']:
    files.add(model/name)
host=ROOT/'host/reports/fpga_rgb_vectors_20261020_022902_768761.json'
files.add(host);small_files(host.with_name(host.stem+'_companions'),True)
writer=REGION/'writer_span_product_20261020_022443_046453'
small_files(writer,True)
regression=ROOT/'fpga/build/full_integration_20261013/sim_20261020_022819_172013'
assert json.loads((regression/'result.json').read_text())['passed']
small_files(regression,True)
screens=[REGION/'pool_local_tokens_20261020_014909_011108/pool_unit_screen_20261020_022717_960101',
         REGION/'snapshot_local_capture_20261020_015904_151226/unit_screen_20261020_022959_667704',
         REGION/'writer_candidate_screen_20261020_023245_102710/unit_screen']
for screen in screens:
    assert json.loads((screen/'result.json').read_text())['passed']
    small_files(screen)
    for label in ['baseline','candidate']:
        small_files(screen/label)
    native_archive(screen,[screen/'baseline',screen/'candidate'])
    # Writer's screen parent is a separate proof-bound diagnostic source copy.
    if screen.parent.name.startswith('writer_candidate_screen_'):
        small_files(screen.parent);small_files(screen.parent/'source',True)
scripts=['prepare_writer_span_product.py','verify_writer_span_math.py','probe_writer_bram_mapping.py',
         'probe_regional_route.py','regional_scan_wrapper.py','test_regional_scan_wrapper.py']
for name in scripts:files.add(ROOT/'fpga/scripts'/name)
validation=S/'regional_driver_extension_validation_20261020.json'
validation.write_text(json.dumps(dict(wrapper_tests_passed=3,actual_iverilog_reset_and_scan_tests=True,
    source_sha256={n:sha(ROOT/'fpga/scripts'/n) for n in scripts},
    pool_frontend_native_passed=True,whole_design_route_allowed=False),indent=2))
files.add(validation)
for name in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md','regional_verification_plan_20261019.md','control_locality_review_20261020.md']:
    files.add(ROOT/'fpga/reports'/name)
entries={p.relative_to(ROOT).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(files)}
manifest=S/'checkpoint_0243_manifest.json';manifest.write_text(json.dumps(dict(files=entries),indent=2))
(S/'checkpoint_0243_scope.txt').write_text('\n'.join(entries)+'\n'+manifest.relative_to(ROOT).as_posix()+'\n')
print('FROZEN',len(entries),sum(v['bytes'] for v in entries.values()))

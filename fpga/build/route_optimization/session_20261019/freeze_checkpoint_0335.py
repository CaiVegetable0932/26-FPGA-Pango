"""Archive completed regional databases and immutable experimental proofs only."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[4]
S=Path(__file__).resolve().parent
R=ROOT/'fpga/build/route_optimization'
files={Path(__file__).resolve(),S/'update_status_0335.py',S/'control_writer_terminal_review_0323.json'}
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def small(folder,recursive=False):
    for p in (folder.rglob('*') if recursive else folder.iterdir()):
        if p.is_file() and p.suffix.lower() in {'.json','.jsonl','.log','.py','.tcl','.v','.sv','.vh','.fdc','.pds','.csv','.hex','.md','.idf'}:
            files.add(p)
def archive(folder,builds):
    target=folder/'native_checkpoints_0335.zip';members={}
    assert not target.exists(), 'Never overwrite a frozen archive'
    with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for build in builds:
            for p in sorted(build.rglob('*')):
                if p.is_file() and (p.suffix.lower() in {'.adf','.vm','.snr','.dmr','.prr','.rtr','.prt','.netlist','.pcf'} or 'CongestionNetInfo' in p.name):
                    name=p.relative_to(folder).as_posix();z.write(p,name)
                    members[name]=dict(bytes=p.stat().st_size,sha256=sha(p))
    with zipfile.ZipFile(target) as z:
        assert z.testzip() is None
        assert all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
    manifest=folder/'native_checkpoints_0335_manifest.json'
    manifest.write_text(json.dumps(dict(archive_sha256=sha(target),members=members),indent=2))
    files.update([target,manifest])
# These runs are all terminal. The decongestion=2 pool run and full-frame
# simulation are deliberately excluded while their producers remain active.
cases=[
 R/'pool_local_tokens_20261020_014909_011108/pool_unit_screen_20261020_022717_960101/regional_route_20261020_023832_501786',
 R/'snapshot_local_capture_20261020_015904_151226/unit_screen_20261020_022959_667704/regional_route_20261020_025528_002166',
 R/'writer_candidate_screen_20261020_023245_102710/unit_screen/regional_route_20261020_030005_452542',
 R/'pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387/regional_route_20261020_030951_250468',
 R/'writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_032713_550985']
for case in cases:
    d=json.loads((case/'result.json').read_text());assert d['completed']
    small(case,True);archive(case,[case/j['label'] for j in d['jobs']])
for name in ['pool_chunk16_20261020_025740_906990','writer_span_pipeline_20261020_031048_641108','proc150_write_cdc_20261020_031859_818696']:
    folder=R/name
    # Explicitly skip native subdirectories, which may contain an active run.
    small(folder)
    for child in folder.iterdir():
        if child.is_dir() and not child.name.startswith('pool_unit_screen_'):small(child,True)
pool=R/'pool_chunk16_20261020_025740_906990/pool_unit_screen_20261020_030600_250387'
writer=R/'writer_candidate_screen_20261020_032507_179978/unit_screen'
for screen in [pool,writer]:
    small(screen)
    for label in ['baseline','candidate']:small(screen/label)
    archive(screen,[screen/'baseline',screen/'candidate'])
small(writer.parent);small(writer.parent/'source',True)
for name in ['sim_20261020_030050_966823','sim_20261020_031100_679289']:
    folder=ROOT/'fpga/build/full_integration_20261013'/name
    assert json.loads((folder/'result.json').read_text())['passed'];small(folder,True)
for name in ['prepare_pool_chunk_counters.py','verify_pool_local_tokens.py','probe_pool_local_mapping.py','prepare_writer_span_pipeline.py','verify_writer_span_pipeline.py','probe_writer_bram_mapping.py','probe_regional_route.py','verify_proc150_write_cdc.py']:
    files.add(ROOT/'fpga/scripts'/name)
files.add(ROOT/'fpga/sim/tb_writer_admission_pipeline.sv')
small(ROOT/'fpga/experiments/proc150',True)
for name in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md','regional_verification_plan_20261019.md','control_locality_review_20261020.md']:
    files.add(ROOT/'fpga/reports'/name)
entries={p.relative_to(ROOT).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(files)}
manifest=S/'checkpoint_0335_manifest.json';manifest.write_text(json.dumps(dict(files=entries),indent=2))
(S/'checkpoint_0335_scope.txt').write_text('\n'.join(entries)+'\n'+manifest.relative_to(ROOT).as_posix()+'\n')
print('FROZEN',len(entries),sum(v['bytes'] for v in entries.values()))

"""Freeze the first timing-clean DMA route and snapshot functional proofs."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[4]
S=Path(__file__).resolve().parent
REGION=ROOT/'fpga/build/route_optimization'
CASE=REGION/'dma_stats_only_20261020_013741_777089/owner_unit_probe_20261020_013831_335662/regional_route_20261020_015127_322351'
SNAP=REGION/'snapshot_local_capture_20261020_015904_151226'
files={Path(__file__).resolve(),S/'dma_stats_seed11_review_20261020.json'}
def sha(path):return hashlib.sha256(path.read_bytes()).hexdigest()
job=json.loads((CASE/'result.json').read_text())['jobs'][0]
assert all(job[k] for k in ['completed','all_internal_constraints_met','inputs_intact','fixed_pin_map_verified'])
for p in CASE.rglob('*'):
    if p.is_file() and p.suffix.lower() in {'.json','.jsonl','.log','.py','.tcl','.v','.sv','.fdc','.pds','.csv'}:
        files.add(p)
archive=CASE/'native_checkpoints.zip';members={}
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
    for p in sorted((CASE/'candidate').rglob('*')):
        if p.is_file() and (p.suffix.lower() in {'.adf','.vm','.snr','.dmr','.prr','.rtr','.prt','.netlist','.pcf'} or 'CongestionNetInfo' in p.name):
            name=p.relative_to(CASE).as_posix();z.write(p,name)
            members[name]=dict(bytes=p.stat().st_size,sha256=sha(p))
with zipfile.ZipFile(archive) as z:
    assert z.testzip() is None
    assert all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
manifest=CASE/'native_checkpoints_manifest.json'
manifest.write_text(json.dumps(dict(archive_sha256=sha(archive),members=members,terminal_status='COMPLETED_TIMING_CLEAN'),indent=2))
files.update([archive,manifest])
for p in SNAP.rglob('*'):
    if p.is_file() and p.suffix.lower() not in {'.vvp','.exe','.pyc','.o'}:files.add(p)
for name in ['sim_20261020_020307_635881','sim_20261020_020506_144595']:
    folder=ROOT/'fpga/build/full_integration_20261013'/name
    assert json.loads((folder/'result.json').read_text())['passed']
    for p in folder.rglob('*'):
        if p.is_file() and p.suffix.lower() in {'.v','.sv','.vh','.hex','.json','.py','.log','.csv'}:files.add(p)
for name in ['prepare_snapshot_local_capture.py','verify_snapshot_local_capture.py','probe_snapshot_capture_mapping.py']:
    files.add(ROOT/'fpga/scripts'/name)
for name in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md','control_locality_review_20261020.md']:
    files.add(ROOT/'fpga/reports'/name)
files.add(REGION/'dma_stats_only_20261020_013741_777089/finalist_selection_20261020.json')
entries={p.relative_to(ROOT).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(files)}
manifest=S/'checkpoint_0210_manifest.json';manifest.write_text(json.dumps(dict(files=entries),indent=2))
(S/'checkpoint_0210_scope.txt').write_text('\n'.join(entries)+'\n'+manifest.relative_to(ROOT).as_posix()+'\n')
print('FROZEN',len(entries),sum(v['bytes'] for v in entries.values()))

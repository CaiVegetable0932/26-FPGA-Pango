"""Freeze terminal DMA SYN, pool proofs and the hourly update only."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT=Path(__file__).resolve().parents[4]
S=Path(__file__).resolve().parent
REGION=ROOT/'fpga/build/route_optimization'
POOL=REGION/'pool_local_tokens_20261020_014909_011108'
DMA=REGION/'dma_stats_only_20261020_013741_777089/owner_unit_probe_20261020_013831_335662'
REGRESSION=ROOT/'fpga/build/full_integration_20261013/sim_20261020_015148_979126'

def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()

files={Path(__file__).resolve(),S/'hourly_0148.py'}
for name in ['prepare_pool_local_tokens.py','verify_pool_local_tokens.py','probe_pool_local_mapping.py']:
    files.add(ROOT/'fpga/scripts'/name)
for path in POOL.rglob('*'):
    if path.is_file() and path.suffix.lower() not in {'.vvp','.exe','.pyc','.o'}:
        files.add(path)
for path in REGRESSION.rglob('*'):
    if path.is_file() and path.suffix.lower() in {'.v','.sv','.vh','.hex','.json','.py','.log','.csv'}:
        files.add(path)
assert json.loads((DMA/'result.json').read_text())['passed']
# Never include the still-active regional route subdirectory.
for label in ['baseline','candidate']:
    build=DMA/label
    for path in build.iterdir():
        if path.is_file() and path.suffix.lower() in {'.v','.sv','.fdc','.tcl','.py','.json','.jsonl','.log','.csv','.pds'}:
            files.add(path)
    archive=DMA/(label+'_native_checkpoints.zip')
    members={}
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for path in build.rglob('*'):
            if path.is_file() and path.suffix.lower() in {'.adf','.vm','.snr','.netlist'}:
                name=path.relative_to(DMA).as_posix()
                z.write(path,name)
                members[name]=dict(bytes=path.stat().st_size,sha256=sha(path))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
    manifest=DMA/(label+'_native_checkpoints_manifest.json')
    manifest.write_text(json.dumps(dict(archive_sha256=sha(archive),members=members),indent=2))
    files.update([archive,manifest])
for path in DMA.iterdir():
    if path.is_file() and path.suffix.lower() in {'.json','.py'}:
        files.add(path)
for name in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md']:
    files.add(ROOT/'fpga/reports'/name)
entries={p.relative_to(ROOT).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(files)}
manifest=S/'checkpoint_0156_manifest.json'
manifest.write_text(json.dumps(dict(files=entries),indent=2))
(S/'checkpoint_0156_scope.txt').write_text('\n'.join(entries)+'\n'+manifest.relative_to(ROOT).as_posix()+'\n')
print('FROZEN',len(entries),sum(v['bytes'] for v in entries.values()))

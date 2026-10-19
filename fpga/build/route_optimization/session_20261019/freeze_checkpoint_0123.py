"""Freeze the two terminal DMA timeouts and supplemental physical constraints."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[4]
SESSION = Path(__file__).resolve().parent
REGION = ROOT/'fpga/build/route_optimization'
files = {Path(__file__).resolve(),SESSION/'dma_round3_first_budget_review.json'}


def sha(data):
    return hashlib.sha256(data).hexdigest()


dma=REGION/'dma_local_cursor_20261019_234450_385383/owner_unit_probe_20261019_235108_893996'
smoke=REGION/'unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261020_012009_332864'
cases=((dma/'regional_route_20261020_003911_499310','baseline','TIMEOUT'),
       (dma/'regional_route_20261020_005929_844858','candidate','TIMEOUT'),
       (smoke,'baseline','COMPLETED'))
for folder,label,expected_status in cases:
    result = json.loads((folder/'result.json').read_text())
    assert result['finished_at'] and result['jobs'][0]['supervision']['status']==expected_status
    build = folder/label
    for path in [*folder.iterdir(),*build.iterdir()]:
        if path.is_file() and path.suffix.lower() in {'.json','.jsonl','.log','.py','.tcl',
                '.v','.sv','.fdc','.pds','.csv'}:
            files.add(path)
    archive = folder/'native_checkpoints.zip'
    members = {}
    with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
        for path in sorted(build.rglob('*')):
            if path.is_file() and (path.suffix.lower() in {'.adf','.vm','.snr','.dmr',
                    '.prr','.rtr','.prt','.netlist','.pcf'} or 'CongestionNetInfo' in path.name):
                data=path.read_bytes();name=path.relative_to(folder).as_posix()
                z.writestr(name,data);members[name]=dict(bytes=len(data),sha256=sha(data))
    with zipfile.ZipFile(archive) as z:
        assert z.testzip() is None
        assert all(sha(z.read(n))==v['sha256'] for n,v in members.items())
    manifest=folder/'native_checkpoints_manifest.json'
    manifest.write_text(json.dumps(dict(archive_sha256=sha(archive.read_bytes()),
        terminal_status=expected_status,in_memory_route_iteration_not_saved=expected_status=='TIMEOUT',members=members),indent=2))
    files.update((archive,manifest))

# Add the tiny PCF dependency as a separate supplement; never rewrite old ZIPs.
pcfs={}
for result_path in REGION.glob('**/regional_route_*/result.json'):
    result=json.loads(result_path.read_text())
    if not result.get('finished_at'):
        continue
    for path in result_path.parent.glob('*/device_map/*.pcf'):
        data=path.read_bytes();mapped=path.with_name('regional_wrapper_map.adf')
        assert mapped.is_file()
        files.add(path)
        pcfs[path.relative_to(ROOT).as_posix()]=dict(bytes=len(data),sha256=sha(data),
            mapped_db_sha256=sha(mapped.read_bytes()),original_terminal_result=str(result_path))
supplement=SESSION/'regional_physical_pcf_supplement_20261020.json'
supplement.write_text(json.dumps(dict(files=pcfs,historical_archives_unchanged=True),indent=2))
files.add(supplement)
entries={p.relative_to(ROOT).as_posix():dict(bytes=p.stat().st_size,
    sha256=sha(p.read_bytes())) for p in sorted(files)}
manifest=SESSION/'regional_checkpoint_20261020_0123_manifest.json'
manifest.write_text(json.dumps(dict(files=entries),indent=2))
(SESSION/'regional_checkpoint_20261020_0123_scope.txt').write_text(
    '\n'.join(entries)+'\n'+manifest.relative_to(ROOT).as_posix()+'\n')
print('Frozen',len(files),'files;',len(pcfs),'PCFs;',sum(v['bytes'] for v in entries.values()),'bytes')

"""Freeze only explicitly selected, terminal regional evidence for this checkpoint."""
import hashlib
import json
from pathlib import Path
import zipfile

ROOT = Path(__file__).resolve().parents[4]
SESSION = Path(__file__).resolve().parent
REGION = ROOT / 'fpga/build/route_optimization'
files = set()


def digest(data):
    """Use byte hashes consistent with the proof manifests and Git attributes."""
    return hashlib.sha256(data).hexdigest()


def select_flat(folder):
    """Keep logs, sources, reports and policies; omit executable/cache artifacts."""
    for path in folder.iterdir():
        if path.is_file() and path.suffix.lower() in {
            '.json', '.jsonl', '.py', '.v', '.sv', '.vh', '.tcl', '.fdc',
            '.log', '.txt', '.pds', '.csv', '.srr', '.vm', '.rtr', '.prr'}:
            files.add(path)


def physical(folder):
    """Archive reproducible native checkpoints only after both jobs terminated."""
    result = json.loads((folder/'result.json').read_text())
    assert result.get('finished_at'), folder
    for job in result['jobs']:
        assert job.get('supervised', job.get('native', {})).get('status') != 'RUNNING'
    members = {}
    archive = folder/'native_checkpoints.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as out:
        for label in ('baseline', 'candidate'):
            build = folder/label
            if not build.exists():
                continue
            select_flat(build)
            for path in sorted(build.rglob('*')):
                if path.is_file() and (path.suffix.lower() in {
                    '.adf', '.vm', '.snr', '.dmr', '.prr', '.rtr', '.prt', '.netlist'}
                    or 'CongestionNetInfo' in path.name):
                    name = path.relative_to(folder).as_posix()
                    data = path.read_bytes()
                    out.writestr(name, data)
                    members[name] = {'bytes': len(data), 'sha256': digest(data)}
    with zipfile.ZipFile(archive) as checked:
        assert checked.testzip() is None
        for name, metadata in members.items():
            assert digest(checked.read(name)) == metadata['sha256']
    (folder/'native_checkpoints_manifest.json').write_text(json.dumps({
        'archive_sha256': digest(archive.read_bytes()), 'members': members}, indent=2))
    files.add(archive)
    select_flat(folder)


# Each source/proof folder is frozen; no active synthesis subtree is traversed.
for name in ('dma_local_cursor_20261019_234450_385383',
             'dma_cursor_stats_20261019_234450_843063'):
    candidate = REGION/name
    select_flat(candidate)
    files.update(p for p in (candidate/'source').rglob('*') if p.is_file())
    for proof in list(candidate.glob('differential_*'))+list(candidate.glob('generic_parameters_*')):
        assert json.loads((proof/'result.json').read_text())['passed']
        select_flat(proof)

physical(REGION/'dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717')
physical(REGION/'unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/regional_route_20261019_234111_668461')

# Include the native screens that establish each physical input transformation.
for folder in (
    REGION/'dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515',
    REGION/'unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009'):
    assert json.loads((folder/'result.json').read_text())['passed']
    select_flat(folder)
    for label in ('baseline', 'candidate'):
        select_flat(folder/label)
        for path in (folder/label).rglob('*'):
            if path.is_file() and path.suffix.lower() in {'.srr', '.vm'}:
                files.add(path)

for name in ('native_checkpoint_integrity_20261019.json',
             'regional_checkpoint_20261019_2306_git_verification.json'):
    files.add(SESSION/name)
files.add(Path(__file__).resolve())
manifest = {p.relative_to(ROOT).as_posix(): {'bytes': p.stat().st_size,
            'sha256': digest(p.read_bytes())} for p in sorted(files)}
scope = SESSION/'regional_checkpoint_20261019_2355_scope.txt'
proof = SESSION/'regional_checkpoint_20261019_2355_manifest.json'
proof.write_text(json.dumps({'files': manifest}, indent=2))
scope.write_text('\n'.join(sorted(manifest))+'\n'+proof.relative_to(ROOT).as_posix()+'\n')
print('Frozen', len(files), 'files;', sum(m['bytes'] for m in manifest.values()), 'bytes')

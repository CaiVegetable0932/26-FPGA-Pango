"""Freeze terminal finite-seed/writer evidence without touching active jobs."""
from pathlib import Path
import hashlib
import json
import zipfile

ROOT = Path(__file__).resolve().parents[4]
SESSION = Path(__file__).resolve().parent
REGION = ROOT/'fpga/build/route_optimization'
files = {Path(__file__).resolve()}


def sha(data):
    """Keep original bytes in the manifest, ZIP and repository."""
    return hashlib.sha256(data).hexdigest()


def flat(folder):
    """Preserve human-readable evidence and immutable sources, not caches."""
    for p in folder.iterdir():
        if p.is_file() and p.suffix.lower() in {'.json', '.jsonl', '.log', '.txt',
                '.py', '.v', '.sv', '.vh', '.tcl', '.fdc', '.pds', '.csv'}:
            files.add(p)


def archive(folder):
    """Only terminal physical pairs qualify for a native checkpoint archive."""
    result = json.loads((folder/'result.json').read_text())
    assert result['completed'] and result['comparison_complete'], folder
    assert all(j['completed'] for j in result['jobs']), folder
    flat(folder)
    members = {}
    dest = folder/'native_checkpoints.zip'
    with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for label in ('baseline', 'candidate'):
            build = folder/label
            flat(build)
            for p in sorted(build.rglob('*')):
                if p.is_file() and (p.suffix.lower() in {'.adf', '.vm', '.snr',
                        '.dmr', '.prr', '.rtr', '.prt', '.netlist'} or
                        'CongestionNetInfo' in p.name):
                    data = p.read_bytes()
                    name = p.relative_to(folder).as_posix()
                    z.writestr(name, data)
                    members[name] = dict(bytes=len(data), sha256=sha(data))
    with zipfile.ZipFile(dest) as z:
        assert z.testzip() is None
        assert all(sha(z.read(n)) == m['sha256'] for n, m in members.items())
    manifest = folder/'native_checkpoints_manifest.json'
    manifest.write_text(json.dumps(dict(archive_sha256=sha(dest.read_bytes()), members=members), indent=2))
    files.update((dest, manifest))


reader = REGION/'unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009'
for name in ('regional_route_20261020_000430_019194', 'regional_route_20261020_000753_001887'):
    archive(reader/name)
files.add(reader/'three_seed_summary.json')

# Preserve the syntax-error fixture as failed evidence, separate from RTL failures.
for name in ('writer_bram_screen_20261020_001142_389407',
             'writer_bram_screen_20261020_001808_201768',
             'writer_bram_screen_20261020_001911_724767'):
    candidate = REGION/name
    flat(candidate)
    files.update(p for p in (candidate/'source').rglob('*') if p.is_file())
    screen = candidate/'unit_screen'
    result = json.loads((screen/'result.json').read_text())
    assert all(j['supervision']['status'] != 'RUNNING' for j in result['jobs'])
    flat(screen)
    for label in ('baseline', 'candidate'):
        build = screen/label
        if build.exists():
            flat(build)
            for p in build.rglob('*'):
                if p.is_file() and p.suffix.lower() in {'.snr', '.vm'}:
                    files.add(p)
    for physical in screen.glob('regional_route_*'):
        archive(physical)

# These integration fixtures finished; the active full-frame model is excluded.
regression = ROOT/'fpga/build/full_integration_20261013/sim_20261020_001153_047628'
assert json.loads((regression/'result.json').read_text())['passed']
flat(regression)
files.update(p for p in (regression/'source').rglob('*') if p.is_file())
files.update(p for p in regression.iterdir() if p.suffix in {'.rgb', '.bin'})
finalist = SESSION/'unpack_finalist'
flat(finalist)
files.update(p for p in (finalist/'source').rglob('*') if p.is_file())
compile_check = SESSION/'writer_context_compile_check'
flat(compile_check)

entries = {p.relative_to(ROOT).as_posix(): dict(bytes=p.stat().st_size,
            sha256=sha(p.read_bytes())) for p in sorted(files)}
manifest = SESSION/'regional_checkpoint_20261020_0026_manifest.json'
manifest.write_text(json.dumps(dict(files=entries), indent=2))
(SESSION/'regional_checkpoint_20261020_0026_scope.txt').write_text(
    '\n'.join(sorted(entries))+'\n'+manifest.relative_to(ROOT).as_posix()+'\n')
print('Frozen', len(files), 'files;', sum(x['bytes'] for x in entries.values()), 'bytes')

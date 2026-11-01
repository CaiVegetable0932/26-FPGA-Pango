"""Package the verified GH2 MAP for a separate computer, without native work.

Inputs and original proof files keep their bytes. An explicit provenance index
maps historical absolute proof references to delivered relative paths. The
portable audit, ZIP CRC and every payload SHA must pass before publication.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys
import zipfile

FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/gh2_integration_20261101'
PREP = FPGA / 'build/gh2_release_preparation_20261101'
STAGE = PREP / 'package'
REL = Path('fpga/release/gray_GH2_20261101')
ZIP = FPGA / 'release/packages/gray_GH2_portable_20261101.zip'


def sha(path):
    """Hash exact file bytes, including original Windows line endings."""
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def read(path):
    return json.loads(Path(path).read_text(encoding='utf-8-sig'))


def save(path, value):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value, indent=2, ensure_ascii=False)+'\n', encoding='utf-8')


def copy_checked(source, destination):
    """Never accept an input that changed while packaging."""
    source, destination = Path(source), Path(destination)
    before = sha(source)
    destination.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source, destination)
    if sha(source) != before or sha(destination) != before:
        raise ValueError('Copy drift: '+str(source))


def package():
    """Consume a new output directory; no prepare/run/native tool is called."""
    from portable_gh2 import INPUT_FILES, SCRIPT_FILES, RUN_OPTIONS
    final_path = ROOT/'final_review_20261101/final_review.json'
    final = read(final_path)
    if not final['passed'] or final['status'] != 'GH2_FUNCTIONAL_SYN_MAP_AND_NETLIST_REVIEW_COMPLETE_PRE_ROUTE':
        raise ValueError('Independent GH2 final review required')
    if any(final[k] for k in ('physical_signoff','routing_started','promoted','bitstream_generated')):
        raise ValueError('Unexpected physical activity in selected candidate')
    if STAGE.exists() or ZIP.exists():
        raise ValueError('Package already exists: inspect it, never overwrite')
    mapping = Path(final['mapping']); sources = read(mapping/'sources.json')
    if len(sources) != 327 or sha(mapping/'sources.json') != final['candidate_sha256']:
        raise ValueError('Wrong source identity')
    functional_path = ROOT/'functional_review.json'; functional = read(functional_path)
    # Recheck the complete final audit closure and its directly bound functional
    # evidence. Historical absolute paths remain provenance, not target commands.
    bindings = dict(final['evidence_sha256'])
    bindings.update(functional['bound_evidence'])
    for path, digest in bindings.items():
        if sha(path) != digest:
            raise ValueError('Reviewed evidence drift: '+path)
    for name, digest in sources.items():
        if sha(mapping/'source'/name) != digest:
            raise ValueError('Frozen source drift: '+name)
    STAGE.mkdir(parents=True, exist_ok=False)
    inputs, evidence = STAGE/REL/'inputs', STAGE/REL/'evidence'
    for name in INPUT_FILES:
        copy_checked(mapping/name, inputs/name)
    # Ship the actual board VM as additional audit evidence even though routing
    # consumes the mapped ADF. No PLC or old routed database is included.
    if 'synthesize/pango_video_system_syn.vm' not in INPUT_FILES:
        copy_checked(mapping/'synthesize/pango_video_system_syn.vm', inputs/'synthesize/pango_video_system_syn.vm')
    for name in sources:
        copy_checked(mapping/'source'/name, inputs/'source'/name)
    for name in SCRIPT_FILES:
        copy_checked(FPGA/'scripts'/name, STAGE/'fpga/scripts'/name)
    proofs = {}
    for key, path in (('final_review', final_path),('functional_review', functional_path),
                      ('postsyn_review', ROOT/'post_syn_review_20261101/review.json')):
        destination = evidence/(key+'.json')
        copy_checked(path, destination)
        proofs[key] = destination.relative_to(STAGE).as_posix()
        bindings[str(path)] = sha(path)
    # Deduplicate identical source/DB/script bytes while retaining every original
    # reference in the index. The new portable manifest binds both index and data.
    by_hash = {sha(p):p.relative_to(STAGE).as_posix() for p in STAGE.rglob('*') if p.is_file()}
    provenance = {}
    for original, digest in sorted(bindings.items()):
        if digest not in by_hash:
            destination = evidence/'objects'/digest/Path(original).name
            copy_checked(original, destination)
            by_hash[digest] = destination.relative_to(STAGE).as_posix()
        provenance[original] = dict(path=by_hash[digest], sha256=digest)
    save(evidence/'original_path_index.json', provenance)
    report = FPGA/'reports/GH2外部计算机布线与监控交接_20261101.md'
    copy_checked(report, STAGE/REL/'README_交接.md')
    for name in ('GH2外部计算机布线与监控交接_20261101.md',
                 'GH2组合版2022工具链验证完成_20261101.md',
                 'PG2L100H_PDS2025_TMDS兼容性定位_20261101.md'):
        copy_checked(FPGA/'reports'/name, STAGE/'fpga/reports'/name)
    manifest = dict(schema=1, kind='GH2_MAP_FRESH_PLACE_ROUTE',release_id='gray_GH2_20261101',
        inputs=(REL/'inputs').as_posix(),original_build=mapping.as_posix(),
        device=dict(family='Logos2',device='PG2L100H',speedgrade='-6',package='FBG676',
                    pds_version='2022.2-SP6.4 build 146967'),
        source_count=327,source_manifest_sha256=sha(inputs/'sources.json'),
        mapped_resources=final['resources'],proofs=proofs,run_options=RUN_OPTIONS,
        provenance_index=(REL/'evidence/original_path_index.json').as_posix(),
        placement_reused=False,partial_route_resumed=False,
        files={p.relative_to(STAGE).as_posix():sha(p) for p in sorted(STAGE.rglob('*')) if p.is_file()})
    save(STAGE/REL/'manifest.json', manifest)
    result = subprocess.run([sys.executable,'-B',str(STAGE/'fpga/scripts/portable_gh2.py'),'--audit'],
        cwd=STAGE,capture_output=True,text=True,encoding='utf-8',errors='replace',timeout=120)
    (PREP/'package_audit.log').write_text(result.stdout+result.stderr,encoding='utf-8')
    if result.returncode:
        raise ValueError('Delivered portable audit failed; retain package and inspect package_audit.log')
    ZIP.parent.mkdir(parents=True,exist_ok=True)
    payload=[*manifest['files'],(REL/'manifest.json').as_posix()]
    with zipfile.ZipFile(ZIP,'x',zipfile.ZIP_DEFLATED,compresslevel=6) as archive:
        for name in payload:
            archive.write(STAGE/name,name)
    with zipfile.ZipFile(ZIP) as archive:
        if archive.testzip() is not None:
            raise ValueError('ZIP CRC failed')
        for name in payload:
            with archive.open(name) as stream:
                if hashlib.file_digest(stream,'sha256').hexdigest() != sha(STAGE/name):
                    raise ValueError('ZIP payload mismatch: '+name)
    digest=sha(ZIP)
    ZIP.with_suffix('.zip.sha256').write_text(digest+'  '+ZIP.name+'\n',encoding='ascii')
    review=dict(passed=True,package_root=str(STAGE),zip=str(ZIP),zip_sha256=digest,
        zip_bytes=ZIP.stat().st_size,manifest_sha256=sha(STAGE/REL/'manifest.json'),
        source_count=327,file_count=len(payload),provenance_entries=len(provenance),
        audit_passed=True,zip_crc_passed=True,all_zip_payload_sha_passed=True,
        pds_started=False,physical_signoff=False,created_at=datetime.now().astimezone().isoformat())
    save(PREP/'release_review.json',review)
    print(json.dumps(review,indent=2,ensure_ascii=False))


if __name__ == '__main__':
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package',action='store_true')
    args=parser.parse_args()
    if not args.package:
        parser.error('Explicit --package required; this operation never starts PDS')
    package()

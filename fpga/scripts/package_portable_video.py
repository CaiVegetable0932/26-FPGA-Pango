"""Freeze the current P12 design and evidence into a relocatable source package.

This is a source/checkpoint handoff, never a bitstream qualification. Read active
builds without changing them and hash stable source/checkpoint files twice.
"""
from datetime import datetime, timezone, timedelta
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import zipfile


REPO = Path(__file__).resolve().parents[2]
FPGA = REPO / 'fpga'
BASE = FPGA / 'build/full_integration_20261013'
P12 = BASE / 'phys_20261017_135035_561224'
MAP = BASE / 'delay_20261016_013746_534606'
MODEL = BASE / 'verilator_20261016_013808_414872'
RELEASE = FPGA / 'release/portable/pango_video_system_P12_20261018'


def sha(path):
    """Stream hashes so native databases need not be loaded into memory."""
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def copy(src, dst, stable=True):
    """Detect edits during a copy; mutable observation logs are snapshots only."""
    before = sha(src)
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(src, dst)
    if stable and (before != sha(dst) or before != sha(src)):
        raise RuntimeError('Input changed during package copy: ' + str(src))


def manifest(root):
    """Bind every delivered payload byte, excluding the manifest itself."""
    files = {p.relative_to(root).as_posix(): {'bytes': p.stat().st_size, 'sha256': sha(p)}
             for p in sorted(root.rglob('*')) if p.is_file() and p.name != 'manifest.json'
             and 'build' not in p.relative_to(root).parts and '__pycache__' not in p.parts}
    value = {'schema': 'pango_portable_source_package.v1',
             'created_at': datetime.now(timezone(timedelta(hours=8))).isoformat(),
             'candidate': 'P12', 'top': 'pango_video_system',
             'tool': 'PDS 2022.2-SP6.4 build 146967',
             'bitstream_included': False, 'hardware_verified': False, 'files': files}
    (root / 'manifest.json').write_text(json.dumps(value, ensure_ascii=False, indent=2), encoding='utf-8')
    return value


def archive(root):
    """Verify zip CRC and every extracted payload hash before publication."""
    value = manifest(root)
    dest = root.with_suffix('.zip')
    with zipfile.ZipFile(dest, 'w', zipfile.ZIP_DEFLATED, compresslevel=6) as z:
        for name in [*value['files'], 'manifest.json']:
            z.write(root / name, root.name + '/' + name)
    with zipfile.ZipFile(dest) as z:
        if z.testzip() is not None:
            raise RuntimeError('ZIP CRC failed')
        for name, meta in value['files'].items():
            if hashlib.sha256(z.read(root.name + '/' + name)).hexdigest() != meta['sha256']:
                raise RuntimeError('ZIP payload mismatch: ' + name)
    dest.with_suffix('.zip.sha256').write_text(sha(dest) + '  ' + dest.name + '\n', encoding='ascii')
    print(json.dumps({'zip': str(dest), 'bytes': dest.stat().st_size,
                      'files': len(value['files']) + 1, 'sha256': sha(dest)}, indent=2))


def main():
    """Package the source-bound active candidate, not unrelated working RTL."""
    RELEASE.mkdir(parents=True, exist_ok=False)
    hashes = json.loads((P12 / 'sources.json').read_text())
    for name, expected in hashes.items():
        if sha(P12 / 'source' / name) != expected:
            raise RuntimeError('Frozen P12 source mismatch: ' + name)
        copy(P12 / 'source' / name, RELEASE / 'fpga/source' / name)
    copy(P12 / 'sources.json', RELEASE / 'fpga/project/sources.json')
    original = (P12 / 'flow.tcl').read_text(encoding='utf-8')
    (RELEASE / 'fpga/project/flow.template.tcl').write_text(original.replace(P12.as_posix(), '@RUN@'), encoding='utf-8')
    copy(P12 / 'flow.pds', RELEASE / 'fpga/evidence/original_P12.pds')
    for name in ['pango_video_system_map.adf', 'pango_video_system.pcf', 'pango_video_system.dmr']:
        if sha(P12 / 'device_map' / name) != sha(MAP / 'device_map' / name):
            raise RuntimeError('MAP provenance mismatch: ' + name)
        copy(P12 / 'device_map' / name, RELEASE / 'fpga/checkpoints/device_map' / name)
    copy(P12 / 'place_route/pango_video_system_plc.adf', RELEASE / 'fpga/checkpoints/place_route/pango_video_system_plc.adf')
    # Carry the reviewed gate and the native helper's transitive imports.
    # This is package metadata, separate from the frozen historical RTL.
    copy(FPGA / 'config/implementation_readiness.json',
         RELEASE / 'fpga/config/implementation_readiness.json')
    for name in ['portable_video_build.py', 'native_bitgen.py', 'package_portable_video.py',
                 'implementation_readiness.py', 'route_supervisor.py']:
        copy(FPGA / 'scripts' / name, RELEASE / 'fpga/scripts' / name)
    # Retain frozen simulation sources/vectors separately: they are evidence,
    # not the native board source list consumed by the new PDS project.
    for path in MODEL.rglob('*'):
        rel = path.relative_to(MODEL)
        if path.is_file() and (rel.parts[0] == 'source' or len(rel.parts) == 1):
            copy(path, RELEASE / 'fpga/evidence/model' / rel)
    for name in ['result.json', 'sources.json', 'flow.tcl', 'console.log']:
        if (MAP / name).is_file():
            copy(MAP / name, RELEASE / 'fpga/evidence/map' / name)
    copy(REPO / 'host/reports/fpga_rgb_vectors_20261016_020054_956588.json',
         RELEASE / 'fpga/evidence/host_decode.json')
    for name in ['sim_20261016_013114_586359',
                 'uart_deadline_repair_20261016_012302_468792/uart_differential_20261016_012553_986714']:
        for path in (BASE / name).rglob('*'):
            if path.is_file() and path.suffix in ('.json', '.log', '.py', '.sv', '.v'):
                copy(path, RELEASE / 'fpga/evidence/regression' / name / path.relative_to(BASE / name))
    for name in ['full_integration_20261013.md', 'route_campaign_1080p30_20261015.md',
                 'p12_congestion_diagnosis_20261018.md', 'board_validation_20260910.md']:
        copy(FPGA / 'reports' / name, RELEASE / 'fpga/docs/history' / name, stable=False)
    for name in ['PG2L100H_1080p畸变矫正详细设计方案.md', 'OV5640_RAW8千兆网与HDMI双路回传方案.md',
                 'MCU_POSE_V2接口实现补充.md']:
        copy(REPO / 'output' / name, RELEASE / 'fpga/docs/design' / name)
    copy(BASE / 'device_pnr_help_20261015_222737_481762/help.log', RELEASE / 'fpga/docs/installed_pnr_help.log')
    copy(P12 / 'resume_20261017_135037_064053/place_route.log', RELEASE / 'fpga/evidence/route_observation.log', stable=False)
    copy(P12 / 'resume_20261017_135037_064053/place_route.tcl', RELEASE / 'fpga/evidence/original_route.tcl')
    copy(BASE / 'active_work_state.json', RELEASE / 'fpga/evidence/active_work_state_observed.json', stable=False)
    # Copy only target-matched board references; never depend on ignored
    # reference/ or copy a local machine's licence/installation into the ZIP.
    board = next((REPO / 'reference').rglob('教程1_盘古MINI系列开发板硬件指导手册_V1.3.pdf'))
    copy(board, RELEASE / 'fpga/docs/reference/board_manual_V1.3.pdf')
    official = Path('E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf')
    copy(official, RELEASE / 'fpga/docs/reference/Pango_Design_Suite_User_Guide.pdf')
    changed = [n for n,h in hashes.items() if (FPGA/n).is_file() and sha(FPGA/n) != h]
    commit = subprocess.run(['git', '-c', 'core.fsmonitor=false', 'rev-parse', 'HEAD'], cwd=REPO,
                            capture_output=True, text=True, check=True).stdout.strip()
    provenance = {'source_build': str(P12), 'mapped_build': str(MAP), 'model_build': str(MODEL),
                  'git_head_context_only': commit, 'version_identity': 'frozen sources.json SHA256, not git HEAD',
                  'working_tree_differs_from_candidate': changed, 'source_files': len(hashes),
                  'references': [{'original': str(p), 'sha256': sha(p), 'modifications': 'none'} for p in (board, official)],
                  'portable_changes': 'New path-independent driver and Tcl root substitution; no RTL/IP/constraint edits',
                  'source_state': 'MAP completed; P12 detailed routing incomplete at capture; no qualified full bitstream'}
    (RELEASE / 'fpga/docs/provenance.json').write_text(json.dumps(provenance, ensure_ascii=False, indent=2), encoding='utf-8')
    manifest(RELEASE)
    print(RELEASE)


if __name__ == '__main__':
    main()

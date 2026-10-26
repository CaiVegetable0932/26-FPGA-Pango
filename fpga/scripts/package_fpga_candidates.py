"""Package audited native PDS SRAM candidates, retaining hardware status.

Only copies successful fresh build artifacts under fpga/release/candidates.
It neither invokes a programmer nor marks unresolved board checks approved.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET

FPGA = Path(__file__).resolve().parents[1]
SCOPES = {
    'pango_video_top': 'IP integration skeleton: DDR address requests idle, PHY held in reset, fixed HDMI symbols; no complete RAW8/ISP/geometry/network pipeline',
    'mini_camera_diag': 'Single CAM1 1280x720 RGB565 diagnostic: camera, DDR frame buffers and HDMI; no RAW8/PRAW or complete 1080p correction system',
}


def digest(path):
    """Hash original bytes; never transform a native image or its mask."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def require(condition, message):
    """Missing or mismatched evidence prevents artifact packaging."""
    if not condition:
        raise ValueError(message)


def main():
    """Check all input candidates before creating an immutable release folder."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('runs', type=Path, nargs='+')
    args = parser.parse_args()
    entries = []
    for supplied in args.runs:
        run = supplied.resolve()
        require(run.is_relative_to(FPGA / 'build'), 'Only FPGA build inputs are allowed')
        result = json.loads((run / 'result.json').read_text())
        project = result['project']
        require(project in SCOPES, 'Unknown project scope')
        require(result.get('stage')=='gen_bit_stream' and result.get('candidate_checks_passed'), 'Candidate build did not pass')
        require(result.get('snapshot_intact') and not result.get('errors'), 'Build inputs/errors are not clean')
        require(not result.get('programmed') and not result.get('download_approved'), 'Unexpected hardware status')
        # Re-run the actual Gray/reset/clock/min-max audit against this build,
        # not an earlier similarly named project or previously generated image.
        audited = subprocess.run([sys.executable, str(FPGA / 'scripts/audit_clock_reset.py'), str(run)],
                                 capture_output=True, text=True, timeout=120)
        (run / 'candidate_audit.log').write_text(audited.stdout+audited.stderr, encoding='utf-8')
        require(audited.returncode==0, f'Structural audit failed: {run}')
        audit = json.loads((run / 'clock_reset_audit.json').read_text())
        require(audit['internal_timing_met'], 'Internal timing has not closed')
        require(all(row['wns_ns']>=0 and row['tns_ns']==0 and row['failing_endpoints']==0
                    for row in audit['timing'].values()), 'Incomplete/failing timing summaries')
        # Bind source snapshots to current working RTL/constraints/IDFs.
        # Reports from a different working source are kept in build, not issued.
        source_hashes = json.loads((run / 'source_hashes.json').read_text())
        for relative, sha in source_hashes.items():
            require(digest(run/'source'/relative)==sha, f'Snapshot changed: {relative}')
            require((FPGA/relative).is_file() and digest(FPGA/relative)==sha, f'Working input changed: {relative}')
        for relative in source_hashes:
            if relative.endswith('.idf'):
                ip = ET.parse(run/'source'/relative)
                require(all(ip.findtext('header/'+k)==v for k,v in
                            {'family':'Logos2','device':'PG2L100H','package':'FBG676','speedgrade':'-6'}.items()),
                        f'IP target mismatch: {relative}')
        top = 'Top' if project=='mini_camera_diag' else project
        image = run / f'generate_bitstream/{top}.sbit'
        require(image.is_file() and digest(image)==result['bitstream_sha256'], 'Image hash mismatch')
        bgr = run / f'generate_bitstream/{top}.bgr'
        report = bgr.read_text(errors='replace')
        require('Generating Programming File done.' in report and 'gen_bit_stream -scbv {High Voltage}' in report, 'Native bitstream report incomplete')
        require(image.stat().st_mtime>=(run/f'place_route/{top}_pnr.adf').stat().st_mtime, 'Image predates its routed DB')
        require(str(run.as_posix()) in report, 'Native report refers to another run')
        entries.append(dict(project=project,top=top,run=run,image=image,bgr=bgr,result=result,audit=audit))
    require(len({e['project'] for e in entries})==len(entries), 'Duplicate candidate project')
    destination = FPGA / 'release/candidates' / datetime.now().strftime('%Y%m%d_%H%M%S')
    destination.mkdir(parents=True, exist_ok=False)
    manifest = dict(created_at=datetime.now().astimezone().isoformat(),
                    target={'family':'Logos2','device':'PG2L100H','package':'FBG676','speedgrade':'-6'},
                    pds='2022.2-SP6.4 build146967',format='native PDS .sbit',status='offline_candidates',
                    hardware_tested=False,programmed=False,download_approved=False,external_timing_verified=False,
                    unresolved=['existing over_temp=1 has no clearance evidence','external timing/electrical sign-off pending',
                                'encrypted OSERDES behavioral regression blocked by ModelSim license',
                                'complete frame/DMA recovery and full RAW8/1080p pipeline acceptance pending'],candidates=[])
    checksums = []
    for entry in entries:
        folder = destination / entry['project']
        folder.mkdir()
        files = [entry['image'],entry['bgr'],entry['run']/f"generate_bitstream/{entry['top']}.smsk",
                 entry['run']/'result.json',entry['run']/'clock_reset_audit.json',entry['run']/'source_hashes.json',
                 entry['run']/'original_project.tcl',entry['run']/'flow.tcl']
        for original in files:
            require(original.is_file(), f'Missing candidate artifact: {original}')
            copied = folder / original.name
            shutil.copyfile(original,copied)
            require(digest(copied)==digest(original), 'Candidate copy hash mismatch')
            checksums.append(digest(copied)+'  '+copied.relative_to(destination).as_posix())
        manifest['candidates'].append(dict(project=entry['project'],top=entry['top'],scope=SCOPES[entry['project']],
            bitstream=entry['image'].relative_to(entry['run']).as_posix().replace('generate_bitstream',entry['project']),
            bytes=entry['image'].stat().st_size,sha256=digest(entry['image']),evidence=str(entry['run']),
            resources=entry['audit']['resources'],timing={name:{k:v for k,v in row.items() if k!='rows'}
                for name,row in entry['audit']['timing'].items()}))
    (destination/'manifest.json').write_text(json.dumps(manifest,indent=2)+'\n')
    (destination/'SHA256SUMS.txt').write_text('\n'.join(checksums)+'\n')
    (destination/'README.md').write_text(
        '# PG2L100H 原生候选位流\n\n两套文件已完成各自总体布线、内部时序和原生位流生成；适用于 PDS 的 .sbit 格式。\n\n'
        'pango_video_top 是集成骨架；mini_camera_diag 是单路720p RGB565摄像头/DDR/HDMI诊断。'
        '均不代表完整 RAW8/1080p 矫正及网络系统。具体来源、SHA256和时序见 manifest.json。\n\n'
        '当前未获得硬件下载放行：既有 over_temp 告警及外部接口签核未关闭。没有实际下载或硬件测试。\n',encoding='utf-8')
    print('FPGA_CANDIDATES_PACKAGED '+str(destination))
    print(json.dumps(manifest,ensure_ascii=False))


if __name__=='__main__':
    main()

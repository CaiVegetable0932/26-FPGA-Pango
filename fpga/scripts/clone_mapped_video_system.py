"""Create an isolated physical trial from an immutable, verified MAP checkpoint."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def sha256(path):
    """Bind copied inputs to their exact bytes, including vendor dependencies."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Copy only completed MAP inputs; never reuse another trial's physical results."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--build', type=Path, required=True)
    args = parser.parse_args()
    build_root = Path(__file__).resolve().parents[1] / 'build'
    original = args.build.resolve()
    if not original.is_relative_to(build_root):
        raise ValueError('Input must be an existing FPGA build')
    manifest = json.loads((original / 'sources.json').read_text(encoding='utf-8'))
    if any(sha256(original / 'source' / n) != h for n, h in manifest.items()):
        raise ValueError('Original frozen inputs changed')
    mapped = original / 'device_map/pango_video_system_map.adf'
    pcf = original / 'device_map/pango_video_system.pcf'
    # Native explicit input_db_file plus generated PCF is the installed PDS
    # 2022.2-SP6.4 flow. Copies isolate later mutable place_route/STA/bitgen files.
    inputs = {p.name: sha256(p) for p in (mapped, pcf)}
    target = original.parent / datetime.now().strftime('phys_%Y%m%d_%H%M%S_%f')
    target.mkdir()
    shutil.copytree(original / 'source', target / 'source')
    shutil.copyfile(original / 'sources.json', target / 'sources.json')
    (target / 'device_map').mkdir()
    for source in (mapped, pcf):
        shutil.copyfile(source, target / 'device_map' / source.name)
    # Preserve completed synthesis/constraint evidence from this exact MAP
    # producer for later packaging, without copying mutable physical reports.
    for name in ('synthesize/pango_video_system.snr',
                 'synthesize/pango_video_system_controlsets.txt',
                 'device_map/pango_video_system.dmr',
                 'constraint_check/constraint_check.ccr'):
        if (original / name).is_file():
            (target / name).parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(original / name, target / name)
    # Rebase the copied project registration, preserving constraint and IP order.
    # The source bytes and mapped netlist remain identical; no RTL recompilation.
    for name in ('flow.tcl', 'flow.pds'):
        content = (original / name).read_text(encoding='utf-8')
        content = content.replace(original.as_posix(), target.as_posix())
        content = content.replace(str(original), str(target))
        (target / name).write_text(content, encoding='utf-8')
    intact = all(sha256(target / 'source' / n) == h for n, h in manifest.items())
    checkpoints_intact = all(sha256(target / 'device_map' / n) == h for n, h in inputs.items())
    if not intact or not checkpoints_intact:
        raise RuntimeError('Physical trial input copy failed hash verification')
    evidence = dict(original_build=str(original), build=str(target),
                    source_count=len(manifest), snapshot_intact=intact,
                    checkpoint_sha256=inputs, checkpoints_intact=checkpoints_intact,
                    pds_version='2022.2-SP6.4',
                    official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf',
                    board_routed=False, bitstream_generated=False, hardware_tested=False)
    (target / 'mapped_copy.json').write_text(json.dumps(evidence, indent=2)+'\n', encoding='utf-8')
    shutil.copyfile(Path(__file__), target / 'clone_mapped_video_system.py')
    print(json.dumps(evidence), flush=True)


if __name__ == '__main__':
    main()

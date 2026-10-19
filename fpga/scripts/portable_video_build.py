"""Build an immutable FPGA handoff package using the recipient's PDS installation.

Only offline native design actions are used. Each invocation owns a new output
directory; bit generation requires fresh min/max STA on the same routed DB.
"""
import argparse
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import xml.etree.ElementTree as ET
from implementation_readiness import require_whole_design_ready


TOP = 'pango_video_system'
ARCH = 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'


def digest(path):
    """Hash the exact stored bytes, including encrypted vendor IP."""
    with path.open('rb') as stream:
        return hashlib.file_digest(stream, 'sha256').hexdigest()


def verify(root):
    """Check the shipped manifest and transitive IDF dependencies before use."""
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    for name, expected in manifest['files'].items():
        path = root / name
        if not path.is_file() or digest(path) != expected['sha256']:
            raise ValueError('Missing or changed package file: ' + name)
    # config/ip_seeds contains generator recipes, not registered native IP.
    # Resolve only the generated IPs used by the frozen board flow.
    for path in (root / 'fpga/source/ip').glob('*/*.idf'):
        for element in ET.parse(path).iter('file'):
            name = element.get('pathname')
            if name and not (path.parent / name).is_file():
                raise ValueError('Missing IDF dependency: ' + str(path.parent / name))
    print('PACKAGE_VERIFIED', len(manifest['files']), flush=True)
    return manifest


def native(shell, run, args, label, env):
    """Record native output and reject both exit failures and PDS E messages."""
    log = run / (label + '.log')
    print('NATIVE_START', label, str(log), flush=True)
    with log.open('wb') as stream:
        child = subprocess.run([str(shell), *args, '-work_dir', str(run)], cwd=run,
                               env=env, stdout=stream, stderr=subprocess.STDOUT,
                               creationflags=0x08000000 if os.name == 'nt' else 0)
    output = log.read_text(encoding='utf-8', errors='replace')
    if child.returncode or re.search(r'^E:|Check license failed', output, re.M):
        raise RuntimeError(f'{label} failed; inspect {log}')
    return output


def script_action(shell, run, text, label, env):
    """Persist a reviewable native Tcl action and execute it in its own run."""
    script = run / (label + '.tcl')
    script.write_text(text, encoding='utf-8')
    return native(shell, run, ['-file', str(script)], label, env)


def main():
    """Relocate sources and checkpoints without changing the signed snapshot."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--package', type=Path, default=Path(__file__).resolve().parents[2])
    parser.add_argument('--pds-home', type=Path)
    parser.add_argument('--license-file', type=Path)
    parser.add_argument('--mode', choices=['verify', 'prepare', 'compile', 'map', 'full',
                                         'route-map', 'route-placement'], default='verify')
    parser.add_argument('--seed', type=int, default=11)
    parser.add_argument('--action-timeout', type=int, default=0,
                        help='PDS minutes; zero waits for the native routing result')
    args = parser.parse_args()
    root = args.package.resolve()
    # Portable full/route modes are still whole-design implementation. Reject
    # them before package verification, output creation or native tool launch
    # until the same reviewed design-completion record permits implementation.
    if args.mode in ('full', 'route-map', 'route-placement'):
        require_whole_design_ready()
    manifest = verify(root)
    if args.mode == 'verify':
        return
    if args.seed < 1 or args.action_timeout < 0:
        parser.error('seed must be positive and timeout nonnegative')
    if not args.pds_home:
        parser.error('--pds-home is required except for verify')
    shell = args.pds_home.resolve() / 'bin/pds_shell.exe'
    if not shell.is_file():
        raise FileNotFoundError(shell)
    # Braced Tcl paths safely support spaces but not literal braces/newlines.
    for path in (root, shell):
        if any(c in str(path) for c in '{}\n\r'):
            raise ValueError('Use an extraction/tool path without braces or newlines')
    env = os.environ.copy()
    if args.license_file:
        license_path = args.license_file.resolve(strict=True)
        env['PANGO_LICENSE_FILE'] = str(license_path)
    run = root / 'fpga/build' / datetime.now().strftime('%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    result = {'mode': args.mode, 'passed': False, 'bitstream_generated': False,
              'hardware_tested': False, 'download_approved': False,
              'package_manifest_sha256': digest(root / 'manifest.json')}
    print('RUN_DIRECTORY', run, flush=True)
    try:
        # The original P12 flow determines ordering and include paths. Replace
        # only its recorded build root, retaining synthesis and constraints.
        shutil.copytree(root / 'fpga/source', run / 'source')
        template = (root / 'fpga/project/flow.template.tcl').read_text(encoding='utf-8')
        flow = template.replace('@RUN@', run.as_posix())
        for path in re.findall(r'add_(?:design|constraint) \{([^}]+)\}', flow):
            if not Path(path).is_file():
                raise FileNotFoundError(path)
        (run / 'flow.tcl').write_text(flow, encoding='utf-8')
        prefix = flow.split('\ncompile ', 1)[0] + '\n'
        # Query this exact installed target before allowing database reuse.
        help_text = script_action(shell, run, ARCH + 'pnr -help\n', 'tool_help', env)
        for token in ('Version 2022.2-SP6.4 build 146967', '-planning_before_place', '-input_db_file'):
            if token not in help_text:
                raise RuntimeError('PDS version/capability mismatch: ' + token)
        script_action(shell, run, f'tcl2prj -tcl {{{(run / "flow.tcl").as_posix()}}}\n', 'create_project', env)
        if not (run / 'flow.pds').is_file():
            raise RuntimeError('PDS did not generate flow.pds')
        if args.mode in ('compile', 'map', 'full'):
            stage = 'compile' if args.mode == 'compile' else 'dev_map'
            native(shell, run, ['-project', str(run / 'flow.pds'), '-run', stage], stage, env)
        if args.mode in ('route-map', 'route-placement'):
            shutil.copytree(root / 'fpga/checkpoints/device_map', run / 'device_map')
        if args.mode in ('full', 'route-map', 'route-placement'):
            mapped = run / f'device_map/{TOP}_map.adf'
            physical = run / f'device_map/{TOP}.pcf'
            if not mapped.is_file() or not physical.is_file():
                raise RuntimeError('MAP database or physical constraints missing')
            prefix += f'add_constraint {{{physical.as_posix()}}}\n'
            options = (f' -action_timeout {args.action_timeout} -max_ctrl_chain_length 500'
                       f' -plc_decongestion 1 -gplace_seed {args.seed} -mode normal'
                       ' -congest_overlap_limit 200 -early_block_placement Global'
                       ' -planning_before_place TRUE -dump_router_congestion_plot TRUE')
            if args.mode == 'route-placement':
                # Reuse a completed PLC, never claim to save an in-memory
                # detailed-routing iteration. Seed describes the original PLC.
                placement = run / f'{TOP}_input_plc.adf'
                shutil.copyfile(root / f'fpga/checkpoints/place_route/{TOP}_plc.adf', placement)
                options = (f' -action_timeout {args.action_timeout} -max_ctrl_chain_length 500'
                           ' -mode normal -congest_overlap_limit 200 -dump_router_congestion_plot TRUE'
                           f' -input_place_db_file {{{placement.as_posix()}}}')
            result['map_sha256'] = digest(mapped)
            script_action(shell, run, prefix + f'pnr -force_to_run -input_db_file {{{mapped.as_posix()}}}' + options + '\n', 'place_route', env)
            routed = run / f'place_route/{TOP}_pnr.adf'
            if not routed.is_file():
                raise RuntimeError('No completed routed database')
            routed_hash = digest(routed)
            script_action(shell, run, prefix + f'report_timing -force_to_run -input_db_file {{{routed.as_posix()}}} -delay_type min_max -max_path 30 -report_exception TRUE\n', 'timing', env)
            report = run / f'report_timing/{TOP}.rtr'
            if digest(routed) != routed_hash or not re.search(r'^Design Summary\s*:\s*All Constraints Met\.', report.read_text(errors='replace'), re.M):
                raise RuntimeError('Fresh routed min/max timing did not pass')
            result['routed_sha256'] = routed_hash
            result['timing_sha256'] = digest(report)
            verify(root)
            # Gate the same immutable source bytes and routed DB before bitgen.
            source_hashes = json.loads((root / 'fpga/project/sources.json').read_text())
            if any(digest(run / 'source' / name) != sha for name, sha in source_hashes.items()):
                raise RuntimeError('Build source changed')
            from native_bitgen import generate_from_timed_database
            old_license = os.environ.get('PANGO_LICENSE_FILE')
            try:
                if 'PANGO_LICENSE_FILE' in env:
                    os.environ['PANGO_LICENSE_FILE'] = env['PANGO_LICENSE_FILE']
                child = generate_from_timed_database(run, str(shell), run / 'bitgen.log')
            finally:
                if old_license is None:
                    os.environ.pop('PANGO_LICENSE_FILE', None)
                else:
                    os.environ['PANGO_LICENSE_FILE'] = old_license
            bit = run / f'generate_bitstream/{TOP}.sbit'
            if child.returncode or re.search(r'^E:', (run / 'bitgen.log').read_text(errors='replace'), re.M) or not bit.is_file() or not bit.stat().st_size:
                raise RuntimeError('Native bit generation failed')
            result.update(bitstream_generated=True, bitstream=str(bit), bitstream_sha256=digest(bit))
            (run / 'BITSTREAM_SHA256.txt').write_text(digest(bit) + '  ' + bit.name + '\n')
        result['passed'] = True
    except Exception as exc:
        result['error'] = str(exc)
        raise
    finally:
        (run / 'result.json').write_text(json.dumps(result, indent=2), encoding='utf-8')
        print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()

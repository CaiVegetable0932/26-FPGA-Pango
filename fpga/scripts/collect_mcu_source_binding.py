"""Bind existing FPGA simulation evidence to one selected native source snapshot.

This is a read/hash/diff collector: it neither reruns simulations nor launches
PDS, changes readiness, or treats source equality as a physical timing pass.
"""
import argparse
from datetime import datetime, timezone
import difflib
import hashlib
import json
from pathlib import Path
import shutil


def digest(path):
    """Hash exact bytes; line ending differences are evidence differences."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read_json(path):
    """Read the UTF-8 manifests retained beside the original test execution."""
    return json.loads(path.read_text(encoding='utf-8-sig'))


def resolve_frozen(build, name):
    """Support the repository's hierarchical and flattened frozen layouts."""
    for path in (build/'source'/name, build/name, build/'source'/Path(name).name, build/Path(name).name):
        if path.is_file():
            return path
    raise ValueError('Missing frozen input: '+str(build)+' / '+name)


def checked_cases(result, selected):
    """Validate case outcomes; a top-level pass cannot hide a failed subcase."""
    actual = result.get('cases', result.get('tests'))
    if actual is None:
        if selected is not None:
            raise ValueError('Selected cases have no recorded outcomes')
        # Single-run Verilator evidence has only the top-level pass flag.
        return None, True
    if isinstance(actual, dict) and actual:
        names = set(actual)
        passed = all(v is True or isinstance(v, dict) and v.get('passed') is True
                     for v in actual.values())
    elif isinstance(actual, list) and actual:
        names = {row.get('name', row.get('test', row.get('bench', row.get('kind'))))
                 for row in actual if isinstance(row, dict)}
        passed = all(isinstance(row, dict) and row.get('passed') is True for row in actual)
    else:
        raise ValueError('Empty or unsupported case outcomes')
    if selected is not None:
        if not isinstance(selected, list) or not selected or not all(isinstance(n, str) for n in selected):
            raise ValueError('Selected cases must be a nonempty list of names')
        if not set(selected).issubset(names):
            raise ValueError('Selected case was not executed: '+str(set(selected)-names))
    return selected if selected is not None else actual, passed


def bind_simulation(build, candidate, selected_cases=None, note=''):
    """Check historical inputs and relevant RTL, keeping fixtures separately."""
    result_path = build/'result.json'
    result = read_json(result_path)
    manifest_path = build/'sources.json'
    # Focused timing-repair benches store the same exact-byte manifest inside
    # their result rather than in a separate sources.json file.
    manifest = read_json(manifest_path) if manifest_path.exists() else result.get('hashes', result.get('sources', result.get('source_hashes')))
    if not isinstance(manifest, dict) or not manifest:raise ValueError('Missing or empty historical input manifest: '+str(build))
    rtl, fixtures, mismatches = {}, {}, []
    by_name = {}
    for name in candidate:
        if name.startswith('rtl/'):
            by_name.setdefault(Path(name).name, []).append(name)
    for name, expected in manifest.items():
        path = resolve_frozen(build, name)
        actual = digest(path)
        if actual != expected:
            raise ValueError('Historical input drift: '+str(path))
        # Some integrity benches retain only basenames, so resolve a unique
        # selected RTL basename; testbenches/hex files never become RTL matches.
        native_name = name if name.startswith('rtl/') else None
        if native_name is None and Path(name).name in by_name:
            options = by_name[Path(name).name]
            if len(options) != 1:
                raise ValueError('Ambiguous selected RTL basename: '+name)
            native_name = options[0]
        row = dict(path=str(path), sha256=actual, historical_manifest_sha256=expected)
        if native_name is not None:
            row.update(candidate_path=native_name, candidate_sha256=candidate.get(native_name),
                       matches_candidate=actual == candidate.get(native_name))
            rtl[name] = row
            if not row['matches_candidate']:
                mismatches.append(native_name)
        else:
            fixtures[name] = row
    peer_manifest = build/'peer/vectors.json'
    if peer_manifest.exists():
        # These are C-produced firmware frames, distinct from the synthetic
        # STATE fixture in the general protocol regression's main manifest.
        peer = read_json(peer_manifest)
        for name, expected in peer['sha256'].items():
            path = build/'peer'/name
            if digest(path) != expected:
                raise ValueError('C peer vector drift: '+str(path))
            fixtures['peer/'+name] = dict(path=str(path), sha256=expected,
                historical_manifest_sha256=expected, origin=peer['origin'])
    extras = {}
    # Auxiliary C++/runner files did not all have original manifest entries.
    # Record their present hashes without claiming retrospective immutability.
    for path in sorted(build.rglob('*')):
        if path.is_file() and (path.suffix in ('.cpp', '.h', '.hpp', '.py') or path.name == 'CMakeLists.txt'):
            extras[path.relative_to(build).as_posix()] = dict(sha256=digest(path),
                historical_hash_verified=False, recorded_at_binding_only=True)
    cases, cases_passed = checked_cases(result, selected_cases)
    if not rtl:
        raise ValueError('Evidence contains no selected RTL inputs: '+str(build))
    return dict(path=str(build), result_sha256=digest(result_path), historical_passed=result.get('passed') is True,
                selected_cases=cases, scope_note=note, simulation_rerun=False,
                matching_rtl_files=len(rtl)-len(mismatches), mismatches=mismatches,
                frozen_inputs_verified=True, relevant_rtl=rtl, fixtures=fixtures,
                auxiliary_files=extras, case_outcomes_passed=cases_passed,
                bound_to_candidate=result.get('passed') is True and cases_passed and not mismatches)


def main():
    """Refresh review evidence while retaining prior generated files verbatim."""
    fpga=Path(__file__).resolve().parents[1]
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--baseline', type=Path, default=fpga/'build/full_integration_20261013/board_20261022_222010_653701')
    parser.add_argument('--evidence-definitions', type=Path,
                        help='JSON mapping names to [FPGA build-relative path, selected cases or null, scope note]')
    args=parser.parse_args()
    native=args.candidate.resolve(); baseline=args.baseline.resolve()
    for path in (native, baseline):
        if not path.is_relative_to(fpga/'build'):
            raise ValueError('Only frozen FPGA builds may be compared')
    manifest=read_json(native/'sources.json')
    for name, expected in manifest.items():
        if digest(native/'source'/name)!=expected:
            raise ValueError('Candidate snapshot drift: '+name)
    selected={k:v for k,v in manifest.items() if k.startswith(('rtl/','constraints/'))}
    current={k:dict(candidate_sha256=v,current_sha256=digest(fpga/k) if (fpga/k).exists() else None)
             for k,v in selected.items()}
    current_mismatches=[k for k,v in current.items() if v['candidate_sha256']!=v['current_sha256']]
    old_manifest=read_json(baseline/'sources.json')
    old={k:v for k,v in old_manifest.items() if k.startswith(('rtl/','constraints/'))}
    changes={}; patch=[]
    for name in sorted(set(old)|set(selected)):
        before=baseline/'source'/name; after=native/'source'/name
        if name in old and digest(before)!=old[name]:raise ValueError('Baseline drift: '+name)
        if old.get(name)==selected.get(name):continue
        changes['fpga/'+name]=dict(before_sha256=old.get(name),after_sha256=selected.get(name))
        # A review patch normalizes text newlines; the separate exact hashes
        # remain authoritative for the frozen native source bytes.
        a=before.read_text(encoding='utf-8-sig').splitlines() if before.exists() else []
        b=after.read_text(encoding='utf-8-sig').splitlines() if after.exists() else []
        patch.extend(difflib.unified_diff([line+'\n' for line in a],[line+'\n' for line in b],
                     fromfile='a/fpga/'+name if before.exists() else '/dev/null',
                     tofile='b/fpga/'+name if after.exists() else '/dev/null'))
    definitions={
      'full_frame_control_display':('full_integration_20261013/verilator_20261023_174921_106930',None,'E RTL, full frame/control/display, manual profile; no board STA'),
      'network':('full_integration_20261013/verilator_20261023_175626_972161',None,'E RTL, network test with small synthetic frames; not measured 1080p30 network throughput'),
      'pc_uart_current_profile':('mcu_link_20261023/regression_20261023_174524',['pc_mcu_link'],'23 UART requests, ENTITY_MASK=1BCA, kind2/kind5 disabled; kind12 retained'),
      'viewport_disabled':('pose_storage_20261023/viewport_off_20261023_175057_313126',None,'C6-off 66 checks plus motion algorithm/config regression'),
      'c6_backpressure':('core_area_20261023/c6_off_review',None,'4 jobs,124 held cycles,65535 timeout; independent synthetic bench'),
      'mcu_and_c_peer':('mcu_link_20261023/regression_20261023_173324',['mcu_link_adapter','mcu_readonly_client','uart_v2_parser','uart_8n1','mcu_uart_peer'],'Excludes historical pc_mcu_link profile; C vectors are independently hashed under peer/'),
      'config_integrity_revocation':('core_area_20261023/config_borrow_173855_603359',None,'16 checks, digest/full modes and concurrent revoke/error cases'),
      'dma_and_frame_storage':('core_area_20261023/172956_118919',None,'73728 round-robin combinations,three DMA random seeds,frame memory fabric'),
    }
    # A new candidate must explicitly select its matching regression evidence;
    # retain the historical defaults for reproducibility of earlier bindings.
    # Paths are constrained to FPGA build artifacts, not arbitrary source files.
    if args.evidence_definitions:
        definitions=read_json(args.evidence_definitions)
        if not isinstance(definitions,dict) or not definitions:
            raise ValueError('Evidence definitions must be a nonempty mapping')
        for label,definition in definitions.items():
            if not isinstance(definition,list) or len(definition)!=3:
                raise ValueError('Invalid evidence definition: '+label)
            if not (fpga/'build'/definition[0]).resolve().is_relative_to(fpga/'build'):
                raise ValueError('Evidence must remain under fpga/build: '+label)
    simulations={name:bind_simulation(fpga/'build'/relative,manifest,cases,note)
                 for name,(relative,cases,note) in definitions.items()}
    out=fpga/'build/mcu_link_20261023'
    previous=out/datetime.now().strftime('binding_history_%Y%m%d_%H%M%S_%f')
    previous.mkdir()
    for name in ('final_source_binding.json','implementation.patch','implementation_hashes.json'):
        if (out/name).exists():shutil.copyfile(out/name,previous/name)
    binding=dict(schema='fpga_source_binding.v2',collected_at=datetime.now(timezone.utc).isoformat(),
        native=str(native),native_sources_manifest_sha256=digest(native/'sources.json'),native_snapshot_intact=True,
        native_build_status='pending independent native completion/MAP/PnR/STA; this collector does not assess them',
        simulations=simulations,current_production_rtl_constraints=current,
        current_production_mismatches=current_mismatches,
        all_selected_simulations_bound=all(v['bound_to_candidate'] for v in simulations.values()),
        simulation_rerun=False,pds_executed=False,bitstream_generated=False)
    hashes=dict(baseline=str(baseline/'source'),candidate=str(native/'source'),scope=['rtl','constraints'],
        patch_newlines='normalized LF for review; hashes preserve exact bytes',changes=changes,
        current_production_mismatches=current_mismatches)
    (out/'final_source_binding.json').write_text(json.dumps(binding,indent=2)+'\n',encoding='utf-8')
    (out/'implementation_hashes.json').write_text(json.dumps(hashes,indent=2)+'\n',encoding='utf-8')
    (out/'implementation.patch').write_text(''.join(patch),encoding='utf-8',newline='\n')
    print(json.dumps(dict(native=str(native),changes=len(changes),current_mismatches=current_mismatches,
          simulations={k:dict(bound=v['bound_to_candidate'],matching_rtl_files=v['matching_rtl_files'],mismatches=v['mismatches']) for k,v in simulations.items()})))
    if current_mismatches or not binding['all_selected_simulations_bound']:raise SystemExit(1)


if __name__=='__main__':
    main()

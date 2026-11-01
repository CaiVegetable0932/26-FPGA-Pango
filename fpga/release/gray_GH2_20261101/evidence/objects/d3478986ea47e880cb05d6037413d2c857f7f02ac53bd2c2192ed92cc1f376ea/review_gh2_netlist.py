"""Review both GH2 structural changes on the same completed board SYN VM.

Reuse the audited G CE parser and H2 RAM/FSM proof, preserving every old result.
Unknown synthesis forms stop before MAP. No native operation is performed.
"""
import argparse
from datetime import datetime
import importlib.util
import json
from pathlib import Path
import sys

from evaluate_g_candidate import frozen_sources, read, sha
from review_g_netlist import inspect_syn, compare, EXPECTED_DE
from audit_h2_fsm_semantics import audit as audit_fsm


FPGA = Path(__file__).resolve().parents[1]
ROOT = FPGA / 'build/gh2_integration_20261101'
TOPOLOGY_HELPER = FPGA / 'build/write_cdc_owned_read_20261031/post_syn_review/gate_lut6d_review.py'


def topology_inspector():
    """Load the already-audited LUT6D cofactor parser without rewriting H2."""
    spec = importlib.util.spec_from_file_location('gh2_h2_topology', TOPOLOGY_HELPER)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module.inspect_board_vm


def save(path, value):
    """Publish one complete record; a new output directory prevents overwrite."""
    path.write_text(json.dumps(value, indent=2), encoding='utf-8')


def review(syn, candidate, out):
    """Require RAM ownership and actual CE branch coverage in the same VM."""
    if sys.flags.optimize:
        raise ValueError('Assertions are required by the reused RAM/FSM auditors')
    syn, candidate, out = syn.resolve(), candidate.resolve(), out.resolve()
    if not out.is_relative_to(ROOT) or out.exists():
        raise ValueError('Use a new GH2 review directory')
    out.mkdir(parents=True, exist_ok=False)
    vm = syn / 'synthesize/pango_video_system_syn.vm'
    record = dict(status='NEEDS_REVIEW', passed=False, synthesis=str(syn), candidate=str(candidate),
        checked_at=datetime.now().astimezone().isoformat(), physical_signoff=False,
        scripts_sha256={str(p):sha(p) for p in (Path(__file__), TOPOLOGY_HELPER,
            FPGA/'scripts/review_g_netlist.py', FPGA/'scripts/gate_h2_read_port.py',
            FPGA/'scripts/audit_h2_fsm_semantics.py', FPGA/'scripts/audit_h2_parent_guards.py')})
    try:
        manifest = frozen_sources(candidate)
        if frozen_sources(syn) != manifest:
            raise ValueError('SYN/candidate source mismatch')
        sr = read(syn/'result.json')
        if sr['native_exit'] != 0 or sr['errors'] or not sr['snapshot_intact']:
            raise ValueError('Successful complete SYN required')
        record.update(vm_sha256=sha(vm), sources_sha256=sha(candidate/'sources.json'),
                      synthesis_result_sha256=sha(syn/'result.json'))
        topology = topology_inspector()(vm)
        topology.update(vm=str(vm), vm_sha256=sha(vm), passed=False,
            topology_and_ce_bit_truth_passed=True, status='FSM_REVIEW_PENDING')
        save(out/'ram_topology.json', topology)
        semantics = audit_fsm(vm, guarded_board=True)
        if not semantics['passed'] or not semantics['parent_predicates']['passed']:
            raise ValueError('Actual GH2 FSM semantics not proven')
        save(out/'fsm_semantics.json', semantics)
        # These exact baseline sources keep the four retained-FF counts honest.
        de = FPGA / 'build/DE_optimization_20261031'
        ds = read(de/'native/state.json')
        baseline = inspect_syn(Path(ds['synthesis']), frozen_sources(de/'candidate'))
        for bank, groups in EXPECTED_DE.items():
            for group, expected in groups.items():
                item = baseline['banks'][bank]['groups'][group]
                if item['retained_ff_count'] != expected or item['branch_count'] != 1:
                    raise ValueError('Unexpected DE CE baseline')
        current = inspect_syn(syn, manifest)
        comparison = compare(baseline, current)
        save(out/'ce_review.json', dict(baseline=baseline, current=current, comparison=comparison,
            physical_signoff=False, limit='Counts measure actual local CE and all local input loads, not global fanout.'))
        if not comparison['retained_payload_metadata_coverage_equal'] or not comparison['four_enables_replication_visible']:
            raise ValueError('GH2 did not retain the intended four bounded CE branches/bit coverage')
        approved = dict(topology, passed=True, status='BOARD_RAM_AND_STATE_SEMANTICS_VERIFIED',
                        independent_fsm_review_sha256=sha(out/'fsm_semantics.json'))
        save(out/'board_ram_mapping_gate.json', approved)
        record.update(status='GH2_ACTUAL_BOARD_RAM_FSM_CE_VERIFIED', passed=True,
            ram_gate_sha256=sha(out/'board_ram_mapping_gate.json'),
            fsm_review_sha256=sha(out/'fsm_semantics.json'), ce_review_sha256=sha(out/'ce_review.json'))
    except Exception as error:
        record.update(error_type=type(error).__name__, error=str(error),
            next_action='Inspect exact GH2 VM and stopped SYN. Never re-SYN or broaden constraints solely to bypass this gate.')
    save(out/'review.json', record)
    return record


def main():
    """Explicit read-only review of a completed SYN; never starts native work."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--syn', type=Path, required=True)
    parser.add_argument('--candidate', type=Path, default=ROOT/'candidate')
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    result = review(args.syn, args.candidate, args.out)
    print(json.dumps(result, indent=2))
    raise SystemExit(0 if result['passed'] else 1)


if __name__ == '__main__':
    main()

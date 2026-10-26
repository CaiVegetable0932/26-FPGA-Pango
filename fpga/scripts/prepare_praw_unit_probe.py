"""Freeze a matched PRAW synthesis comparison without starting native tools.

Both versions expose the same dynamic ports, two packet banks and an 8ns clock
on PG2L100H-6/FBG676. Installed PDS 2022.2-SP6.4 settings match existing native
unit probes; neither this preparation nor a unit SYN constitutes board signoff.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def main():
    """Require intact functional evidence before freezing a native comparison."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--proof', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate, proof = args.candidate.resolve(), args.proof.resolve()
    if not candidate.is_relative_to(fpga/'build') or not proof.is_relative_to(candidate):
        raise ValueError('Candidate and proof must be frozen FPGA build files')
    result = json.loads((proof/'result.json').read_text())
    if not all(result.get(k) for k in ('passed', 'cycle_equivalent', 'inputs_intact')):
        raise ValueError('Passing functional proof required')
    if result.get('host_golden_packet_bytes') != 3303:
        raise ValueError('Independent complete packet golden check required')
    for name, digest in result['inputs'].items():
        if hashlib.sha256(Path(name).read_bytes()).hexdigest() != digest:
            raise ValueError('Functional proof input changed: '+name)
    run = candidate/datetime.now().strftime('unit_probe_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__, run/'preparation_script.py')
    inputs = {}
    for label, source in [('baseline', candidate/'original_praw_udp_tx.sv'),
                          ('candidate', candidate/'source/rtl/network/praw_udp_tx.sv')]:
        build = run/label
        build.mkdir()
        shutil.copyfile(source, build/'praw_udp_tx.sv')
        (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
        # The official installed compile/synthesize path is identical in both
        # cases. Do not run PnR or infer benefit merely from the RTL expression.
        flow = 'set_dir -impl_directory {'+build.as_posix()+'}\n'
        flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
        flow += 'add_design {'+(build/'praw_udp_tx.sv').as_posix()+'}\n'
        flow += 'add_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
        flow += 'compile -top_module praw_udp_tx -system_verilog\n'
        flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
        (build/'flow.tcl').write_text(flow)
        for path in (source, build/'praw_udp_tx.sv', build/'clock.fdc', build/'flow.tcl'):
            inputs[str(path)] = hashlib.sha256(path.read_bytes()).hexdigest()
    # Preparation is deliberately a separate state. Launch only after a real
    # in-flight task finishes and a fresh process/memory audit permits it.
    record = dict(status='prepared', native_started=False, native_completed=False,
        candidate=str(candidate), proof=str(proof), inputs=inputs,
        tool='E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
        launch_policy=dict(require_completed_current_attempt=True,
            minimum_free_physical_kib=4000000, maximum_existing_pds_shells=8),
        official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf',
        timing_signoff=False, programmed=False)
    (run/'prepared.json').write_text(json.dumps(record, indent=2)+'\n')
    print(run, flush=True)


if __name__ == '__main__':
    main()

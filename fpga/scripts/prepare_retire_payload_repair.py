"""Freeze a fabric candidate with completion payload independent of valid.

The already registered token, full ticket and error feed the frame bank
continuously. Only COMPLETE authorizes observation and commit, removing a
valid-controlled payload mux without changing any transaction edge.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes


def main():
    """Copy the complete frozen source set and retain the exact original fabric."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    base = args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Require a frozen FPGA candidate')
    before = json.loads((base/'sources.json').read_text())
    if hashes(base/'source') != before:
        raise ValueError('Baseline source inputs changed')
    name = 'rtl/memory/frame_memory_fabric.sv'
    content = (base/'source'/name).read_text()
    old = '''    if(retire_stage[b]==2) begin
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE]=1;
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_TOKEN]=retire_token[b];
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_TICKET]=retire_ticket[b];
     // Producer cancellation invalidates a partial frame. Read cancellation
     // merely abandons this consumer's transport; it cannot corrupt stored
     // pixels or revoke an independent snapshot/consumer of the same frame.
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_ERROR]=retire_error[b];
    end'''
    new = '''    // The completion descriptor is already held in bank-local registers.
    // Present it continuously so COMPLETE does not gate all 64 ticket bits
    // before their equality comparison. The frame bank observes these fields
    // only with COMPLETE asserted; retirement/ACK edges stay unchanged.
    commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE]=(retire_stage[b]==2);
    commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_TOKEN]=retire_token[b];
    commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_TICKET]=retire_ticket[b];
    // Producer cancellation invalidates a partial frame. Read cancellation
    // abandons only this consumer's transport, preserving independent readers.
    commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_ERROR]=retire_error[b];'''
    if content.count(old) != 1:
        raise ValueError('Unexpected completion-command baseline')
    run = fpga/'build/full_integration_20261013'/datetime.now().strftime('retire_payload_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source', run/'source')
    shutil.copyfile(base/'source'/name, run/'original_frame_memory_fabric.sv')
    (run/'source'/name).write_text(content.replace(old,new,1))
    after = hashes(run/'source')
    if set(before) != set(after) or {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Unexpected source differences')
    (run/'sources.json').write_text(json.dumps(after,indent=2)+'\n')
    record = dict(baseline=str(base),changed=[name],full_ticket_bits=64,
                  completion_edges_changed=False,functional_pass=False,
                  differential_required=True,full_model_required=True,
                  native_synthesis_started=False,routed=False,programmed=False)
    (run/'preparation.json').write_text(json.dumps(record,indent=2)+'\n')
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__ == '__main__':
    main()

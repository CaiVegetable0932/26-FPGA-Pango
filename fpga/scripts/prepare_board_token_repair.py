"""Freeze board-specific transaction capacities without changing frame pools.

The seven board clients each retain one request until retirement/ACK. SRC/DST
have three possible clients, RAW two, and each snapshot bank one. Generic
modules retain their original capacity unless this board mode is selected.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes


def main():
    """Preserve all evidence inputs and change only the three capacity bindings."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    base = args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Require frozen FPGA baseline')
    before = json.loads((base/'sources.json').read_text())
    if hashes(base/'source') != before:
        raise ValueError('Baseline inputs changed')
    run = fpga/'build/full_integration_20261013'/datetime.now().strftime('board_token_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source', run/'source')
    changes = {
        'rtl/memory/frame_manager.sv': [
            ('module frame_manager #(parameter TXNS=8)(',
             'module frame_manager #(parameter TXNS=8, parameter BOARD_CLIENT_LIMITS=0)('),
            ('  frame_pool_bank #(.SLOTS(bank>=SNAP_S1?1:3),.BASE(BANK_BASE),.TXNS(TXNS),',
             '''  // The board admits at most one request per connected client.
  // Only the board mode specializes transaction capacity; triple frame pools,
  // full 64-bit tickets and completion/drain ownership stay unchanged.
  localparam BANK_TOKENS=BOARD_CLIENT_LIMITS ? (bank==SRC || bank==DST ? 3 : bank==RAW ? 2 : 1) : TXNS;
  frame_pool_bank #(.SLOTS(bank>=SNAP_S1?1:3),.BASE(BANK_BASE),.TXNS(BANK_TOKENS),''')],
        'rtl/memory/frame_memory_fabric.sv': [
            ('parameter N=7, parameter BANK_TXNS=8, parameter CAPACITY_BYTES',
             'parameter N=7, parameter BANK_TXNS=8, parameter BOARD_CLIENT_LIMITS=0, parameter CAPACITY_BYTES'),
            (' frame_manager #(.TXNS(BANK_TXNS)) frames(',
             ''' // Board mode sizes each token scoreboard to its connected-client bound.
 // Requests still wait for ownership admission and retire only after DMA drain.
 frame_manager #(.TXNS(BANK_TXNS),.BOARD_CLIENT_LIMITS(BOARD_CLIENT_LIMITS)) frames(''')],
        'rtl/board/video_memory_core.sv': [
            (''' // until retirement/ACK. Four tokens per bank cover that proven bound; the
 // generic fabric keeps its eight-token default for arbitrary unit clients.
 frame_memory_fabric #(.BANK_TXNS(4)) fabric(''',
             ''' // until retirement/ACK. Size the scoreboards to those client bounds:
 // SRC/DST=3, RAW=2, snapshots=1 each. Generic fabric capacity is unchanged.
 // Full tickets, frame generations, drain checks and three-frame pools remain.
 frame_memory_fabric #(.BANK_TXNS(4),.BOARD_CLIENT_LIMITS(1)) fabric(''')]
    }
    for name, pairs in changes.items():
        p = run/'source'/name
        content = p.read_text()
        for old, new in pairs:
            if content.count(old) != 1:
                raise ValueError('Unexpected baseline at '+name)
            content = content.replace(old, new, 1)
        p.write_text(content)
    after = hashes(run/'source')
    if set(before) != set(after) or {n for n in before if before[n] != after[n]} != set(changes):
        raise ValueError('Unexpected composition changes')
    (run/'sources.json').write_text(json.dumps(after, indent=2)+'\n')
    record = dict(baseline=str(base), changed=list(changes), capacities=[3,3,2,1,1],
                  old_capacities=[4,4,4,4,4], frame_slots=[3,3,3,1,1],
                  full_ticket_bits=64, functional_pass=False, full_model_required=True,
                  native_synthesis_started=False, routed=False, programmed=False,
                  rationale='One accepted request per client until retirement/ACK; board wiring bounds SRC/DST=3 RAW=2 SNAP=1')
    (run/'preparation.json').write_text(json.dumps(record, indent=2)+'\n')
    shutil.copyfile(__file__, run/'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

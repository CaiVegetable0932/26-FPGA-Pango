"""Prepare slot-local token validity without changing the global scoreboard."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def localize(text):
    declaration = ' reg token_busy[0:TXNS-1];'
    condition = 'if(token_busy[t] && token_slot[t]==a) begin'
    anchor = ' // Transaction slot/owner payload is written atomically with token_busy'
    for marker in [declaration, condition, anchor]:
        if text.count(marker) != 1:
            raise ValueError('Unexpected pool structure: '+marker)
    text = text.replace(declaration, declaration+'''
 // Redundant validity is local to each slot; the central token/ticket
 // scoreboard still authorizes ISSUE and COMPLETE. Payload is never trusted
 // while idle. These flags mirror the same post-edge busy/slot relation.
 reg [TXNS-1:0] slot_token_active[0:SLOTS-1] /* synthesis syn_preserve=1 */;''')
    text = text.replace(condition, 'if(slot_token_active[a][t]) begin')
    logic = ''' // Preserve pre-state token reuse fences and original assignment priority.
 // COMPLETE clears every slot copy; ISSUE installs only its accepted slot.
 genvar local_slot, local_token;
 generate for(local_slot=0;local_slot<SLOTS;local_slot=local_slot+1) begin : slot_token_flags
  for(local_token=0;local_token<TXNS;local_token=local_token+1) begin : token_flag
   always @(posedge clk or negedge reset_n) begin
    if(!reset_n) slot_token_active[local_slot][local_token]<=0;
    else if(fabric_ready) begin
     if(cmd[`FM_CMD_COMPLETE] && rsp[`FM_RSP_COMPLETE_OK] &&
        cmd[`FM_CMD_COMPLETE_TOKEN]==local_token)
      slot_token_active[local_slot][local_token]<=0;
     if(cmd[`FM_CMD_ISSUE] && rsp[`FM_RSP_ISSUE_READY] &&
        rsp[`FM_RSP_ISSUE_TOKEN]==local_token)
      slot_token_active[local_slot][local_token]<=cmd[`FM_CMD_ISSUE_SLOT]==local_slot;
    end
   end
  end
 end endgenerate
'''
    return text.replace(anchor, logic+anchor)


def main():
    fpga = Path(__file__).resolve().parents[1]
    names = json.loads((fpga/'build/route_optimization/session_20261019/unpack_finalist/sources.json').read_text())
    run = fpga/'build/route_optimization'/datetime.now().strftime('pool_local_tokens_%Y%m%d_%H%M%S_%f')
    source = run/'source'
    source.mkdir(parents=True)
    for name, expected in names.items():
        original = fpga/name
        if hashlib.sha256(original.read_bytes()).hexdigest() != expected:
            raise ValueError('Verified main changed: '+name)
        target = source/name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(original, target)
    target = source/'rtl/memory/frame_pool_bank.sv'
    shutil.copyfile(target, run/'original_frame_pool_bank.sv')
    target.write_text(localize(target.read_text(encoding='utf-8')), encoding='utf-8', newline='\n')
    (run/'sources.json').write_text(json.dumps({n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names}, indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/frame_pool_bank.sv'],expected_extra_flags='SLOTS*TXNS',
        tickets_and_generations_unchanged=True,extra_latency_cycles=0), indent=2))
    shutil.copyfile(__file__, run/'prepare_script.py')
    print(run)


if __name__ == '__main__':
    main()

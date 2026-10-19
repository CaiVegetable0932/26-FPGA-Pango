"""Replace measured wide counter CE endpoints with exact chunked increments."""
import argparse
from datetime import datetime
import hashlib,json,shutil
from pathlib import Path


def localize(text,chunk):
    replacements={
        '   next_order<=0; published<=0;':'   published<=0;',
        '    token_busy[k]<=0; ticket[k]<=0;':'    token_busy[k]<=0;',
        "   if(cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY]) next_order<=next_order+1'b1;":'',
        '     token_busy[k]<=1; ticket[k]<=rsp[`FM_RSP_ISSUE_TICKET];':'     token_busy[k]<=1;'}
    for before,after in replacements.items():
        if text.count(before)!=1:raise ValueError('Unexpected pool counter structure')
        text=text.replace(before,after)
    anchor=' // Transaction slot/owner payload is written atomically with token_busy'
    if text.count(anchor)!=1:raise ValueError('Unexpected pool payload anchor')
    logic=f''' // Keep the complete 64-bit values and existing exhaustion fences.
 // Each chunk adds its accepted-event carry from the SAME pre-edge lower
 // bits. No counter update is delayed and no ticket bits are discarded.
 // Continuous add-with-carry targets the measured wide CE endpoint, rather
 // than copying a high-fanout authorization signal into another wide CE.
 wire accepted_alloc=fabric_ready && cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY];
 genvar counter_word,counter_token;
 generate for(counter_word=0;counter_word<{64//chunk};counter_word=counter_word+1) begin : order_chunks
  wire increment;
  if(counter_word==0)assign increment=accepted_alloc;
  else assign increment=accepted_alloc && (&next_order[counter_word*{chunk}-1:0]);
  always @(posedge clk or negedge reset_n)
   if(!reset_n)next_order[counter_word*{chunk}+:{chunk}]<=0;
   else next_order[counter_word*{chunk}+:{chunk}]<=next_order[counter_word*{chunk}+:{chunk}]+increment;
 end
 for(counter_token=0;counter_token<TXNS;counter_token=counter_token+1) begin : token_counter_chunks
  wire accepted_issue=fabric_ready && cmd[`FM_CMD_ISSUE] && rsp[`FM_RSP_ISSUE_READY] &&
   rsp[`FM_RSP_ISSUE_TOKEN]==counter_token;
  for(counter_word=0;counter_word<{64//chunk};counter_word=counter_word+1) begin : word_counter
   wire increment;
   if(counter_word==0)assign increment=accepted_issue;
   else assign increment=accepted_issue && (&ticket[counter_token][counter_word*{chunk}-1:0]);
   always @(posedge clk or negedge reset_n)
    if(!reset_n)ticket[counter_token][counter_word*{chunk}+:{chunk}]<=0;
    else ticket[counter_token][counter_word*{chunk}+:{chunk}]<=ticket[counter_token][counter_word*{chunk}+:{chunk}]+increment;
  end
 end endgenerate
'''
    return text.replace(anchor,logic+anchor)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--chunk-bits',type=int,choices=(8,16),default=16)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    names=json.loads((fpga/'build/route_optimization/session_20261019/unpack_finalist/sources.json').read_text())
    run=fpga/'build/route_optimization'/datetime.now().strftime('pool_chunk'+str(args.chunk_bits)+'_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    for name,expected in names.items():
        p=fpga/name
        if hashlib.sha256(p.read_bytes()).hexdigest()!=expected:raise ValueError('Main drift: '+name)
        target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
    target=source/'rtl/memory/frame_pool_bank.sv';shutil.copyfile(target,run/'original_frame_pool_bank.sv')
    target.write_text(localize(target.read_text(encoding='utf-8'),args.chunk_bits),encoding='utf-8',newline='\n')
    (run/'sources.json').write_text(json.dumps({n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names},indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/frame_pool_bank.sv'],chunk_bits=args.chunk_bits,counter_bits=64,
        latency_added_cycles=0,local_token_flags=False,saturation_fences_unchanged=True),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print(run)


if __name__=='__main__':main()

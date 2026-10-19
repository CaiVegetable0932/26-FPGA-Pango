"""Freeze a second review round: local capture control for aligned read data."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def main():
    """Preserve exact reset, valid, ready and tail-data semantics with no delay."""
    fpga=Path(__file__).resolve().parents[1]
    baseline=fpga/'build/full_integration_20261013/delay_20261019_163458_368603'
    names=json.loads((baseline/'sources.json').read_text(encoding='utf-8'))
    run=fpga/'build/route_optimization'/datetime.now().strftime('unpack_local_capture_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    hashes={}
    for name in names:
        origin=fpga/name;dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(origin,dest);hashes[name]=hashlib.sha256(dest.read_bytes()).hexdigest()
    target=source/'rtl/memory/dma_byte_unpack.v'
    original=target.read_bytes();(run/'original_dma_byte_unpack.v').write_bytes(original)
    text=original.decode('utf-8').replace('\r\n','\n')
    declaration='  reg [255:0] held_data;'
    replacement='''  reg [255:0] held_data;
  // Four physically distinct local state copies feed 64-bit capture groups.
  // Copies reflect the SAME next state as the authoritative handshake state;
  // no speculative ready, payload delay, reset removal or extra FIFO is used.
  reg [3:0] capture_active /* synthesis syn_preserve=1 */;
  reg [3:0] capture_nonzero /* synthesis syn_preserve=1 */;
  reg [3:0] capture_held_valid /* synthesis syn_preserve=1 */;
  wire start_fire=start_valid && start_ready;
  wire input_fire=beat_valid && beat_ready;
  wire output_fire=chunk_valid && chunk_ready;
  wire active_after=start_fire ? row_bytes!=0 :
    (output_fire && held_last ? 1'b0 : active);
  wire nonzero_after=start_fire ? row_bytes!=0 :
    (input_fire ? left>32 : left!=0);
  wire held_after=start_fire ? 1'b0 :
    (input_fire ? 1'b1 : (output_fire ? 1'b0 : held_valid));
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin capture_active<=0;capture_nonzero<=0;capture_held_valid<=0;end
   else begin
    capture_active<={4{active_after}};
    capture_nonzero<={4{nonzero_after}};
    capture_held_valid<={4{held_after}};
   end
  end
  genvar capture_group;
  for(capture_group=0;capture_group<4;capture_group=capture_group+1)begin: local_capture
   wire capture_enable=beat_valid && capture_active[capture_group] &&
    capture_nonzero[capture_group] && (!capture_held_valid[capture_group] || chunk_ready);
   // Preserve original asynchronous payload reset in every group.
   always @(posedge clk or negedge rst_n)begin
    if(!rst_n)held_data[capture_group*64+:64]<=0;
    else if(capture_enable)held_data[capture_group*64+:64]<=beat_data[capture_group*64+:64];
   end
  end'''
    old_reset='left<=0;held_data<=0;held_bytes<=0;'
    old_capture='held_data<=beat_data;held_bytes<=take;'
    if any(text.count(item)!=1 for item in (declaration,old_reset,old_capture)):
        raise ValueError('Aligned unpack baseline differs from reviewed structure')
    text=text.replace(declaration,replacement).replace(old_reset,'left<=0;held_bytes<=0;').replace(old_capture,'held_bytes<=take;')
    target.write_text(text,encoding='utf-8',newline='\n')
    hashes['rtl/memory/dma_byte_unpack.v']=hashlib.sha256(target.read_bytes()).hexdigest()
    (run/'sources.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
    (run/'candidate.json').write_text(json.dumps(dict(review_round=2,
        status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/dma_byte_unpack.v'],
        expected_added_ff=12,extra_latency_cycles=0,
        production_reset_preserved=True,physical_benefit_verified=False),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'prepare_script.py')
    print('UNPACK_LOCAL_CAPTURE',run)


if __name__=='__main__': main()

"""Prepare a latency-tolerant shared metadata read without touching live RTL.

Multi-slot pools arbitrate one synchronous descriptor read. Ownership is still
committed only on the public acquire ACK, after rechecking the selected slot,
generation, pending claim, cancellation and drain fences. DMA lanes are intact.
This is a candidate, not a verified replacement or a timing signoff.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Freeze one alternative and record every changed source for later proof."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Baseline must be in fpga/build')
    before=json.loads((base/'sources.json').read_text())
    if hashes(base/'source')!=before:
        raise ValueError('Frozen baseline changed')
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('metadata_read_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name='rtl/memory/frame_pool_bank.sv'
    path=run/'source'/name
    original=path.read_text(encoding='utf-8')
    text=replace_once(original,' reg [3:0] acq_ok, rel_ok, skip_ok;', ''' // Eligible means the current command can acquire ownership; metadata_match
 // additionally proves a prior synchronous read still belongs to that exact
 // consumer, slot and generation. A stale read can never create an ACK.
 reg [3:0] metadata_eligible;
 wire [3:0] metadata_match;
 reg [3:0] acq_ok, rel_ok, skip_ok;''')
    text=replace_once(text,'  acq_ok=0; rel_ok=0; skip_ok=0; acq_slots=0; acq_gens=0; acq_meta=0;',
        '  metadata_eligible=0;\n  acq_ok=0; rel_ok=0; skip_ok=0; acq_slots=0; acq_gens=0; acq_meta=0;')
    text=replace_once(text,'''     acq_ok[c]=1; acq_slots[2*c+:2]=selected[c];''', '''     metadata_eligible[c]=1;
     if(metadata_match[c]) begin
     acq_ok[c]=1; acq_slots[2*c+:2]=selected[c];''')
    text=replace_once(text,'''      capture_last[selected[c]],metadata_errors[selected[c]]);
    end''', '''      capture_last[selected[c]],metadata_errors[selected[c]]);
     end
    end''')
    text=replace_once(text,''' // Multi-slot storage retains one dynamic write and asynchronous read ports.''',
        ''' // Multi-slot storage uses one synchronous read, selected by a fair arbiter.
 // The public response stays zero until that read is revalidated; all existing
 // operation lanes except ACQUIRE retain their original cycle behavior.''')
    text=replace_once(text,''' generate if(SLOTS==1) begin : single_slot_metadata
  reg''', ''' generate if(SLOTS==1) begin : single_slot_metadata
  assign metadata_match=4'b1111;
  reg''')
    start=text.index(' end else begin : multi_slot_metadata')
    end=text.index(' end endgenerate',start)+len(' end endgenerate')
    text=text[:start]+''' end else begin : multi_slot_metadata
  // One block RAM read replaces replicated asynchronous consumer ports.
  // Payload RAM and its read output have no reset. The resettable fetch tag
  // and original busy/pending guards prevent stale/unknown data being exposed.
  reg [IMMUTABLE_META_BITS-1:0] storage[0:SLOTS-1] /* synthesis syn_ramstyle="block_ram" */;
  reg [IMMUTABLE_META_BITS-1:0] read_payload;
  reg fetch_valid;
  reg [1:0] fetch_consumer,fetch_slot,round_robin;
  reg [31:0] fetch_generation;
  integer scan_consumer,offset,choice;
  reg [1:0] read_slot;
  always @* begin
   choice=-1;read_slot=0;
   for(offset=0;offset<4;offset=offset+1) begin
    scan_consumer=(round_robin+offset)&3;
    if(choice<0 && metadata_eligible[scan_consumer])choice=scan_consumer;
   end
   if(choice>=0)read_slot=selected[choice];
  end
  genvar shared_consumer;
  for(shared_consumer=0;shared_consumer<4;shared_consumer=shared_consumer+1) begin : consumer_read
   assign consumer_immutable[shared_consumer]=read_payload;
   assign metadata_match[shared_consumer]=fetch_valid &&
    fetch_consumer==shared_consumer && fetch_slot==selected[shared_consumer] &&
    fetch_generation==generation[fetch_slot];
  end
  // SEAL needs capture_first independently of ACQUIRE. A small allocation-only
  // copy preserves its immediate validation and avoids adding an asynchronous
  // port to block RAM. Neither payload copy can outlive its ownership guards.
  reg [63:0] seal_first[0:SLOTS-1];
  assign seal_capture_first=seal_first[cmd[`FM_CMD_SEAL_SLOT]];
  always @(posedge clk) begin
   if(fabric_ready && cmd[`FM_CMD_ALLOC] && rsp[`FM_RSP_ALLOC_READY]) begin
    storage[rsp[`FM_RSP_ALLOC_SLOT]]<=allocation_immutable;
    seal_first[rsp[`FM_RSP_ALLOC_SLOT]]<=allocation_meta[`FM_META_CAPTURE_FIRST];
   end
   if(fabric_ready && choice>=0)read_payload<=storage[read_slot];
  end
  // Reads speculate only on currently eligible claims. ACK is revalidated
  // combinationally on the following cycle, so pause/cancel/error/reset never
  // leaks a reference. Round-robin advances on a real accepted acquisition.
  always @(posedge clk or negedge reset_n) begin
   if(!reset_n) begin
    fetch_valid<=0;fetch_consumer<=0;fetch_slot<=0;fetch_generation<=0;round_robin<=0;
   end else begin
    fetch_valid<=fabric_ready && choice>=0;
    if(fabric_ready && choice>=0) begin
     fetch_consumer<=choice;fetch_slot<=read_slot;fetch_generation<=generation[read_slot];
    end
    if(fabric_ready && |acq_ok)round_robin<=fetch_consumer+1'b1;
   end
  end
 end endgenerate'''+text[end:]
    text=replace_once(text,'''     // All pieces sample the same selected slot without adding a clock stage.''',
        '''     // Mutable fields are sampled at ACK; immutable payload was fetched
     // earlier and its exact generation/slot revalidated before this ACK.''')
    text=replace_once(text,''' // Neither branch resets payload. Resettable busy/ownership guards prevent''',
        ''' // Multi-slot payload uses a shared synchronous block RAM read; the
 // one-slot payload remains FF. Neither branch resets payload. Ownership guards prevent''')
    # Remove the superseded asynchronous-read description while preserving the
    # immutable field schema and every allocation/cancellation/ticket guard.
    text=replace_once(text,''' // minimum depth on one-slot snapshot banks. Multi-slot banks keep the tested
 // asynchronous distributed RAM implementation; SLOTS=1 uses clock-only FF.''',
        ''' // minimum depth on one-slot snapshot banks. SLOTS=1 uses clock-only FF;
 // multi-slot consumers accept a bounded metadata-fetch handshake delay.''')
    text=replace_once(text,''' // Branch-local storage exposes only dynamic consumer read ports. Do not
 // broadcast every slot through constant read aliases: installed ADS mapped
 // that structure to FF instead of the requested distributed RAM.''',
        ''' // Branch-local storage exposes the descriptor selected for this ACK.
 // Multi-slot consumers share one registered RAM read; one-slot consumers
 // retain their original direct FF payload. No constant per-slot RAM aliases.''')
    path.write_text(text,encoding='utf-8')
    (run/'original_frame_pool_bank.sv').write_text(original,encoding='utf-8')
    after=hashes(run/'source')
    if {n for n in before if before[n]!=after[n]}!={name}:
        raise ValueError('Unexpected input change')
    (run/'sources.json').write_text(json.dumps(after,indent=2))
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),candidate=str(run),changed=[name],
        source_count=len(after),functional_pass=False,routed=False,cycle_equivalent=False,
        semantics='Bounded ACQUIRE latency; accepted metadata/ownership and DMA lanes preserved',programmed=False),indent=2))
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__=='__main__':
    main()

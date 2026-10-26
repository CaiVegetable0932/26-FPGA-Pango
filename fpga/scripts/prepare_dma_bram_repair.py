"""Freeze a DMA block-RAM repair without changing running native projects.

The installed ADS 2022.2-SP6.4 guide section 5.16 specifies block_ram and a
synchronous read template. Preserve all seven reservations and native drain
rules; prefetch the next cursor to sustain one native beat per clock. Delay
client read visibility by one clock so same-address RAM collisions are never
observable. Existing scoreboards and the full-frame model must validate this
latency before promotion; this script alone establishes no functional result.
"""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def digest_tree(root):
    """Bind every copied RTL/IP/constraint input to actual immutable bytes."""
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def main():
    """Prepare a single congestion repair, keeping baseline evidence intact."""
    fpga = Path(__file__).resolve().parents[1]
    base = fpga / 'build/full_integration_20261013/delay_20261014_220546_195131'
    manifest = json.loads((base / 'sources.json').read_text(encoding='utf-8'))
    assert digest_tree(base / 'source') == manifest
    run = base.parent / datetime.now().strftime('dma_bram_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base / 'source', run / 'source')
    relative = 'rtl/memory/ddr_native_dma.v'
    path = run / 'source' / relative
    original = path.read_text(encoding='utf-8')
    text = original
    start = text.index(' // Purpose: one static local RAM bank per client')
    end = text.index(' // Purpose: quota-limited urgent selection', start)
    text = text[:start] + ''' // Purpose: prefetch the post-edge native cursor into synchronous block RAM.
 // This duplicates only the small address next-state expression, not payload
 // storage. WD and readback still consume one beat per native handshake.
 reg [4:0] next_beat_index;
 always @* begin
  next_beat_index=beat_index;
  if(!rst_n) next_beat_index=0;
  else if(state==IDLE && chosen>=0 && !fault && controller_ready &&
          !cancel[chosen[CLIENT_BITS-1:0]]) next_beat_index=0;
  else if(state==WD && native_wready) begin
   if(beat_index==beats[owner]-1'b1) begin
    if(VERIFY_WRITES) next_beat_index=0;
   end else next_beat_index=beat_index+1'b1;
  end else if((state==RD || state==VERIFY_DATA) && native_rvalid &&
              beat_index!=beats[owner]-1'b1) next_beat_index=beat_index+1'b1;
 end

 // Each client retains its own complete reservation. Payload uses dedicated
 // block RAM; the much smaller masks retain asynchronous distributed reads.
 // Read outputs are exposed only after one settling edge following returned.
 // Thus a one-beat read cannot expose old RAM data on its final write edge;
 // no device-dependent mixed-port read-during-write mode is assumed.
 reg [CLIENTS-1:0] returned_settled;
 genvar g;
 generate for(g=0;g<CLIENTS;g=g+1) begin: client_bank
  assign eligible[g]=pending[g] && !done[g] && !aborted[g] && !returned[g] &&
   (!is_write[g] || loaded[g]==beats[g]);
  reg [255:0] payload[0:MAX_BEATS-1] /* synthesis syn_ramstyle="block_ram" */;
  reg [31:0] masks[0:MAX_BEATS-1] /* synthesis syn_ramstyle="lut_ram" */;
  reg [255:0] payload_q;
  reg [INDEX_BITS-1:0] prefetch_index;
  reg next_is_write;
  reg [4:0] next_consumed;
  always @* begin
   next_is_write=is_write[g]; next_consumed=consumed[g];
   if(!rst_n) begin next_is_write=0; next_consumed=0; end
   else begin
    if(req_valid[g] && req_ready[g]) begin
     next_is_write=req_write[g]; next_consumed=0;
    end
    if(r_valid[g] && r_ready[g]) next_consumed=consumed[g]+1'b1;
   end
   prefetch_index=next_is_write ? next_beat_index[INDEX_BITS-1:0] :
                                  next_consumed[INDEX_BITS-1:0];
  end
  // A single write port and synchronous read infer the official simple
  // dual-port template. Payload and output registers intentionally have no
  // reset; descriptor/control reset prevents access before a complete fill.
  always @(posedge clk) begin
   if(w_valid[g] && w_ready[g]) begin
    payload[loaded[g][INDEX_BITS-1:0]]<=w_data[g*256+:256];
    masks[loaded[g][INDEX_BITS-1:0]]<=w_strb[g*32+:32];
   end else if(state==RD && native_rvalid && owner==g)
    payload[beat_index[INDEX_BITS-1:0]]<=native_rdata;
   payload_q<=payload[prefetch_index];
  end
  assign bank_data[g*256+:256]=payload_q;
  assign bank_mask[g*32+:32]=masks[beat_index[INDEX_BITS-1:0]];
 end endgenerate

''' + text[end:]
    text = text.replace('r_valid[j]=returned[j] &&', 'r_valid[j]=returned[j] && returned_settled[j] &&')
    text = text.replace('state<=IDLE; pending<=0;', 'returned_settled<=0;\n   state<=IDLE; pending<=0;', 1)
    text = text.replace('if(!controller_ready &&', '// One complete read-port edge precedes client visibility.\n   returned_settled<=returned;\n   if(!controller_ready &&', 1)
    path.write_text(text, encoding='utf-8')
    (run / 'original_ddr_native_dma.v').write_text(original, encoding='utf-8')
    after = digest_tree(run / 'source')
    assert {n for n in manifest if manifest[n] != after[n]} == {relative}
    (run / 'sources.json').write_text(json.dumps(after, indent=2), encoding='utf-8')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    evidence = dict(baseline=str(base), candidate=str(run), source_count=len(after),
                    changed=[relative], original_sha256=manifest[relative],
                    candidate_sha256=after[relative], functional_pass=False,
                    native_map_pass=False, routed=False, programmed=False,
                    interface_change='one extra client read visibility clock per burst; native beat throughput unchanged')
    (run / 'preparation.json').write_text(json.dumps(evidence, indent=2), encoding='utf-8')
    print(run, flush=True)


if __name__ == '__main__':
    main()

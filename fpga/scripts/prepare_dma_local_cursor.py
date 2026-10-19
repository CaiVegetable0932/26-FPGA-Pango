"""Prepare bounded round-3 candidates for the measured shared cursor hotspot."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil


def localize_cursor(text):
    """Mirror the exact post-edge cursor; keep RAM prefetch edge unchanged."""
    match=re.search(r' always @\* begin\n  next_beat_index=beat_index;.*?\n end\n',text,re.S)
    if not match:raise ValueError('Unexpected native prefetch structure')
    local_logic=re.sub(r'\bnext_beat_index\b','local_next_beat_index',match[0])
    local_logic=re.sub(r'\bbeat_index\b','local_cursor',local_logic)
    declaration=' reg [4:0] next_beat_index;'
    copies=''' reg [4:0] next_beat_index;
 // Local copies mirror the SAME post-edge cursor, including IDLE holds.
 // Unlike an extra pipeline stage, these copies receive the cursor's next
 // value. RAM read/write addresses and exposed masks keep their old cycles.
 reg [CLIENTS*5-1:0] client_cursor /* synthesis syn_preserve=1 */;
 wire cursor_grant=state==IDLE && chosen>=0 && !fault && controller_ready &&
   !cancel[chosen[CLIENT_BITS-1:0]];
 wire [4:0] cursor_after=(state==IDLE && !cursor_grant) ? beat_index : next_beat_index;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)client_cursor<=0;
  else client_cursor<={CLIENTS{cursor_after}};
 end'''
    if text.count(declaration)!=1:raise ValueError('Unexpected cursor declaration')
    text=text.replace(declaration,copies)
    anchor='  reg [INDEX_BITS-1:0] prefetch_index;'
    local='''  // Keep each bank's address/control fanout next to that bank.
  wire [4:0] local_cursor=client_cursor[g*5+:5];
  reg [4:0] local_next_beat_index;
'''+local_logic+'\n'+anchor
    if text.count(anchor)!=1:raise ValueError('Unexpected client bank')
    text=text.replace(anchor,local)
    for before,after in (
        ('prefetch_index=next_is_write ? next_beat_index[INDEX_BITS-1:0]',
         'prefetch_index=next_is_write ? local_next_beat_index[INDEX_BITS-1:0]'),
        ('payload[beat_index[INDEX_BITS-1:0]]<=native_rdata;',
         'payload[local_cursor[INDEX_BITS-1:0]]<=native_rdata;'),
        ('bank_mask[g*32+:32]=masks[beat_index[INDEX_BITS-1:0]];',
         'bank_mask[g*32+:32]=masks[local_cursor[INDEX_BITS-1:0]];')):
        if text.count(before)!=1:raise ValueError('Unexpected bank cursor use: '+before)
        text=text.replace(before,after)
    return text


def localize_stats(text):
    """The second candidate adds the already-tested local comparison to A."""
    before='''     if(wait_cycles[chosen[CLIENT_BITS-1:0]]>max_wait_cycles[chosen[CLIENT_BITS-1:0]*32+:32])
      max_wait_cycles[chosen[CLIENT_BITS-1:0]*32+:32]<=wait_cycles[chosen[CLIENT_BITS-1:0]];'''
    anchor='    // Do not withdraw a VALID address, even if cancelled before acceptance.'
    replacement='''    // Constant client slices remove the central statistics read/write mux.
    // The grant still captures the same pre-edge 32-bit wait counter.
    if(state==IDLE && chosen==i && !fault && controller_ready && !cancel[i])begin
     if(wait_cycles[i]>max_wait_cycles[i*32+:32])
      max_wait_cycles[i*32+:32]<=wait_cycles[i];
    end
'''
    if text.count(before)!=1 or text.count(anchor)!=1:
        raise ValueError('Unexpected wait statistics cone')
    return text.replace(before,'').replace(anchor,replacement+anchor)


def main():
    """A=local cursor versus main; B=local stats versus A, one factor per edge."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--with-local-stats',action='store_true')
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    names=json.loads((fpga/'build/full_integration_20261013/delay_20261019_163458_368603/sources.json').read_text())
    label='dma_cursor_stats' if args.with_local_stats else 'dma_local_cursor'
    run=fpga/'build/route_optimization'/datetime.now().strftime(label+'_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True);hashes={}
    for name in names:
        dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(fpga/name,dest);hashes[name]=hashlib.sha256(dest.read_bytes()).hexdigest()
    target=source/'rtl/memory/ddr_native_dma.v';base_bytes=target.read_bytes()
    base=target.read_text(encoding='utf-8')
    cursor=localize_cursor(base)
    reference=cursor if args.with_local_stats else base
    changed=localize_stats(cursor) if args.with_local_stats else cursor
    (run/'original_ddr_native_dma.v').write_bytes(reference.encode('utf-8') if args.with_local_stats else base_bytes)
    target.write_text(changed,encoding='utf-8',newline='\n')
    hashes['rtl/memory/ddr_native_dma.v']=hashlib.sha256(target.read_bytes()).hexdigest()
    (run/'sources.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
    (run/'candidate.json').write_text(json.dumps(dict(review_round=3,
        status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',with_local_stats=args.with_local_stats,
        reference='local_cursor_A' if args.with_local_stats else 'writer_baseline',
        changed_files=['rtl/memory/ddr_native_dma.v'],expected_scalar_copies='CLIENTS*5',
        extra_payload_latency_cycles=0,storage_type_unchanged=True),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'prepare_script.py');print('DMA_CURSOR_CANDIDATE',run)


if __name__=='__main__':main()

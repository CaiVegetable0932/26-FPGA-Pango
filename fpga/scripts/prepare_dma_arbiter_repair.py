"""Replace rotating dynamic-client reads with fixed-client priority selection.

The first eligible client at/above rr wins, or the first overall on wrap. The
urgent selector follows the same ordering; quota and pointer updates stay as
before. No extra edge or burst latency is introduced. Keep original full DMA
bytes for both an isolated comparison and the earlier prefetch proof chain.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes,replace_once


def main():
    """Prepare only frozen FPGA build files; never modify a running design."""
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline',type=Path,required=True)
    p.add_argument('--prefetch-reference',type=Path,required=True)
    args=p.parse_args();fpga=Path(__file__).resolve().parents[1];base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):raise ValueError('Frozen build required')
    before=json.loads((base/'sources.json').read_text())
    if hashes(base/'source')!=before:raise ValueError('Baseline changed')
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('dma_arbiter_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source');name='rtl/memory/ddr_native_dma.v';path=run/'source'/name;old=path.read_text()
    text=replace_once(old,' integer i, j, k, byte_count;',
        ''' // Static priority encoders avoid rr+j dynamic array muxes. Wrap
 // candidates retain the lowest eligible index when no index is >= rr.
 integer normal_wrap,urgent_wrap;
 integer i, j, byte_count;''')
    text=replace_once(text,'''  normal_choice=-1; urgent_choice=-1;
  for(j=0;j<CLIENTS;j=j+1) begin
   k=rr+j; if(k>=CLIENTS) k=k-CLIENTS;
   // rr+j is reduced into 0..CLIENTS-1 before the narrow array selection.
   if(eligible[k[CLIENT_BITS-1:0]]) begin
    if(normal_choice<0) normal_choice=k;
    if(urgent[k[CLIENT_BITS-1:0]] && urgent_choice<0) urgent_choice=k;
   end''',
        '''  normal_choice=-1; urgent_choice=-1;normal_wrap=-1;urgent_wrap=-1;
  // Ascending fixed lanes implement exactly the same cyclic order: select
  // the first eligible index >= rr, otherwise wrap to the lowest index.
  // Urgency is independently ordered before the unchanged quota decision.
  for(j=0;j<CLIENTS;j=j+1) begin
   if(eligible[j]) begin
    if(normal_wrap<0)normal_wrap=j;
    if(j>=rr && normal_choice<0)normal_choice=j;
    if(urgent[j])begin
     if(urgent_wrap<0)urgent_wrap=j;
     if(j>=rr && urgent_choice<0)urgent_choice=j;
    end
   end''')
    text=replace_once(text,'  chosen=normal_choice;',
        '''  if(normal_choice<0)normal_choice=normal_wrap;
  if(urgent_choice<0)urgent_choice=urgent_wrap;
  chosen=normal_choice;''')
    path.write_text(text);(run/'arbiter_baseline_dma.v').write_text(old)
    # The integration differential compares both repairs directly against the
    # pre-prefetch reference, rather than losing that earlier proof obligation.
    reference=args.prefetch_reference.resolve()
    if not reference.is_relative_to(fpga/'build'):raise ValueError('Frozen reference required')
    shutil.copyfile(reference,run/'original_ddr_native_dma.v')
    for n in ('original_frame_pixel_writer.sv','original_geometry_tile_refill.sv'):
        shutil.copyfile(base/n,run/n)
    after=hashes(run/'source')
    if {n for n in before if before[n]!=after[n]}!={name}:raise ValueError('Unexpected changes')
    (run/'sources.json').write_text(json.dumps(after,indent=2))
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),prefetch_reference=str(reference),changed=[name],functional_pass=False,programmed=False),indent=2))
    shutil.copyfile(__file__,run/'preparation_script.py');print(run,flush=True)


if __name__=='__main__':main()

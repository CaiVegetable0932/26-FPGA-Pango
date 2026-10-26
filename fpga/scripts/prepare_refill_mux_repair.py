"""Expose the refill's fixed 16-way pair selection to the native synthesizer.

The row stores, DMA schedule and edge masks remain unchanged. Only adjacent
RGB pixels share an explicitly bounded constant-slice mux, replacing separate
integer-indexed byte selections. No accuracy or frame-rate tradeoff is made.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Freeze a standalone alternative; never edit a running source snapshot."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    base = args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Baseline must be under fpga/build')
    before = json.loads((base/'sources.json').read_text(encoding='utf-8'))
    if hashes(base/'source')!=before:
        raise ValueError('Baseline input changed')
    run = fpga/'build/full_integration_20261013'/datetime.now().strftime('refill_mux_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name = 'rtl/memory/geometry_tile_refill.sv'
    path = run/'source'/name
    original = path.read_text(encoding='utf-8')
    start = original.index(' // Memory stores R,G,B')
    end = original.index(' // 32-pixel RGB tiles',start)
    # Every possible quad value selects one constant 48-bit pair from each
    # row. The original per-pixel frame-bound masks are kept verbatim in width.
    selection = '\n'.join("    4'd%d: select_pair=bytes[%d+:48];"%(q,q*48) for q in range(16))
    replacement = ''' // Memory stores R,G,B in increasing byte addresses. Select each adjacent
 // pair once through a bounded 16-way constant-slice mux; no general integer
 // byte shifter is required. Keep the original per-pixel edge mask and sample
 // order. Row storage and output acceptance edges are unchanged.
 function [47:0] select_pair(input [767:0] bytes,input [3:0] index);
  begin
   case(index)
'''+selection+'''
    default: select_pair=48'bx;
   endcase
  end
 endfunction
 wire [47:0] even_pair=select_pair(row_even,quad);
 wire [47:0] odd_pair=select_pair(row_odd,quad);
 function [23:0] pixel(input [23:0] bytes,input integer x,input integer y);
  begin
   if(start_x+x>=width || start_y+y>=height)pixel=0;
   else pixel={bytes[7:0],bytes[15:8],bytes[23:16]};
  end
 endfunction
 assign fill_rgb=state==FAILED ? 96'b0 : {
  pixel(odd_pair[47:24],quad*2+1,row),pixel(odd_pair[23:0],quad*2,row),
  pixel(even_pair[47:24],quad*2+1,row-1),pixel(even_pair[23:0],quad*2,row-1)};
'''
    path.write_text(replace_once(original,original[start:end],replacement),encoding='utf-8')
    (run/'original_geometry_tile_refill.sv').write_text(original,encoding='utf-8')
    shutil.copyfile(base/'source/rtl/memory/frame_pixel_writer.sv',run/'original_frame_pixel_writer.sv')
    after=hashes(run/'source')
    if {n for n in before if before[n]!=after[n]}!={name}:
        raise ValueError('Unexpected source change')
    (run/'sources.json').write_text(json.dumps(after,indent=2),encoding='utf-8')
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),candidate=str(run),
        changed=[name],source_count=len(after),functional_pass=False,routed=False,
        minimum_corrected_fps=30,programmed=False),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__=='__main__':
    main()

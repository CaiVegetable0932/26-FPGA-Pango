"""Freeze a refill row-storage alternative with unchanged valid-cycle latency.

Installed ADS guide pp93-95 documents syn_ramstyle=lut_ram. Two asynchronous
beat reads provide each 48-bit pixel pair; no new state or memory-read cycle is
introduced. Storage is never reset: every valid in-frame byte is overwritten
before EMIT, and the original masks suppress virtual rows and tail pixels.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Change only refill storage inside an independently frozen source tree."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Baseline must be under fpga/build')
    before=json.loads((base/'sources.json').read_text(encoding='utf-8'))
    if hashes(base/'source')!=before:
        raise ValueError('Baseline changed')
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('refill_storage_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name='rtl/memory/geometry_tile_refill.sv'
    path=run/'source'/name;original=path.read_text(encoding='utf-8')
    text=replace_once(original,' reg [767:0] row_even,row_odd;', ''' // Each row has three aligned 256-bit beats. A fourth address is unused;
 // pair reads wrap to beat zero after beat two, whose upper neighbor is never
 // consumed. Valid in-frame bytes are all written before the EMIT state.
 reg [255:0] even_beats[0:3] /* synthesis syn_ramstyle="lut_ram" */;
 reg [255:0] odd_beats[0:3] /* synthesis syn_ramstyle="lut_ram" */;
 wire [3:0] write_beat={1'b0,returned}+{1'b0,segment_start};
 wire [9:0] pair_offset={6'd0,quad}*10'd48;
 wire [1:0] read_beat=pair_offset[9:8];
 wire [1:0] next_beat=read_beat==2 ? 2'd0 : read_beat+2'd1;
 wire [511:0] even_window={even_beats[next_beat],even_beats[read_beat]};
 wire [511:0] odd_window={odd_beats[next_beat],odd_beats[read_beat]};
 wire [47:0] even_pair=even_window>>pair_offset[7:0];
 wire [47:0] odd_pair=odd_window>>pair_offset[7:0];
 // Separate clock-only payload writes enable LUTRAM inference. The original
 // FSM reset, failed/cancel flags and valid guards remain asynchronous. Reads
 // are consumed only in EMIT, after all DMA responses were drained; RECEIVE
 // writes cannot collide with an accepted output. No no_rw_check attribute.
 always @(posedge clk)begin
  if(rst_n && state==RECEIVE && r_valid && write_beat<3)begin
   if(row[0])odd_beats[write_beat[1:0]]<=r_data;
   else even_beats[write_beat[1:0]]<=r_data;
  end
 end''')
    start=text.index(' // Memory stores R,G,B');end=text.index(' // 32-pixel RGB tiles',start)
    text=replace_once(text,text[start:end],''' // Memory stores R,G,B in increasing byte addresses. Each pair may span
 // two DMA beats; the six selected bytes are reordered into two RGB samples.
 // Preserve the original frame-bound masks: virtual rows/tail pixels must
 // produce zero regardless of stale/uninitialized payload outside the frame.
 function [23:0] pixel(input [23:0] bytes,input integer x,input integer y);
  begin
   if(start_x+x>=width || start_y+y>=height)pixel=0;
   else pixel={bytes[7:0],bytes[15:8],bytes[23:16]};
  end
 endfunction
 assign fill_rgb=state==FAILED ? 96'b0 : {
  pixel(odd_pair[47:24],quad*2+1,row),pixel(odd_pair[23:0],quad*2,row),
  pixel(even_pair[47:24],quad*2+1,row-1),pixel(even_pair[23:0],quad*2,row-1)};
''')
    text=replace_once(text,'failed<=0;cancelled_seen<=0;row_even<=0;row_odd<=0;',
                          'failed<=0;cancelled_seen<=0;')
    text=replace_once(text,'     row_even<=0;row_odd<=0;state<=VALIDATE;',
                          '     // Payload is overwritten by DMA; frame-bound masks cover virtual samples.\n     state<=VALIDATE;')
    text=replace_once(text,'if(row[0])begin row_odd<=0;quad<=0;state<=EMIT;end',
                          'if(row[0])begin quad<=0;state<=EMIT;end')
    text=replace_once(text,'else begin row_even<=0;row<=row+1\'b1;row_address<=row_address+stride;end',
                          'else begin row<=row+1\'b1;row_address<=row_address+stride;end')
    text=replace_once(text,'''      if(returned+segment_start<3)begin
       if(row[0])row_odd[(returned+segment_start)*256+:256]<=r_data;
       else row_even[(returned+segment_start)*256+:256]<=r_data;
      end''', '''      // The clock-only row memories above accept this beat on the same
      // edge. Protocol errors still force FAILED before any EMIT publication.''')
    path.write_text(text,encoding='utf-8')
    (run/'original_geometry_tile_refill.sv').write_text(original,encoding='utf-8')
    shutil.copyfile(base/'source/rtl/memory/frame_pixel_writer.sv',run/'original_frame_pixel_writer.sv')
    after=hashes(run/'source')
    if {n for n in before if before[n]!=after[n]}!={name}:
        raise ValueError('Unexpected source change')
    (run/'sources.json').write_text(json.dumps(after,indent=2),encoding='utf-8')
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),candidate=str(run),
        changed=[name],functional_pass=False,routed=False,minimum_corrected_fps=30,
        notes='Inactive fill_rgb payload is not contractual; valid payload and cycles must match',
        programmed=False),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__=='__main__':
    main()

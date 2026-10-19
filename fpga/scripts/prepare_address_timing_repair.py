"""Freeze a throughput-preserving address/length repair for the video build.

Keep native clocks, timing constraints and all existing source snapshots intact.
The writer replaces repeated coordinate multiplies with address recurrences;
refill uses its existing VALIDATE/SPAN cycles to register tile-invariant length.
This preparation alone is not simulation, timing or hardware signoff.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def hashes(root):
    """Record actual input bytes so candidate and baseline cannot be mixed."""
    return {p.relative_to(root).as_posix(): hashlib.sha256(p.read_bytes()).hexdigest()
            for p in sorted(root.rglob('*')) if p.is_file()}


def replace_once(text, old, new):
    """Fail on source drift rather than silently applying a partial repair."""
    if text.count(old) != 1:
        raise ValueError('Expected one source block: ' + old[:90])
    return text.replace(old, new, 1)


def writer_repair(text):
    """Advance addresses at existing segment boundaries without adding stalls."""
    text = replace_once(text, ' reg [31:0] base,stride,generation,address;', ''' reg [31:0] stride,generation,address;
 // Segment addresses follow the same raster/tile coordinate transitions.
 // Keep the active DMA address separate: 4KiB splits may advance it while
 // the next segment address is already prepared. All updates overlap the
 // existing COLLECT/DRAIN work, so the repair adds no segment wait cycles.
 reg [31:0] segment_address,row_base,tile_band_base,tile_top;
 wire [31:0] segment_step=rgb ? 32'd96 : 32'd32;
 wire [31:0] next_band_base=tile_band_base+(stride<<3);''')
    text = replace_once(text, 'state<=IDLE;base<=0;stride<=0;',
                        'state<=IDLE;segment_address<=0;row_base<=0;tile_band_base<=0;tile_top<=0;stride<=0;')
    text = replace_once(text, 'base<=frame_base;stride<=frame_stride;',
                        'segment_address<=frame_base;row_base<=frame_base;tile_band_base<=frame_base;tile_top<=frame_base;stride<=frame_stride;')
    text = replace_once(text, 'address<=base+y*stride+x*(rgb?3:1);',
                        'address<=segment_address;')
    text = replace_once(text,
        "if(!TILED)begin x<=(x==width-1'b1) ? 0 : x+1'b1;if(x==width-1'b1)y<=y+1'b1;end",
        """if(!TILED)begin
         x<=(x==width-1'b1) ? 0 : x+1'b1;
         if(x==width-1'b1)begin
          y<=y+1'b1;row_base<=row_base+stride;segment_address<=row_base+stride;
         end else segment_address<=segment_address+segment_step;
        end""")
    text = replace_once(text,
        'if(tile_x+32>=width)begin tile_x<=0;x<=0;tile_y<=tile_y+8;y<=tile_y+8;end',
        '''if(tile_x+32>=width)begin
           tile_x<=0;x<=0;tile_y<=tile_y+8;y<=tile_y+8;
           tile_band_base<=next_band_base;tile_top<=next_band_base;segment_address<=next_band_base;
          end''')
    text = replace_once(text,
        'else begin tile_x<=tile_x+32;x<=tile_x+32;y<=tile_y;end',
        '''else begin
           tile_x<=tile_x+32;x<=tile_x+32;y<=tile_y;
           tile_top<=tile_top+segment_step;segment_address<=tile_top+segment_step;
          end''')
    text = replace_once(text, "end else y<=y+1'b1;",
                        "end else begin y<=y+1'b1;segment_address<=segment_address+stride;end")
    return text


def refill_repair(text):
    """Split clipping and byte rounding across already-existing startup edges."""
    text = replace_once(text, ' reg [16:0] valid_pixels;', ''' // Tile width is invariant across all eight rows. Clip it in VALIDATE,
 // round to beats in SPAN, then only compare small lengths in PREPARE.
 // Preserve partial right edges and the existing request/response latency.
 reg [16:0] valid_pixels;
 wire [16:0] remaining_pixels=start_x>=width ? 17'd0 : {1'b0,width}-start_x;''')
    text = replace_once(text, '''  valid_pixels=start_x>=width ? 0 : width-start_x;
  if(valid_pixels>32)valid_pixels=32;
  needed_beats=(valid_pixels*3+31)>>5;
''', '')
    text = replace_once(text, 'span_rows<=0;tile_offset<=0;row_bytes<=0;row_address<=0;shape_ok<=0;',
                        'span_rows<=0;tile_offset<=0;row_bytes<=0;row_address<=0;shape_ok<=0;valid_pixels<=0;needed_beats<=0;')
    text = replace_once(text, '     span_rows<=last_row_index*stride;',
                        "     valid_pixels<=remaining_pixels>32 ? 17'd32 : remaining_pixels;\n     span_rows<=last_row_index*stride;")
    text = replace_once(text, '    SPAN:begin\n',
                        "    SPAN:begin\n     needed_beats<=(valid_pixels*3+31)>>5;\n")
    return text


def main():
    """Create one isolated source variant and preserve originals for comparison."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    base = args.baseline.resolve()
    if not base.is_relative_to(fpga / 'build'):
        raise ValueError('Baseline must be an FPGA build snapshot')
    before = json.loads((base / 'sources.json').read_text(encoding='utf-8'))
    if hashes(base / 'source') != before:
        raise ValueError('Baseline inputs changed')
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('address_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base / 'source', run / 'source')
    repairs = {'rtl/memory/frame_pixel_writer.sv': writer_repair,
               'rtl/memory/geometry_tile_refill.sv': refill_repair}
    for name, repair in repairs.items():
        path = run / 'source' / name
        original = path.read_text(encoding='utf-8')
        (run / ('original_' + path.name)).write_text(original, encoding='utf-8')
        path.write_text(repair(original), encoding='utf-8')
    after = hashes(run / 'source')
    if {n for n in before if before[n] != after[n]} != set(repairs):
        raise ValueError('Unexpected source change')
    (run / 'sources.json').write_text(json.dumps(after, indent=2), encoding='utf-8')
    (run / 'preparation.json').write_text(json.dumps(dict(
        baseline=str(base), candidate=str(run), changed=list(repairs),
        source_count=len(after), added_segment_wait_cycles=0,
        minimum_corrected_fps=30, width=1920, height=1080,
        functional_pass=False, routed=False, programmed=False), indent=2), encoding='utf-8')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

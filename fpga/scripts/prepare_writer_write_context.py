"""Freeze a zero-added-cycle segment-buffer write-context trial from P12."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Preserve the full frozen source set and alter only writer write gating."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    baseline = args.baseline.resolve()
    if not baseline.is_relative_to(fpga / 'build'):
        raise ValueError('Frozen FPGA baseline required')
    before = json.loads((baseline / 'sources.json').read_text(encoding='utf-8'))
    if len(before) != 290 or hashes(baseline / 'source') != before:
        raise ValueError('Baseline source integrity failed')
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime(
        'writer_write_context_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline / 'source', run / 'source')
    name = 'rtl/memory/frame_pixel_writer.sv'
    path = run / 'source' / name
    text = path.read_text(encoding='utf-8')
    marker = ' // Coordinates advance by raster or 32x8 tile rows.'
    # The redundant context describes current COLLECT and !aborting, using
    # the exact transition priorities of the existing control always block.
    added = ''' // Predecode the segment-buffer write context on the prior edge.
 // This flag equals (state==COLLECT && !aborting); current frame_abort,
 // pack_valid and stored bounds still qualify the original write edge.
 // Coordinate failure may coincide with pack_last: aborting wins eligibility
 // even when the later pack_last assignment changes state to REQUEST.
 reg collect_write_context;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)collect_write_context<=0;
  else begin
   collect_write_context<=0;
   if(state==START_PACK)
    collect_write_context<=!aborting && !frame_abort && pack_start_ready;
   else if(state==COLLECT)
    collect_write_context<=!aborting && !frame_abort &&
     !(in_valid && in_ready && !correct_pixel) &&
     !(pack_valid && (stored>=3 || pack_last));
  end
 end
 // Keep payload storage unreset and indexed exactly as before for LUTRAM.
 // Separating its clock-only write avoids bringing the full state decoder
 // into the shared memory write qualifier; physical benefit needs mapping.
 always @(posedge clk)begin
  if(rst_n && collect_write_context && !frame_abort && pack_valid && stored<3)begin
   words[stored]<=pack_data;masks[stored]<=pack_strb;
  end
 end

'''
    text = replace_once(text, marker, added + marker)
    text = replace_once(text,
        'words[stored]<=pack_data;masks[stored]<=pack_strb;stored<=stored+1\'b1;',
        "stored<=stored+1'b1;")
    path.write_text(text, encoding='utf-8')
    for module in ('geometry_tile_refill', 'frame_pixel_writer'):
        shutil.copyfile(baseline / 'source/rtl/memory' / (module + '.sv'),
                        run / ('original_' + module + '.sv'))
    after = hashes(run / 'source')
    if set(before) != set(after) or {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Unexpected source changes')
    (run / 'sources.json').write_text(json.dumps(after, indent=2) + '\n')
    (run / 'preparation.json').write_text(json.dumps(dict(
        baseline=str(baseline), candidate=str(run), changed=[name],
        source_count=290, minimum_corrected_fps=30, functional_pass=False,
        routed=False, programmed=False, added_wait_cycles=0,
        intent='Predecode segment write context; physical benefit unproven'), indent=2) + '\n')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

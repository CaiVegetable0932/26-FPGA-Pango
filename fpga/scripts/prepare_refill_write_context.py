"""Freeze a P12 write-context retiming trial without changing receive latency."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Bind the full baseline and change only the refill write-control decode."""
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
        'refill_write_context_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline / 'source', run / 'source')
    name = 'rtl/memory/geometry_tile_refill.sv'
    path = run / 'source' / name
    text = path.read_text(encoding='utf-8')
    start = text.index(' // Separate clock-only payload writes')
    end = text.index(' // Capture, multiply, then validate', start)
    # RECEIVE is entered only by an accepted ADDRESS and left on done.
    # Row parity cannot change on either transition into RECEIVE or within it.
    # Thus these flags describe the CURRENT receive context after each edge,
    # without delaying r_valid/r_data or changing the memory write edge.
    replacement = ''' // Predecode the next receive context into two row-local controls.
 // This removes the state/parity decode from the wide LUTRAM write enable.
 // ADDRESS acceptance enters RECEIVE; done leaves it even on errors/cancel.
 // Row parity is stable across entry and throughout RECEIVE. Async reset
 // clears both flags; payload memories remain clock-only and unreset.
 reg receive_even,receive_odd;
 wire receive_next=(state==ADDRESS && req_ready) ||
                   (state==RECEIVE && !done);
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin receive_even<=0;receive_odd<=0;end
  else begin
   receive_even<=receive_next && !row[0];
   receive_odd<=receive_next && row[0];
  end
 end
 // Current-cycle DMA payload and address are written on the original edge.
 // Preserve invalid beat suppression and the original LUTRAM read semantics.
 always @(posedge clk)begin
  if(rst_n && r_valid && write_beat<3)begin
   if(receive_odd)odd_beats[write_beat[1:0]]<=r_data;
   if(receive_even)even_beats[write_beat[1:0]]<=r_data;
  end
 end
'''
    path.write_text(replace_once(text, text[start:end], replacement), encoding='utf-8')
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
        intent='Predecode receive/parity control; physical benefit unproven'), indent=2) + '\n')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

"""Freeze a P12 refill mux alternative while retaining its LUTRAM row stores.

The sixteen legal quad positions need only fixed 48-bit slices. This trial
removes arithmetic-driven wide shifting without changing payload writes,
dynamic memory reads, frame masks, states, or accepted-cycle latency.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Create an isolated one-file trial; never change the active route input."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    baseline = args.baseline.resolve()
    if not baseline.is_relative_to(fpga / 'build'):
        raise ValueError('A frozen FPGA baseline is required')
    before = json.loads((baseline / 'sources.json').read_text(encoding='utf-8'))
    if len(before) != 290 or hashes(baseline / 'source') != before:
        raise ValueError('The complete baseline source set changed')
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime(
        'refill_window_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline / 'source', run / 'source')
    name = 'rtl/memory/geometry_tile_refill.sv'
    path = run / 'source' / name
    original = path.read_text(encoding='utf-8')
    start = original.index(' wire [9:0] pair_offset=')
    end = original.index(' // Separate clock-only payload writes', start)
    # A pair starts at bit 48*q of the three-beat row. The memory ports still
    # read floor(48*q/256) and its neighbor, including the original wrap rule.
    cases = '\n'.join(
        "    4'd%d: window_pair=window_bits[%d+:48];" % (q, (48*q) % 256)
        for q in range(16))
    replacement = ''' // Only sixteen quad positions are legal. Decode their beat range and
 // fixed pair slices directly, preserving the two dynamic LUTRAM read ports.
 // Quads 5 and 10 cross beat boundaries; their constant slices retain both
 // pieces. No pipeline, extra wait state, or row-store replication is added.
 wire [1:0] read_beat=quad<6 ? 2'd0 : quad<11 ? 2'd1 : 2'd2;
 wire [1:0] next_beat=read_beat==2 ? 2'd0 : read_beat+2'd1;
 wire [511:0] even_window={even_beats[next_beat],even_beats[read_beat]};
 wire [511:0] odd_window={odd_beats[next_beat],odd_beats[read_beat]};
 function [47:0] window_pair(input [511:0] window_bits,input [3:0] index);
  begin
   case(index)
'''+cases+'''
    default: window_pair=48'bx;
   endcase
  end
 endfunction
 wire [47:0] even_pair=window_pair(even_window,quad);
 wire [47:0] odd_pair=window_pair(odd_window,quad);
'''
    path.write_text(replace_once(original, original[start:end], replacement), encoding='utf-8')
    # Keep byte-exact P12 references for differential verification and native
    # unit comparisons; previous candidates' original modules are not reused.
    for module in ('geometry_tile_refill', 'frame_pixel_writer'):
        shutil.copyfile(baseline / 'source/rtl/memory' / (module+'.sv'),
                        run / ('original_'+module+'.sv'))
    after = hashes(run / 'source')
    if {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Unexpected source changes')
    (run / 'sources.json').write_text(json.dumps(after, indent=2)+'\n', encoding='utf-8')
    (run / 'preparation.json').write_text(json.dumps(dict(
        baseline=str(baseline), candidate=str(run), changed=[name],
        source_count=290, functional_pass=False, routed=False,
        minimum_corrected_fps=30, programmed=False,
        required_proofs=['cycle differential with storage edges',
                         'native resource/timing comparison',
                         'full frame model and regression before promotion']), indent=2)+'\n', encoding='utf-8')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

"""Freeze a synchronous segment-cache trial without changing live RTL.

PDS 2022.2-SP6.4 ADS Synthesis User Guide section 5.16 documents
syn_ramstyle=block_ram. Physical benefit must be measured after equivalence.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Retain all frozen inputs; replace only the writer's local storage."""
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
        'writer_bram_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline / 'source', run / 'source')
    name = 'rtl/memory/frame_pixel_writer.sv'
    path = run / 'source' / name
    text = path.read_text(encoding='utf-8')
    text = replace_once(text,
        ' reg [255:0] words[0:2];reg [31:0] masks[0:2];',
        ''' // Store each complete data/mask beat together in dedicated RAM.
 // Storage remains unreset; control prevents use before segment collection.
 reg [287:0] segment_cache[0:2] /* synthesis syn_ramstyle="block_ram,low_power" */;
 reg [287:0] segment_read;
'''.rstrip())
    text = replace_once(text,
        ' assign w_data=words[burst_start+feed_index],w_strb=masks[burst_start+feed_index];',
        ' assign w_data=segment_read[287:32],w_strb=segment_read[31:0];')
    marker = ' // Coordinates advance by raster or 32x8 tile rows.'
    added = ''' // REQUEST already precedes FEED, providing the first synchronous read.
 // On an accepted beat prefetch the next index at the same edge that advances
 // feed_index. Backpressure rereads the held beat; a split starts a new REQUEST.
 // No new state or ready/valid latency is introduced. Out-of-range data is
 // irrelevant after the final beat because the original w_valid deasserts.
 // A split REQUEST retains the prior feed_index until req_ready, so its
 // first read must explicitly select burst_start rather than that old index.
 wire [2:0] segment_read_index=(state==REQUEST) ? burst_start :
  burst_start+feed_index+((state==FEED && w_valid && w_ready) ? 3'd1 : 3'd0);
 always @(posedge clk)begin
  segment_read<=segment_cache[segment_read_index];
  if(rst_n && state==COLLECT && !aborting && !frame_abort && pack_valid && stored<3)
   segment_cache[stored]<={pack_data,pack_strb};
 end

'''
    text = replace_once(text, marker, added + marker)
    text = replace_once(text,
        "words[stored]<=pack_data;masks[stored]<=pack_strb;stored<=stored+1'b1;",
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
        routed=False, programmed=False, intended_added_wait_cycles=0,
        official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf section 5.16',
        intent='Synchronous DRM segment storage with handshake lookahead; benefit unproven'), indent=2) + '\n')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

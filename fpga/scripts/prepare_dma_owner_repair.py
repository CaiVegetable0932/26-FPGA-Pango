"""Freeze a P12 DMA wide-selector trial without adding transaction cycles.

Keep the existing binary owner for control and hold a matching one-hot owner
for the 256-bit payload and 32-bit mask reduction. Each bank sees its own
selection bit instead of broadcasting the binary owner across the wide mux.
Native synthesis and transport equivalence must establish any benefit.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Create an isolated one-file alternative; preserve all live inputs."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    baseline = args.baseline.resolve()
    if not baseline.is_relative_to(fpga / 'build'):
        raise ValueError('Frozen FPGA baseline required')
    before = json.loads((baseline / 'sources.json').read_text(encoding='utf-8'))
    if len(before) != 290 or hashes(baseline / 'source') != before:
        raise ValueError('Complete source snapshot changed')
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime(
        'dma_owner_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline / 'source', run / 'source')
    name = 'rtl/memory/ddr_native_dma.v'
    source = run / 'source' / name
    text = source.read_text(encoding='utf-8')
    text = replace_once(text, ' reg [CLIENT_BITS-1:0] owner,rr;', ''' reg [CLIENT_BITS-1:0] owner,rr;
 // Hold one bank-local selector per payload lane on the same edge as owner.
 // Binary owner remains authoritative for the unchanged arbitration/control.
 // Reset selects bank zero, matching the original inactive payload selection.
 reg [CLIENTS-1:0] owner_onehot;
 reg [255:0] selected_data;
 reg [31:0] selected_mask;
 integer select_bank;
 always @* begin
  selected_data=0; selected_mask=0;
  for(select_bank=0;select_bank<CLIENTS;select_bank=select_bank+1)begin
   selected_data=selected_data | (bank_data[select_bank*256+:256] & {256{owner_onehot[select_bank]}});
   selected_mask=selected_mask | (bank_mask[select_bank*32+:32] & {32{owner_onehot[select_bank]}});
  end
 end''')
    # All users share the same selected payload/mask. The storage, prefetch,
    # accepted beat cursor, verification and cancellation schedules are intact.
    text = replace_once(text, 'assign native_wdata=bank_data[owner*256+:256];',
                        'assign native_wdata=selected_data;')
    text = replace_once(text, "(state==WD) ? bank_mask[owner*32+:32] : 32'd0;",
                        "(state==WD) ? selected_mask : 32'd0;")
    text = replace_once(text, 'bank_mask[owner*32+verify_byte]', 'selected_mask[verify_byte]')
    text = replace_once(text, 'bank_data[owner*256+verify_byte*8+:8]', 'selected_data[verify_byte*8+:8]')
    text = replace_once(text, 'byte_count+bank_mask[owner*32+i]', 'byte_count+selected_mask[i]')
    text = replace_once(text, '   owner<=0; rr<=0;',
                        "   owner<=0; owner_onehot<={{(CLIENTS-1){1'b0}},1'b1}; rr<=0;")
    text = replace_once(text, '     owner<=chosen[CLIENT_BITS-1:0]; beat_index<=0;', '''     // No extra arbitration or payload cycle: both owner encodings change
     // only at the existing grant edge and remain stable through the burst.
     for(i=0;i<CLIENTS;i=i+1)owner_onehot[i]<=(chosen[CLIENT_BITS-1:0]==i);
     owner<=chosen[CLIENT_BITS-1:0]; beat_index<=0;''')
    source.write_text(text, encoding='utf-8')
    shutil.copyfile(baseline / 'source' / name, run / 'original_ddr_native_dma.v')
    after = hashes(run / 'source')
    if {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Unexpected source differences')
    (run / 'sources.json').write_text(json.dumps(after, indent=2)+'\n', encoding='utf-8')
    (run / 'preparation.json').write_text(json.dumps(dict(
        baseline=str(baseline), changed=[name], source_count=290,
        functional_pass=False, routed=False, programmed=False,
        intended_added_cycles=0, native_benefit_unproven=True), indent=2)+'\n', encoding='utf-8')
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

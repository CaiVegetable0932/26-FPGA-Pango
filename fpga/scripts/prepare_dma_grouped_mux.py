"""Freeze a binary, two-level DMA data selector from the accepted source set.

Unlike the previously rejected one-hot OR tree, this trial retains binary
selection at both levels. Four local lane registers drive two-client groups;
the group selector drives only the final reduction. Ownership changes on the
existing grant edge, so all native/client timing and arbitration is unchanged.
Installed ADS guide section 5.15 documents local syn_preserve registers. Their
physical survival and benefit still require native synthesis/MAP/placement.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def grouped_selector(text):
    """Replace only payload selection; keep the original owner authoritative."""
    text = replace_once(text, ' reg [CLIENT_BITS-1:0] owner,rr;', ''' reg [CLIENT_BITS-1:0] owner,rr;
 // Binary two-client groups localize low-order owner fanout. All copies
 // update on the existing grant edge and hold through write/readback/drain.
 // ADS 5.15 preserves only these intentionally redundant local registers.
 localparam OWNER_GROUPS=(CLIENTS+1)/2;
 localparam OWNER_GROUP_BITS=(OWNER_GROUPS>1)?$clog2(OWNER_GROUPS):1;
 reg [OWNER_GROUPS-1:0] owner_lane /* synthesis syn_preserve=1 */;
 reg [OWNER_GROUP_BITS-1:0] owner_group;
 wire [OWNER_GROUPS*256-1:0] grouped_data;
 wire [OWNER_GROUPS*32-1:0] grouped_mask;
 wire [255:0] selected_data=grouped_data[owner_group*256+:256];
 wire [31:0] selected_mask=grouped_mask[owner_group*32+:32];
 genvar owner_pair;
 generate for(owner_pair=0;owner_pair<OWNER_GROUPS;owner_pair=owner_pair+1)begin: owner_mux_group
  if(owner_pair*2+1<CLIENTS)begin: full_pair
   assign grouped_data[owner_pair*256+:256]=owner_lane[owner_pair] ?
    bank_data[(owner_pair*2+1)*256+:256] : bank_data[(owner_pair*2)*256+:256];
   assign grouped_mask[owner_pair*32+:32]=owner_lane[owner_pair] ?
    bank_mask[(owner_pair*2+1)*32+:32] : bank_mask[(owner_pair*2)*32+:32];
  end else begin: final_single
   // Preserve out-of-range selection as unknown rather than inventing an
   // additional legal client. Reachable grants always select an actual bank.
   assign grouped_data[owner_pair*256+:256]=owner_lane[owner_pair] ?
    256'bx : bank_data[(owner_pair*2)*256+:256];
   assign grouped_mask[owner_pair*32+:32]=owner_lane[owner_pair] ?
    32'bx : bank_mask[(owner_pair*2)*32+:32];
  end
 end endgenerate''')
    text = replace_once(text, 'assign native_wdata=bank_data[owner*256+:256];',
                        'assign native_wdata=selected_data;')
    text = replace_once(text, "(state==WD) ? bank_mask[owner*32+:32] : 32'd0;",
                        "(state==WD) ? selected_mask : 32'd0;")
    text = replace_once(text, 'bank_mask[owner*32+verify_byte]', 'selected_mask[verify_byte]')
    text = replace_once(text, 'bank_data[owner*256+verify_byte*8+:8]',
                        'selected_data[verify_byte*8+:8]')
    text = replace_once(text, 'byte_count+bank_mask[owner*32+i]', 'byte_count+selected_mask[i]')
    text = replace_once(text, '   owner<=0; rr<=0;',
                        '   owner<=0; owner_lane<=0; owner_group<=0; rr<=0;')
    text = replace_once(text, '     owner<=chosen[CLIENT_BITS-1:0]; beat_index<=0;', '''     // The same accepted grant installs all group-local selectors, with
     // no new arbitration edge or native beat of latency.
     owner_lane<={OWNER_GROUPS{chosen[0]}};
     owner_group<=chosen[CLIENT_BITS-1:0]>>1;
     owner<=chosen[CLIENT_BITS-1:0]; beat_index<=0;''')
    return text


def main():
    """Create one isolated variant; do not modify live or running snapshots."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    baseline = args.baseline.resolve()
    if not baseline.is_relative_to(fpga/'build'):
        raise ValueError('An immutable FPGA source build is required')
    before = json.loads((baseline/'sources.json').read_text(encoding='utf-8'))
    if len(before) != 290 or hashes(baseline/'source') != before:
        raise ValueError('Complete baseline bytes do not match their manifest')
    run = fpga/'build/route_optimization'/datetime.now().strftime('dma_grouped_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline/'source', run/'source')
    name = 'rtl/memory/ddr_native_dma.v'
    path = run/'source'/name
    shutil.copyfile(path, run/'original_ddr_native_dma.v')
    path.write_text(grouped_selector(path.read_text(encoding='utf-8')), encoding='utf-8')
    after = hashes(run/'source')
    if set(before) != set(after) or {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Grouped selector must change exactly one source')
    (run/'sources.json').write_text(json.dumps(after, indent=2)+'\n')
    (run/'preparation.json').write_text(json.dumps(dict(
        baseline=str(baseline), changed=[name], source_count=len(after),
        intended_added_cycles=0, intended_added_ff=6,
        official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf section 5.15',
        strategy='binary two-client groups; not the rejected one-hot OR reduction',
        functional_pass=False, physical_benefit_verified=False, routed=False,
        programmed=False), indent=2)+'\n')
    shutil.copyfile(__file__, run/'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

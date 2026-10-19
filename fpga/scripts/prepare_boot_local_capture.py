"""Localize PC status-snapshot enables without changing reset or capture time.

The last parser response determines page zero one cycle before CHECK. Register
eight local copies on that edge; each drives one 192-bit page on the original
CHECK capture edge. All public and payload resets remain intact. This differs
from the previous unreset-payload experiment that increased control sets.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def local_capture(text):
    """Predecode only the known status operation and final collected byte."""
    reset = 'status_snapshot<=0;'
    capture = "status_snapshot<=operation==8'h96 ? {snapshot_result_status,snapshot_s1_status}:{768'd0,(operation==8'h95 ? geometry_status:(operation==8'h97 ? snapshot_geometry_status:control_status))};"
    text = replace_once(text, reset, '')
    text = replace_once(text, capture, '')
    block = '''
 // The final payload response precedes CHECK by exactly one edge. For the
 // one-byte status commands the incoming byte is the complete page number;
 // retain the collected-byte form too so the predecode states its semantics.
 wire status_operation=operation==8'h90 || operation==8'h95 || operation==8'h96 || operation==8'h97;
 wire last_status_page_zero=read_response && index==collect_length-1'b1 &&
  status_operation && ((index==0) ? read_data==0 : received[7:0]==0);
 // ADS guide 5.15: preserve just the eight intentionally local enable copies.
 // Reset clears copies and all payload pages, matching original cold/mid-job
 // behavior. No new UART, reply, snapshot or command state is introduced.
 reg [7:0] status_capture_page /* synthesis syn_preserve=1 */;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)status_capture_page<=0;
  else status_capture_page<={8{last_status_page_zero}};
 end
 wire [1535:0] status_capture_data=operation==8'h96 ? {snapshot_result_status,snapshot_s1_status}:
  {768'd0,(operation==8'h95 ? geometry_status:(operation==8'h97 ? snapshot_geometry_status:control_status))};
 genvar status_page;
 generate for(status_page=0;status_page<8;status_page=status_page+1)begin: local_status_page
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)status_snapshot[status_page*192+:192]<=0;
   else if(status_capture_page[status_page])
    status_snapshot[status_page*192+:192]<=status_capture_data[status_page*192+:192];
  end
 end endgenerate
'''
    return replace_once(text, 'endmodule', block+'endmodule')


def main():
    """Prepare a one-file, independently checkable full-source candidate."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    baseline = args.baseline.resolve()
    if not baseline.is_relative_to(fpga/'build'):
        raise ValueError('Frozen FPGA baseline required')
    before = json.loads((baseline/'sources.json').read_text(encoding='utf-8'))
    if len(before) != 290 or hashes(baseline/'source') != before:
        raise ValueError('Complete baseline source integrity failed')
    run = fpga/'build/route_optimization'/datetime.now().strftime('boot_local_capture_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline/'source', run/'source')
    name = 'rtl/control/pc_video_boot.sv'
    source = run/'source'/name
    shutil.copyfile(source, run/'original_pc_video_boot.sv')
    source.write_text(local_capture(source.read_text(encoding='utf-8')), encoding='utf-8')
    after = hashes(run/'source')
    if set(before) != set(after) or {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Only PC capture enables may differ')
    (run/'sources.json').write_text(json.dumps(after, indent=2)+'\n')
    (run/'preparation.json').write_text(json.dumps(dict(
        baseline=str(baseline), changed=[name], intended_added_cycles=0,
        intended_added_ff=8, resets_unchanged=True, functional_pass=False,
        physical_benefit_verified=False, routed=False, programmed=False,
        official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf section 5.15'), indent=2)+'\n')
    shutil.copyfile(__file__, run/'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

"""Compare constant-luma APM versus LUT mapping without changing live RTL.

ADS User Guide section 5.7 documents syn_dspstyle="logic" on operators/wires.
The three exact 16-bit products preserve arithmetic and cycle behavior. An
exhaustive RGB comparison precedes two identical registered-input SYN probes.
Unit synthesis is evidence for selection only, never board timing signoff.
"""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def main():
    """Keep source copies, the exact fixture, native logs and all failed results."""
    fpga = Path(__file__).resolve().parents[1]
    original = fpga / 'build/full_integration_20261013/delay_20261015_111425_510321/source/rtl/isp/rgb_frame_statistics.sv'
    root = fpga / 'build/full_integration_20261013' / datetime.now().strftime('statistics_logic_%Y%m%d_%H%M%S_%f')
    root.mkdir()
    shutil.copyfile(__file__, root / 'probe_script.py')
    before = original.read_text(encoding='utf-8')
    expression = " wire [15:0] luma_sum=16'd77*pixel_rgb[23:16]+16'd150*pixel_rgb[15:8]+16'd29*pixel_rgb[7:0]+16'd128;"
    replacement = ''' // Purpose: keep the constant-weight luma arithmetic in local LUT logic.
 // All products and the rounded sum fit 16 bits (maximum sum is 65408).
 // This changes only native mapping, not pixels, sampling or result latency.
 wire [15:0] weighted_r /* synthesis syn_dspstyle="logic" */ =16'd77*pixel_rgb[23:16];
 wire [15:0] weighted_g /* synthesis syn_dspstyle="logic" */ =16'd150*pixel_rgb[15:8];
 wire [15:0] weighted_b /* synthesis syn_dspstyle="logic" */ =16'd29*pixel_rgb[7:0];
 wire [15:0] luma_sum=weighted_r+weighted_g+weighted_b+16'd128;'''
    assert before.count(expression) == 1
    after = before.replace(expression, replacement)
    (root/'baseline.sv').write_text(before, encoding='utf-8')
    (root/'candidate.sv').write_text(after, encoding='utf-8')
    (root/'reference.sv').write_text(before.replace('module rgb_frame_statistics #',
        'module rgb_frame_statistics_reference #',1), encoding='utf-8')
    # Only combinational luma changes. Exhaust all 24-bit RGB values while
    # both original and candidate control state remains inactive in reset.
    tb = '''`timescale 1ns/1ps
module tb_luma_equivalence;
 reg [23:0] rgb; integer n;
 rgb_frame_statistics_reference old_dut(.clk(1'b0),.rst_n(1'b0),.pixel_rgb(rgb));
 rgb_frame_statistics new_dut(.clk(1'b0),.rst_n(1'b0),.pixel_rgb(rgb));
 initial begin
  for(n=0;n<16777216;n=n+1)begin
   rgb=n; #1;
   if(old_dut.luma_sum!==new_dut.luma_sum || old_dut.luma!==new_dut.luma)
    $fatal(1,"luma mismatch rgb=%h",rgb);
  end
  $display("PASS exhaustive_rgb=16777216 unchanged_luma_and_rounding"); $finish;
 end
endmodule
'''
    (root/'tb_luma_equivalence.sv').write_text(tb, encoding='utf-8')
    runtime = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(original=str(original), original_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),
                  candidate_sha256=hashlib.sha256((root/'candidate.sv').read_bytes()).hexdigest(),
                  live_modified=False, board_timing_signoff=False, runs=[])
    def execute(name, command, cwd):
        """Record every actual command; abort on failure before dependent work."""
        with (root/(name+'.log')).open('wb') as log:
            child=subprocess.run(command,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
        result['runs'].append(dict(name=name,exit=child.returncode,command=command))
        (root/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print(name, child.returncode, root, flush=True)
        if child.returncode: raise SystemExit(1)
    print('STATISTICS_MAPPING_PROBE',root,flush=True)
    execute('compile_equivalence',[str(runtime/'iverilog.exe'),'-g2012','-s','tb_luma_equivalence',
        '-o',str(root/'equivalence.vvp'),str(root/'reference.sv'),str(root/'candidate.sv'),
        str(root/'tb_luma_equivalence.sv')],root)
    execute('run_equivalence',[str(runtime/'vvp.exe'),str(root/'equivalence.vvp')],root)
    assert 'PASS exhaustive_rgb=16777216' in (root/'run_equivalence.log').read_text()
    result['exhaustive_rgb_pass']=True
    # The common RGB register models a registered upstream pixel source.
    # Fixed full-frame ROI and TAG_BITS=64/SUPPORT_ABORT=1 match the board.
    wrapper='''// Purpose: identical registered-input native timing probe for both mappings.
module statistics_mapping_probe(
 input clk,rst_n,frame_start,frame_abort,input [63:0] frame_tag,
 input pixel_valid,pixel_ready,pixel_mask,pixel_last,input [15:0] pixel_x,pixel_y,
 input [23:0] pixel_rgb,input result_ready,
 output result_valid,result_failed,rejected,output [63:0] result_tag,
 output [47:0] luminance_sum,output [31:0] samples,dark,saturated);
 reg [23:0] rgb_q;
 always @(posedge clk) rgb_q<=pixel_rgb;
 // Explicit ports are required by the installed ADS SystemVerilog parser.
 rgb_frame_statistics #(.TAG_BITS(64),.SUPPORT_ABORT(1)) dut(
  .clk(clk),.rst_n(rst_n),.frame_start(frame_start),.frame_abort(frame_abort),
  .frame_tag(frame_tag),.pixel_valid(pixel_valid),.pixel_ready(pixel_ready),
  .pixel_mask(pixel_mask),.pixel_last(pixel_last),.pixel_x(pixel_x),.pixel_y(pixel_y),
  .pixel_rgb(rgb_q),.roi_x(16'd0),.roi_y(16'd0),.roi_width(16'd1920),.roi_height(16'd1080),
  .result_ready(result_ready),.result_valid(result_valid),.result_failed(result_failed),
  .result_tag(result_tag),.luminance_sum(luminance_sum),.samples(samples),
  .dark(dark),.saturated(saturated),.rejected(rejected));
endmodule
'''
    for label in ('baseline','candidate'):
        build=root/label
        build.mkdir()
        shutil.copyfile(root/(label+'.sv'),build/'rgb_frame_statistics.sv')
        (build/'top.sv').write_text(wrapper,encoding='utf-8')
        (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n',encoding='ascii')
        flow=('# Purpose: SYN-only comparison; not a physical board implementation.\n'
              'set_dir -impl_directory {'+build.as_posix()+'}\n'
              'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
              'add_design {'+(build/'rgb_frame_statistics.sv').as_posix()+'}\n'
              'add_design {'+(build/'top.sv').as_posix()+'}\n'
              'add_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
              'compile -top_module statistics_mapping_probe -system_verilog\n'
              'synthesize -ads -rw_check_on_ram -resource_sharing false -fanout_guide 64 -selected_syn_tool_opt 2\n')
        (build/'flow.tcl').write_text(flow,encoding='utf-8')
        execute(label+'_syn',['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
            '-file',str(build/'flow.tcl'),'-work_dir',str(build)],build)
        errors=re.findall(r'^E:.*',(root/(label+'_syn.log')).read_text(errors='replace'),re.M)
        result[label+'_errors']=errors
        if errors: raise RuntimeError(errors)
    result['completed']=True
    result['original_intact']=hashlib.sha256(original.read_bytes()).hexdigest()==result['original_sha256']
    (root/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result),flush=True)


if __name__ == '__main__':
    main()

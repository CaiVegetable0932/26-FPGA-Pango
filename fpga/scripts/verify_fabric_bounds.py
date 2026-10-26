"""Exercise the actual old/new bound predicates on exhaustive boundary shapes.

This complements the transactional fabric bench, including generic small
capacities. Extracted source regions and hashes make the algebra check auditable.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def sha(p):
    """Bind evidence to source bytes rather than a candidate name."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    """Compare legal/reject decisions without creating native DDR transactions."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    a=parser.parse_args();candidate=a.candidate.resolve();fpga=Path(__file__).resolve().parents[1]
    identity=json.loads((candidate/'candidate.json').read_text());baseline=Path(identity['baseline'])
    run=candidate/datetime.now().strftime('bounds_%Y%m%d_%H%M%S_%f');run.mkdir()
    origins={}
    for label,root in [('old',baseline),('new',candidate)]:
        source=root/'source/rtl/memory/frame_memory_fabric.sv';original=source.read_text();origins[str(source)]=sha(source)
        start=original.index(' always @* begin\n  address_legal=0;')
        stop=original.index(' // Narrow client selectors',start)
        # Keep the exact executable predicate and all of its declared inputs.
        text='module bounds_'+label+''' #(parameter CAPACITY_BYTES=32'h40000000)(
 input [31:0] req_addr,input [4:0] req_beats,input [2:0] req_bank,req_owner,
 input [1:0] req_slot,input req_write,output reg address_legal);
 localparam N=1;integer c;
 reg [32:0] slot_base,slot_end,span_end;reg [31:0] slot_bytes;
'''+original[start:stop]+'endmodule\n'
        # Single-bit packed outputs must retain a range for the original [c].
        text=text.replace('output reg address_legal','output reg [0:0] address_legal')
        text=text.replace('input req_write','input [0:0] req_write')
        (run/(label+'.sv')).write_text(text)
    bench='''`timescale 1ns/1ps
// Boundaries, full request lengths, every bank/slot/owner/write encoding,
// and deterministic random addresses are compared at several capacities.
module tb_bounds;
 reg [31:0] req_addr;reg [4:0] req_beats;reg [2:0] req_bank,req_owner;
 reg [1:0] req_slot;reg req_write;wire [5:0] old_ok,new_ok;
 genvar g;generate for(g=0;g<6;g++)begin:capacity
  localparam C=g==0?32'h40000000:g==1?32'h03c00000:g==2?32'h01800101:
               g==3?32'h00000fff:g==4?32'hffffffff:32'h00000000;
  bounds_old #(.CAPACITY_BYTES(C)) a(.*,.address_legal(old_ok[g]));
  bounds_new #(.CAPACITY_BYTES(C)) b(.*,.address_legal(new_ok[g]));
 end endgenerate
 integer checks=0;reg [31:0] origin,delta,rng=32'h1845abc9;
 task test;begin #1;checks++;if(old_ok!==new_ok)
  $fatal(1,"BOUNDS_DIFF addr=%h beats=%0d bank=%0d slot=%0d owner=%0d wr=%0d old=%b new=%b",req_addr,req_beats,req_bank,req_slot,req_owner,req_write,old_ok,new_ok);
 end endtask
 initial begin
  for(integer edge_no=0;edge_no<16;edge_no++)begin
   case(edge_no)
    0:origin=0;1:origin='h00800000;2:origin='h01000000;3:origin='h01800000;
    4:origin='h02000000;5:origin='h02800000;6:origin='h03000000;7:origin='h03400000;
    8:origin='h03800000;9:origin='h03c00000;10:origin='h01800100;11:origin='h1000;
    12:origin='h01801000;13:origin='hffffffe0;14:origin='h80000000;15:origin='hffffffff;
   endcase
   for(integer offset_no=0;offset_no<7;offset_no++)begin
    case(offset_no)0:delta=0;1:delta=1;2:delta=-1;3:delta=-32;4:delta=-512;5:delta=32;6:delta=512;endcase
    req_addr=origin+delta;
    for(integer b=0;b<8;b++)for(integer s=0;s<4;s++)for(integer o=0;o<8;o++)
     for(integer w=0;w<2;w++)for(integer l=0;l<32;l++)begin
      req_bank=b;req_slot=s;req_owner=o;req_write=w;req_beats=l;test;
     end
   end
  end
  for(integer r=0;r<20000;r++)begin
   rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   req_addr=r%2?{6'b0,rng[25:5],5'b0}:rng;
   req_bank=rng[2:0];req_slot=rng[4:3];req_owner=rng[7:5];req_write=rng[8];req_beats=rng[13:9];test;
  end
  $display("BOUNDS_PASS descriptors=%0d capacities=6 decisions=%0d",checks,checks*6);$finish;
 end
endmodule
'''
    (run/'tb.sv').write_text(bench);shutil.copyfile(__file__,run/'verification_script.py')
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    frozen={p.name:sha(p) for p in run.iterdir() if p.is_file()}
    compile_cmd=[str(binary/'iverilog.exe'),'-g2012','-s','tb_bounds','-o',str(run/'unit.vvp')]+[str(run/n) for n in ('old.sv','new.sv','tb.sv')]
    result=dict(passed=False,origins=origins,frozen_files=frozen,commands=[compile_cmd])
    print('BOUNDS',run,flush=True)
    try:
        p=subprocess.run(compile_cmd,input=b'',capture_output=True,timeout=120,cwd=run);(run/'compile.log').write_bytes(p.stdout+p.stderr)
        if p.returncode:raise RuntimeError((p.stdout+p.stderr).decode(errors='replace'))
        cmd=[str(binary/'vvp.exe'),str(run/'unit.vvp')];result['commands'].append(cmd)
        p=subprocess.run(cmd,input=b'',capture_output=True,timeout=600,cwd=run);(run/'run.log').write_bytes(p.stdout+p.stderr)
        result['passed']=p.returncode==0 and b'BOUNDS_PASS' in p.stdout
        print((p.stdout+p.stderr).decode(errors='replace'),flush=True)
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()

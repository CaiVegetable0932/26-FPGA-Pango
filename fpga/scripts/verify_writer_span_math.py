"""Check actual frozen span expressions over all heights and four-state inputs."""
import argparse
from datetime import datetime
import hashlib,json,re,shutil,subprocess
from pathlib import Path


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):raise ValueError('Frozen candidate required')
    run=candidate/datetime.now().strftime('span_math_%Y%m%d_%H%M%S_%f');run.mkdir()
    paths=[candidate/'original_frame_pixel_writer.sv',candidate/'source/rtl/memory/frame_pixel_writer.sv']
    inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in paths}
    original=paths[0].read_text(encoding='utf-8');current=paths[1].read_text(encoding='utf-8')
    golden=re.search(r' wire \[63:0\] span_end=.*?;',original,re.S)[0].replace('span_end','original_span')
    changed=re.search(r' wire signed \[16:0\] preceding_rows=.*?wire \[63:0\] span_end=.*?;',current,re.S)[0]
    for old,new in [('span_end','candidate_span'),('row_span','candidate_row_span'),('preceding_rows','candidate_preceding_rows')]:
        changed=re.sub(r'\b'+old+r'\b',new,changed)
    # This is the full signed product width, not truncation based on accepted
    # image bounds: every 16-bit height, including zero, and 32-bit stride fits.
    minimum=-(2**32-1);maximum=(2**16-2)*(2**32-1)
    assert -(2**49)<=minimum<=maximum<2**49
    tb='''`timescale 1ns/1ps
module span_tb;
 reg [96:0] controls=0;
 wire [31:0] frame_base,frame_stride;
 wire [15:0] frame_height,frame_width;wire frame_rgb888;
 assign {frame_base,frame_stride,frame_height,frame_width,frame_rgb888}=controls;
'''+golden+'\n'+changed+'''
 reg [31:0] strides[0:5];reg [31:0] base_value;reg [96:0] known;
 integer h,j,k,checks=0,seed=177;
 task check;begin #1;
  checks=checks+1;
  if(original_span !== candidate_span)
   $fatal(1,"SPAN_MATH_DIFF controls=%h reference=%h candidate=%h",controls,original_span,candidate_span);
 end endtask
 initial begin
  strides[0]=0;strides[1]=1;strides[2]=31;strides[3]=32;strides[4]=6144;strides[5]=32'hffffffff;
  for(h=0;h<65536;h=h+1)for(j=0;j<6;j=j+1)begin
   base_value=(j==0)?0:((j==5)?32'hffffffff:$random(seed));
   controls={base_value,strides[j],16'(h),16'(h*17),1'(h&1)};check;
  end
  for(k=0;k<20000;k=k+1)begin
   controls={$random(seed),$random(seed),16'($random(seed)),16'($random(seed)),1'($random(seed))};check;
  end
  for(j=0;j<3;j=j+1)begin
   known=(j==0)?97'd0:((j==1)?{97{1'b1}}:{32'hfffff000,32'd6144,16'd1080,16'd1920,1'b1});
   for(k=0;k<97;k=k+1)begin
    controls=known;controls[k]=1'bx;check;
    controls=known;controls[k]=1'bz;check;
   end
  end
  $display("SPAN_MATH_PASS checks=%0d",checks);$finish;
 end
endmodule
'''
    (run/'span_tb.sv').write_text(tb,encoding='utf-8');shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,inputs=inputs,full_height_sweep=True,four_state=True,
        minimum_signed_product=minimum,maximum_signed_product=maximum,full_product_bits=50,final_span_bits=64)
    try:
        for phase,command in [('compile',[str(tool/'iverilog.exe'),'-g2012','-s','span_tb','-o','span_tb.vvp','span_tb.sv']),
                               ('run',[str(tool/'vvp.exe'),'span_tb.vvp'])]:
            p=subprocess.run(command,cwd=run,capture_output=True,timeout=120)
            output=p.stdout+p.stderr;(run/(phase+'.log')).write_bytes(output)
            if p.returncode:raise RuntimeError(output.decode(errors='replace')[-1800:])
        match=re.search(rb'SPAN_MATH_PASS checks=(\d+)',output)
        assert match and int(match[1])==413798
        result.update(passed=True,checks=int(match[1]))
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
        print('SPAN_MATH_RESULT',run,result['passed'],flush=True)
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()

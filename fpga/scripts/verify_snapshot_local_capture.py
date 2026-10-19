"""Compare same-edge snapshot metadata capture, including inactive payloads."""
import argparse
from datetime import datetime
import hashlib,json,re,shutil,subprocess
from pathlib import Path


def fixture():
    inputs={'clk':1,'rst_n':1,'start':1,'cancel':1,'source_slot':2,'result_slot':2,
        'source_gen':32,'result_gen':32,'s1_gen':32,'dst_gen':32,'req_ready':1,'w_ready':1,
        'r_valid':1,'r_data':256,'dma_done':1,'dma_error':1,'dma_cancelled':1,'done_tag':32}
    outputs={'ready':1,'done':1,'failed':1,'drained':1,'req_valid':1,'req_write':1,'req_addr':32,
        'req_tag':32,'req_bank':3,'req_owner':3,'req_slot':2,'req_generation':32,
        'w_valid':1,'w_data':256,'w_strb':32,'r_ready':1,'dma_done_ready':1,'dma_cancel':1}
    text='`timescale 1ns/1ps\nmodule snapshot_tb;\n parameter WIDTH=33,HEIGHT=2;\n'
    for name,width in inputs.items():
        text+=' reg '+(f'[{width-1}:0] ' if width>1 else '')+name+'=0;\n'
    for prefix in ['', 'ref_']:
        for name,width in outputs.items():
            text+=' wire '+(f'[{width-1}:0] ' if width>1 else '')+prefix+name+';\n'
    for module,instance,prefix in [('snapshot_copy_dma','reference_impl','ref_'),
                                   ('snapshot_copy_candidate','candidate_impl','')]:
        ports=['.'+n+'('+n+')' for n in inputs]+['.'+n+'('+prefix+n+')' for n in outputs]
        text+=module+' #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) '+instance+'('+','.join(ports)+');\n'
    concat=','.join(outputs)
    ref_concat=','.join('ref_'+n for n in outputs)
    text+=''' integer seed=177,cycle,word_index,checks=0,completed=0;
 always #5 clk=~clk;
 always @(posedge clk)begin #2;
  if(rst_n)begin
   checks=checks+1;
'''
    text+='   if({'+concat+'} !== {'+ref_concat+'})$fatal(1,"SNAPSHOT_CAPTURE_DIFF all public bits");\n'
    text+='''   if(candidate_impl.local_idle !== {6{ref_ready}})
    $fatal(1,"SNAPSHOT_CAPTURE_DIFF same-edge idle flags");
   if({candidate_impl.ss,candidate_impl.rs,candidate_impl.sg,candidate_impl.rg,candidate_impl.dsg,candidate_impl.drg}
      !== {reference_impl.ss,reference_impl.rs,reference_impl.sg,reference_impl.rg,reference_impl.dsg,reference_impl.drg})
    $fatal(1,"SNAPSHOT_CAPTURE_DIFF inactive metadata");
   if(done)completed=completed+1;
  end
 end
 initial begin
  if($value$plusargs("SEED=%d",seed))begin end
  repeat(3)@(negedge clk);rst_n=1;
  for(cycle=0;cycle<40000;cycle=cycle+1)begin
   @(negedge clk);
   source_slot=$random(seed);result_slot=$random(seed);
   source_gen=$random(seed);result_gen=$random(seed);s1_gen=$random(seed);dst_gen=$random(seed);
   for(word_index=0;word_index<8;word_index=word_index+1)r_data[word_index*32+:32]=$random(seed);
   // First complete real two-image copies under an independent always-ready
   // backend, then inject stalls, early/error ACKs, cancel and cold resets.
   if(cycle<3000)begin
    start=ref_ready;cancel=0;req_ready=1;w_ready=1;r_valid=ref_r_ready;
    dma_done=ref_dma_done_ready;dma_error=0;dma_cancelled=0;done_tag=ref_req_tag;
   end else begin
    start=($random(seed)&3)==0;cancel=($random(seed)&31)==0;
    req_ready=($random(seed)&3)!=0;w_ready=($random(seed)&3)!=0;r_valid=($random(seed)&1)!=0;
    dma_done=ref_dma_done_ready && (($random(seed)&7)==0);
    dma_error=($random(seed)&63)==0;dma_cancelled=($random(seed)&63)==0;
    done_tag=(($random(seed)&15)==0)?$random(seed):ref_req_tag;
    rst_n=(cycle%601)!=0;
   end
  end
  @(negedge clk);rst_n=1;start=0;cancel=0;repeat(3)@(negedge clk);
  if(checks<39000 || completed<1)$fatal(1,"SNAPSHOT_CAPTURE_DIFF insufficient coverage");
  $display("SNAPSHOT_CAPTURE_PASS checks=%0d completions=%0d",checks,completed);$finish;
 end
endmodule
'''
    return text


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):raise ValueError('Frozen candidate required')
    run=candidate/datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f');run.mkdir()
    files={'original.sv':candidate/'original_snapshot_copy_dma.sv',
           'candidate.sv':candidate/'source/rtl/memory/snapshot_copy_dma.sv'}
    inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files.values()}
    for n,p in files.items():shutil.copyfile(p,run/n)
    p=run/'candidate.sv';text=p.read_text(encoding='utf-8');assert text.count('module snapshot_copy_dma #(')==1
    p.write_text(text.replace('module snapshot_copy_dma #(','module snapshot_copy_candidate #('),encoding='utf-8')
    (run/'snapshot_tb.sv').write_text(fixture(),encoding='utf-8');shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,inputs=inputs,all_public_bits_compared=True,inactive_metadata_compared=True,
                same_edge_idle_invariant=True,four_state=True,tests=[])
    try:
        for width,height in [(1,2),(10,2),(11,2),(32,2),(33,2),(1920,1)]:
            for seed in [177,2718]:
                name=f'{width}_{height}_{seed}'
                commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-s','snapshot_tb',
                    '-Psnapshot_tb.WIDTH='+str(width),'-Psnapshot_tb.HEIGHT='+str(height),'-o',name+'.vvp',
                    'original.sv','candidate.sv','snapshot_tb.sv']),
                    ('run',[str(tool/'vvp.exe'),name+'.vvp','+SEED='+str(seed)])]
                for phase,command in commands:
                    p=subprocess.run(command,cwd=run,capture_output=True,timeout=120)
                    output=p.stdout+p.stderr;(run/(name+'_'+phase+'.log')).write_bytes(output)
                    if p.returncode:raise RuntimeError(name+' '+phase+': '+output.decode(errors='replace')[-1600:])
                match=re.search(rb'SNAPSHOT_CAPTURE_PASS checks=(\d+) completions=(\d+)',output)
                if not match:raise ValueError('Missing independent completion marker')
                result['tests'].append(dict(width=width,height=height,seed=seed,checks=int(match[1]),completions=int(match[2])))
                print(name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
        print('SNAPSHOT_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()

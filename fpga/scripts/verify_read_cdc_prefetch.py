"""Byte/stall/last/reset and continuous-output checks for isolated read CDC."""
from pathlib import Path
from datetime import datetime
import hashlib,json,shutil,subprocess
from prepare_read_cdc_prefetch import prefetch

def main():
    fpga=Path(__file__).resolve().parents[1]
    original=fpga/'rtl/memory/dma_read_cdc.sv';candidate=fpga/'experiments/proc150/rtl/dma_read_cdc_prefetch.sv'
    if candidate.read_text(encoding='utf-8')!=prefetch(original.read_text(encoding='utf-8')):raise ValueError('Transformation drift')
    fixture=fpga/'sim/tb_dma_read_cdc.sv'
    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_read_prefetch_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(candidate,run/candidate.name);shutil.copyfile(fixture,run/'original_tb.sv');shutil.copyfile(original,run/'original.sv')
    shutil.copyfile(__file__,run/'verification_script.py')
    text=fixture.read_text(encoding='utf-8').replace('dma_read_cdc dut(.*);','dma_read_cdc_prefetch dut(.*);')
    text=text.replace('module tb_dma_read_cdc;','module tb_dma_read_cdc;\n parameter real CLIENT_HALF=3.333,MEMORY_HALF=4.0,MEMORY_PHASE=0.7;\n parameter CONTIGUOUS=0;')
    text=text.replace('always #6.7 if(client_running)','always #CLIENT_HALF if(client_running)')
    text=text.replace('always #4 memory_clk=~memory_clk;','initial begin #MEMORY_PHASE;forever #MEMORY_HALF memory_clk=~memory_clk;end')
    text=text.replace('always @(negedge client_clk)r_ready=cycles%5!=0;','always @(negedge client_clk)r_ready=CONTIGUOUS || cycles%5!=0;')
    anchor='always @(posedge client_clk)if(client_rst_n && r_valid && r_ready)begin'
    if text.count(anchor)!=1:raise ValueError('Unexpected scoreboard')
    text=text.replace(anchor,'''// Throughput is checked independently after the first consumed beat.
 always @(posedge client_clk)if(client_rst_n && CONTIGUOUS && received>0 && received<count && !cancel && !r_valid)
  $fatal(1,"Read CDC inserted a bubble in a fully buffered burst");
 reg stalled=0;reg [255:0] held_data;reg held_last;
 always @(posedge client_clk)begin
  if(client_rst_n && stalled && !cancel && (!r_valid || r_data!==held_data || r_last!==held_last))
   $fatal(1,"Read CDC changed a stalled beat");
  stalled=client_rst_n && r_valid && !r_ready;held_data=r_data;held_last=r_last;
 end
 '''+anchor)
    (run/'tb.sv').write_text(text,encoding='utf-8',newline='\n')
    inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in [original,candidate,fixture]}
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,inputs=inputs,cycle_equivalent=False,production_changed=False,independent_byte_scoreboard=True,tests=[])
    try:
        for ch,mh,phase in [(3.333,4,.7),(4,3.333,1.1),(5,3.1,0),(3.333,4,3.9)]:
            for contiguous in [0,1]:
                name=f'c{ch}_m{mh}_p{phase}_continuous{contiguous}'
                cmds=[('compile',[str(tool/'iverilog.exe'),'-g2012','-s','tb_dma_read_cdc',
                    '-Ptb_dma_read_cdc.CLIENT_HALF='+str(ch),'-Ptb_dma_read_cdc.MEMORY_HALF='+str(mh),
                    '-Ptb_dma_read_cdc.MEMORY_PHASE='+str(phase),'-Ptb_dma_read_cdc.CONTIGUOUS='+str(contiguous),
                    '-o',name+'.vvp','tb.sv',candidate.name]),('run',[str(tool/'vvp.exe'),name+'.vvp'])]
                for stage,cmd in cmds:
                    p=subprocess.run(cmd,cwd=run,capture_output=True,timeout=120);output=p.stdout+p.stderr
                    (run/(name+'_'+stage+'.log')).write_bytes(output)
                    if p.returncode:raise RuntimeError(output.decode(errors='replace'))
                if b'DMA_READ_CDC_PASS' not in output:raise ValueError('Missing independent scoreboard result')
                result['tests'].append(dict(client_half_ns=ch,memory_half_ns=mh,phase_ns=phase,continuous=bool(contiguous),passed=True))
                print(name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2));print('READ_CDC_PREFETCH_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)

if __name__=='__main__':main()

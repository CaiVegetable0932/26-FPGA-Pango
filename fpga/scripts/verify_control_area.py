"""Compare control-area candidates against B3 across time and queue boundaries."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from regional_scan_wrapper import ports


def sha(p):
    """Bind all behavioral claims to frozen source inputs."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def peer(module,instance,original,parameters=''):
    """Compare every public output, including valid timing and reset values."""
    # Peer wiring preserves bits; signedness remains in the original modules.
    port_list=ports(re.sub(r'\bsigned\s+','',original),module,{})
    code='\n'+module+'_baseline '+parameters+' reference_'+instance+'('+','.join('.'+n+'('+instance+'.'+n+')' for d,n,w in port_list if d=='input')+');\n'
    code+='integer checks_'+instance+'=0;always @(posedge clk)begin #1;if('+instance+'.rst_n)begin checks_'+instance+'++;\n'
    for d,n,w in port_list:
        if d=='output':code+='if('+instance+'.'+n+' !== reference_'+instance+'.'+n+')$fatal(1,"CONTROL_AREA_DIFF '+module+'.'+n+'");\n'
    return code+'end end\n final $display("CONTROL_AREA_CHECKED '+module+' cycles=%0d",checks_'+instance+');\n'


def random_selector(original):
    """Exercise non-power-of-two rings, modular time arithmetic and clear/reset."""
    port_list=ports(re.sub(r'\bsigned\s+','',original),'pose_frame_selector',{})
    text='`timescale 1ns/1ps\nmodule tb_selector_area #(parameter DEPTH=32);\n'
    for d,n,w in port_list:
        if d=='input':text+='reg '+('['+str(w-1)+':0] ' if w>1 else '')+n+'=0;\n'
    text+='always #4 clk=~clk;\npose_frame_selector #(.DEPTH(DEPTH)) dut('+','.join('.'+n+'('+n+')' for d,n,w in port_list if d=='input')+');\n'
    text+=peer('pose_frame_selector','dut',original,'#(.DEPTH(DEPTH))')
    text+='''integer results=0;reg [31:0] rng=32'h71a9b309;
 always @(posedge clk)if(rst_n && dut.result_valid && result_ready)results++;
 initial begin
  repeat(3)@(negedge clk);rst_n=1;mapping_valid=1;clock_error_us=100;result_ready=1;
  for(integer n=0;n<12000;n++)begin
   @(negedge clk);rng=rng^(rng<<13);rng=rng^(rng>>17);rng=rng^(rng<<5);
   rst_n=n%1601!=1600;clear=n%777==776;state_valid=n%2==0;
   // A legal encoder-only STATE keeps the full time/source layout. Inject
   // invalid source flags separately to verify rejection counters as well.
   state_payload=0;state_payload[96+:32]=1;state_payload[160+:32]='hd8;
   state_payload[728+:8]=5;state_payload[736+:8]=3;state_payload[744+:8]=3;
   if(n%19==18)state_payload[728+:2]=3;
   receive_us=(n%7==0?64'hffffffffffff0000:64'd1000000)+n;
   state_payload[480+:64]=receive_us;
   frame_valid=n%200==199;epoch=7;frame_id=n;exposure_us=receive_us+100;
   clock_offset_us=n%3==0?-64'sd100:n%3==1?64'd100:64'h7fffffffffffffff;
   sync_received_us=exposure_us+(n%11==0?-64'd2000001:64'd1000);
   clock_error_us=n%13==0?32'hffffffff:32'd100;mapping_valid=n%17!=0;result_ready=rng[0];
  end
  @(negedge clk);state_valid=0;frame_valid=0;clear=0;rst_n=1;result_ready=1;
  repeat(200)@(negedge clk);
  if(results<20)$fatal(1,"selector coverage results=%0d",results);
  $display("SELECTOR_AREA_PASS depth=%0d results=%0d",DEPTH,results);$finish;
 end
endmodule
'''
    return text


def main():
    """Keep independent directed oracles and add a broad baseline comparison."""
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--candidate',type=Path,required=True)
    a=parser.parse_args();candidate=a.candidate.resolve();fpga=Path(__file__).resolve().parents[1]
    identity=json.loads((candidate/'candidate.json').read_text());base=Path(identity['baseline'])
    hashes=json.loads((candidate/'sources.json').read_text());assert all(sha(candidate/'source'/n)==h for n,h in hashes.items())
    run=candidate/datetime.now().strftime('software_%Y%m%d_%H%M%S_%f');source=run/'source';source.mkdir(parents=True)
    origins={};originals={}
    # Keep this unit closure independent of board/package-only controllers.
    for name in ('pose_frame_selector.sv','mcu_readonly_client.sv','uart_v2_parser.sv','frame_parameter_bank.sv'):
        p=candidate/'source/rtl/control'/name
        shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
    for module in ('pose_frame_selector','mcu_readonly_client'):
        p=base/'source/rtl/control'/(module+'.sv');originals[module]=p.read_text();origins[str(p)]=sha(p)
        (source/(module+'_baseline.sv')).write_text(re.sub(r'\bmodule '+module+r'\b','module '+module+'_baseline',p.read_text(),count=1))
    cases=[('tb_control_services',{}),('tb_mcu_readonly_client',{})]+[('tb_selector_area',{'DEPTH':d}) for d in (1,3,32,33)]
    for top,module,instance in [('tb_control_services','pose_frame_selector','selector'),('tb_mcu_readonly_client','mcu_readonly_client','dut')]:
        p=fpga/'sim'/(top+'.sv');text=p.read_text();origins[str(p)]=sha(p)
        match=re.search(r'\b'+module+r'\s*(#\(.*?\))?\s*'+instance+r'\(.*?\);',text,re.S)
        assert match
        text=text[:match.end()]+peer(module,instance,originals[module],match[1] or '')+text[match.end():]
        (source/p.name).write_text(text)
    if identity['variant']=='private_payload':
        # Exercise the real bank's publication/version oracle, then cold-reset
        # a pending legal body before any capture may expose the stale payload.
        module='motion_config_bank';p=candidate/'source/rtl/stabilization'/(module+'.sv')
        shutil.copyfile(p,source/p.name);origins[str(p)]=sha(p)
        old=base/'source/rtl/stabilization'/p.name;origins[str(old)]=sha(old)
        (source/(module+'_baseline.sv')).write_text(re.sub(r'\bmodule '+module+r'\b','module '+module+'_baseline',old.read_text(),count=1))
        fixture=fpga/'sim/tb_motion_config.sv';origins[str(fixture)]=sha(fixture);text=fixture.read_text()
        match=re.search(r'\bmotion_config_bank\s+dut\(.*?\);',text,re.S);assert match
        text=text[:match.end()]+peer(module,'dut',old.read_text())+text[match.end():]
        text=text.replace('  $display("PASS C4/C5', '''  // Reset revokes pending ownership without requiring private payload reset.
  kind=8;read_kind=8;version=4;body=valid_pose;
  @(negedge clk);submit=1;@(negedge clk);submit=0;rst_n=0;
  repeat(2)@(negedge clk);rst_n=1;boundary=1;
  @(negedge clk);boundary=0;
  if(pose_current!=0 || status[63:32]!=0 || status[113])$fatal(1,"stale pending payload escaped reset");
  $display("PASS C4/C5''')
        (source/'tb_motion_config.sv').write_text(text);cases.append(('tb_motion_config',{}))
    (source/'tb_selector_area.sv').write_text(random_selector(originals['pose_frame_selector']))
    for p in (fpga/'sim/vectors/network_control').glob('*.hex'):
        shutil.copyfile(p,run/p.name);origins[str(p)]=sha(p)
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.relative_to(run).as_posix():sha(p) for p in run.rglob('*') if p.is_file()}
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,origins=origins,frozen_files=frozen,cases=[],hardware_tested=False)
    print('CONTROL_AREA',run,flush=True)
    try:
        for top,params in cases:
            label=top+('_'+str(params['DEPTH']) if params else '')
            commands=[[str(binary/'iverilog.exe'),'-g2012','-s',top,'-o',str(run/(label+'.vvp'))]+
                      ['-P'+top+'.'+n+'='+str(v) for n,v in params.items()]+[str(p) for p in source.glob('*.sv')],
                      [str(binary/'vvp.exe'),str(run/(label+'.vvp'))]]
            entry=dict(test=top,parameters=params,passed=False,commands=commands);result['cases'].append(entry)
            for phase,cmd in zip(['compile','run'],commands):
                p=subprocess.run(cmd,input=b'',capture_output=True,timeout=180,cwd=run);out=p.stdout+p.stderr
                (run/(label+'.'+phase+'.log')).write_bytes(out)
                if p.returncode:raise RuntimeError(out.decode(errors='replace')[-2500:])
            if b'PASS' not in out or b'CONTROL_AREA_CHECKED' not in out or b'FATAL' in out:raise RuntimeError('Incomplete oracle')
            entry.update(passed=True,summary=out.decode(errors='replace'));print(label,entry['summary'][-400:],flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(n))==h for n,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()

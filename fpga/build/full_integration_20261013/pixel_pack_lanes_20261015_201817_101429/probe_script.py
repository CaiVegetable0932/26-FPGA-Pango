"""Measure fixed-byte write decoding without changing the packer's handshake.

Keep the complete 35-byte reservoir, including inactive bytes and reset values.
An independent original instance is compared every cycle across all offsets,
RAW/RGB, simultaneous drain/append, random stalls and mid-stream reset. Native
unit SYN follows the installed ADS 2022.2-SP6.4 flow; it is not board signoff.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Freeze one isolated candidate and keep all comparison evidence."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):raise ValueError('Frozen FPGA build required')
    original_hashes=json.loads((base/'sources.json').read_text())
    if hashes(base/'source')!=original_hashes:raise ValueError('Baseline changed')
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('pixel_pack_lanes_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name='rtl/memory/dma_pixel_pack.v';source=run/'source'/name
    old=source.read_text()
    start=old.index(' // Purpose: remove a beat')
    end=old.index(' always @(posedge clk',start)
    # Decode each byte once from the pre-append cursor. This avoids ADS having
    # to lower three dependent variable part-select read/modify/write updates.
    block=''' // Purpose: drain and append on the original edge with fixed byte
 // lanes. The pre-append cursor is bounded to 0..31 when accepting a pixel;
 // 35 storage lanes still preserve the two/three-byte RGB overflow payload.
 wire take_beat=beat_valid && beat_ready;
 wire take_pixel=pixel_valid && pixel_ready;
 wire [5:0] append_at=take_beat ? ((count>=32)?count-6'd32:6'd0) : count;
 integer lane;
 always @* begin
  bytes_next=take_beat ? (bytes_q>>256) : bytes_q;
  mask_next=take_beat ? (mask_q>>32) : mask_q;
  count_next=append_at;
  for(lane=0;lane<35;lane=lane+1)begin
   if(take_pixel && append_at==lane)begin
    bytes_next[lane*8+:8]=pixel[7:0];mask_next[lane]=1;
   end
   if(take_pixel && mode && append_at+6'd1==lane)begin
    bytes_next[lane*8+:8]=pixel[15:8];mask_next[lane]=1;
   end
   if(take_pixel && mode && append_at+6'd2==lane)begin
    bytes_next[lane*8+:8]=pixel[23:16];mask_next[lane]=1;
   end
  end
  if(take_pixel)count_next=append_at+(mode?6'd3:6'd1);
 end
'''
    source.write_text(old[:start]+block+old[end:])
    (run/'original_dma_pixel_pack.v').write_text(old)
    current=hashes(run/'source')
    if {n for n in current if current[n]!=original_hashes[n]}!={name}:raise ValueError('Unexpected change')
    (run/'sources.json').write_text(json.dumps(current,indent=2))
    shutil.copyfile(__file__,run/'probe_script.py')
    fixture=fpga/'sim/tb_dma_pixel_pack_differential.sv'
    shutil.copyfile(fixture,run/fixture.name)
    (run/'baseline_pack.v').write_text(old.replace('module dma_pixel_pack(','module baseline_pack(',1))
    result=dict(passed=False,cycle_equivalent=False,board_timing_signoff=False,baseline=str(base),jobs=[],
        inputs={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in (source,run/'original_dma_pixel_pack.v',fixture)})
    print('PIXEL_PACK_PROBE',run,flush=True)
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'

    def execute(label,command,cwd):
        """Persist native failures and never treat a missing marker as success."""
        with (cwd/(label+'.log')).open('wb') as log:
            child=subprocess.run(command,cwd=cwd,stdout=log,stderr=subprocess.STDOUT,creationflags=0x08000000)
        text=(cwd/(label+'.log')).read_text(errors='replace')
        errors=re.findall(r'^E:.*',text,re.M)
        result['jobs'].append(dict(name=label,exit=child.returncode,errors=errors))
        if child.returncode or errors:raise RuntimeError(label+': '+text[-1500:])
        return text

    try:
        image=run/'compare.vvp'
        execute('compile',[str(tool/'iverilog.exe'),'-g2012','-s','tb_dma_pixel_pack_differential','-o',str(image),
            str(source),str(run/'baseline_pack.v'),str(run/fixture.name)],run)
        for seed in (42,177,2718):
            text=execute('seed_'+str(seed),[str(tool/'vvp.exe'),str(image),'+SEED='+str(seed)],run)
            if 'PIXEL_PACK_DIFFERENTIAL_PASS' not in text:raise ValueError('Missing differential PASS')
            print(text.strip(),flush=True)
        for label,rtl in [('baseline',old),('candidate',source.read_text())]:
            build=run/label;build.mkdir();(build/'pack.v').write_text(rtl)
            (build/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+build.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow+='add_design {'+(build/'pack.v').as_posix()+'}\nadd_constraint {'+(build/'clock.fdc').as_posix()+'}\n'
            flow+='compile -top_module dma_pixel_pack -system_verilog\nsynthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (build/'flow.tcl').write_text(flow)
            execute('syn',['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(build/'flow.tcl'),'-work_dir',str(build)],build)
            report=(build/'synthesize/dma_pixel_pack.snr').read_text(errors='replace')
            resources={k:int(re.search(p,report)[1]) for k,p in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),('controlsets',r'Number of unique control sets : (\d+)')]}
            result[label+'_resources']=resources;print(label,resources,flush=True)
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in result['inputs'].items())
        if not result['inputs_intact']:raise ValueError('Comparison input changed')
        result.update(passed=True,cycle_equivalent=True)
    finally:
        (run/'result.json').write_text(json.dumps(result,indent=2));print('RESULT',run,flush=True)


if __name__=='__main__':main()

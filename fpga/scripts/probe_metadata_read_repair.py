"""Measure a shared metadata candidate after latency-aware smoke checks.

The snapshot fixture waits at most eight cycles for requested ACQUIRE ACKs;
all payload, drain, reference and error assertions stay intact. The independent
pressure scoreboard already observes accepted operations, not fixed latency.
This bounded smoke plus unit SYN is not complete integration/release evidence.
Installed ADS guide pp93-95 documents block_ram and synchronous read inference.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
from prepare_address_timing_repair import hashes,replace_once


def main():
    """Compare unchanged original/candidate bytes with identical native options."""
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate',type=Path,required=True)
    p.add_argument('--compare-valid-descriptors',action='store_true',
                   help='Compare two independent synchronized banks each cycle, masking only inactive metadata lanes')
    args=p.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    candidate=args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build') or hashes(candidate/'source')!=json.loads((candidate/'sources.json').read_text()):
        raise ValueError('Candidate identity mismatch')
    run=candidate/datetime.now().strftime('metadata_probe_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__,run/'probe_script.py')
    runtime=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,functional_smoke=False,board_timing_signoff=False,jobs=[],inputs={})
    def copy(origin,dest):
        """Hash both RTL and original fixtures before any explicit adaptation."""
        result['inputs'][str(origin)]=hashlib.sha256(origin.read_bytes()).hexdigest()
        shutil.copyfile(origin,dest)
    def execute(label,command,cwd,timeout=600):
        """Record every command/output, including a naturally failing probe."""
        log=run/(label+'.log')
        with log.open('wb') as f:
            child=subprocess.run(command,cwd=cwd,stdout=f,stderr=subprocess.STDOUT,timeout=timeout,creationflags=0x08000000)
        content=log.read_text(errors='replace')
        errors=re.findall(r'^E:.*',content,re.M)
        job=dict(name=label,exit=child.returncode,errors=errors,command=command)
        result['jobs'].append(job)
        print(label,child.returncode,flush=True)
        if child.returncode or errors or 'FATAL' in content:
            raise RuntimeError(label+' failed; see '+str(log))
        return content
    print('METADATA_PROBE',run,flush=True)
    try:
        sim=run/'sim';sim.mkdir()
        for name in ('frame_manager_pkg.sv','frame_manager_layout.vh','frame_pool_bank.sv','frame_manager.sv',):
            copy(candidate/'source/rtl/memory'/name,sim/name)
        fixture_names=['tb_frame_manager_pressure.sv']
        if args.compare_valid_descriptors:
            fixture_names.append('tb_frame_metadata_read.sv')
            # Each bank receives the same commands but owns independent state.
            # Normalize only an unqualified consumer's metadata word. All ACKs,
            # slots, generations, telemetry and valid descriptor bits must match.
            current=(sim/'frame_pool_bank.sv').read_text()
            copy(candidate/'original_frame_pool_bank.sv',sim/'reference_input.sv')
            previous=(sim/'reference_input.sv').read_text()
            start=current.index('module frame_pool_bank #(')
            header=current[start:current.index(' import frame_manager_pkg::*;',start)].replace('output reg ','output wire ')
            body='''
 wire [`FM_RSP_BITS-1:0] reference_rsp;
 frame_pool_bank_candidate #(.SLOTS(SLOTS),.BASE(BASE),.SLOT_BYTES(SLOT_BYTES),.TXNS(TXNS),.STRIDE(STRIDE))
  candidate_bank(clk,reset_n,fabric_ready,display_boundary,cmd,rsp);
 frame_pool_bank_reference #(.SLOTS(SLOTS),.BASE(BASE),.SLOT_BYTES(SLOT_BYTES),.TXNS(TXNS),.STRIDE(STRIDE))
  reference_bank(clk,reset_n,fabric_ready,display_boundary,cmd,reference_rsp);
 wire [3:0] observed_ack=rsp[`FM_RSP_ACQUIRE_OK];
 reg [`FM_RSP_BITS-1:0] actual_normalized,reference_normalized;
 reg [4*`FM_META_BITS-1:0] actual_metadata,reference_metadata;
 integer consumer_index,compared_cycles=0;
 always @(negedge clk)begin #2;
  if(reset_n)begin
   compared_cycles=compared_cycles+1;
   actual_normalized=rsp;reference_normalized=reference_rsp;
   actual_metadata=rsp[`FM_RSP_ACQUIRE_META];reference_metadata=reference_rsp[`FM_RSP_ACQUIRE_META];
   if(observed_ack==0 && actual_metadata!=='0)$fatal(1,"BANK_DIFFERENTIAL no-ACK payload is not zero");
   for(consumer_index=0;consumer_index<4;consumer_index=consumer_index+1)
    if(!observed_ack[consumer_index])begin
     actual_metadata[consumer_index*`FM_META_BITS+:`FM_META_BITS]=0;
     reference_metadata[consumer_index*`FM_META_BITS+:`FM_META_BITS]=0;
    end
   actual_normalized[`FM_RSP_ACQUIRE_META]=actual_metadata;
   reference_normalized[`FM_RSP_ACQUIRE_META]=reference_metadata;
   if(actual_normalized!==reference_normalized)$fatal(1,"BANK_DIFFERENTIAL control or valid descriptor differs");
  end
 end
 final $display("BANK_DIFFERENTIAL_CYCLES %0d",compared_cycles);
endmodule
'''
            (sim/'frame_pool_bank.sv').write_text('`timescale 1ns/1ps\n`include "frame_manager_layout.vh"\n'+header+body+'\n'+
                current.replace('module frame_pool_bank #(','module frame_pool_bank_candidate #(',1)+'\n'+
                previous.replace('module frame_pool_bank #(','module frame_pool_bank_reference #(',1))
        for name in fixture_names:
            copy(fpga/'sim'/name,sim/name)
        for top in [Path(n).stem for n in fixture_names]:
            image=sim/(top+'.vvp')
            sources=[str(sim/n) for n in ('frame_manager_pkg.sv','frame_pool_bank.sv','frame_manager.sv',top+'.sv')]
            execute(top+'_compile',[str(runtime/'iverilog.exe'),'-g2012','-I',str(sim),'-s',top,'-o',str(image),*sources],sim)
            for seed in ([42,177,2718] if top.endswith('pressure') else [42]):
                content=execute(top+'_'+str(seed),[str(runtime/'vvp.exe'),str(image),'+SEED='+str(seed)],sim)
                if '_PASS' not in content:raise RuntimeError('Missing smoke PASS')
        result['functional_smoke']=True
        # One dynamic three-slot bank is a resource-comparison probe only.
        # Disable physical IO insertion for its wide ports in both variants.
        for label,origin in [('baseline',candidate/'original_frame_pool_bank.sv'),('candidate',candidate/'source/rtl/memory/frame_pool_bank.sv')]:
            b=run/label;b.mkdir()
            for name in ('frame_manager_pkg.sv','frame_manager_layout.vh'):
                copy(candidate/'source/rtl/memory'/name,b/name)
            copy(origin,b/'frame_pool_bank.sv')
            (b/'clock.fdc').write_text('create_clock -name clk -period 8.000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+b.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for name in ('frame_manager_pkg.sv','frame_pool_bank.sv'):
                flow+='add_design {'+(b/name).as_posix()+'}\n'
            flow+='add_constraint {'+(b/'clock.fdc').as_posix()+'}\ncompile -top_module frame_pool_bank -system_verilog\n'
            flow+='synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
            (b/'flow.tcl').write_text(flow)
            execute(label+'_syn',['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(b/'flow.tcl'),'-work_dir',str(b)],b)
        result['passed']=True
        result['cycle_equivalent']=args.compare_valid_descriptors
        result['scope']='All bank response controls and accepted metadata cycle-equivalent; inactive lanes may broadcast another accepted descriptor' if args.compare_valid_descriptors else 'Latency-aware ownership smoke and unit synthesis only'
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in result['inputs'].items())
        (run/'result.json').write_text(json.dumps(result,indent=2))
        print('RESULT',run,flush=True)


if __name__=='__main__':
    main()

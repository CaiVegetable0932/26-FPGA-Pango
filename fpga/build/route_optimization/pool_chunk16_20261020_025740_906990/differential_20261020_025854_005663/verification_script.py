"""Compare all pool responses and redundant token state against frozen RTL."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


WRAPPER = '''`timescale 1ns/1ps
`include "frame_manager_layout.vh"
module frame_pool_bank #(
 parameter integer SLOTS=3,parameter [31:0] BASE=0,SLOT_BYTES=32'h00800000,
 parameter integer TXNS=8,parameter [31:0] STRIDE=6144
)(input wire clk,reset_n,fabric_ready,display_boundary,
 input wire [`FM_CMD_BITS-1:0] cmd,output wire [`FM_RSP_BITS-1:0] rsp);
 wire [`FM_RSP_BITS-1:0] reference_rsp;
 frame_pool_candidate #(.SLOTS(SLOTS),.BASE(BASE),.SLOT_BYTES(SLOT_BYTES),.TXNS(TXNS),.STRIDE(STRIDE))
 candidate(clk,reset_n,fabric_ready,display_boundary,cmd,rsp);
 frame_pool_reference #(.SLOTS(SLOTS),.BASE(BASE),.SLOT_BYTES(SLOT_BYTES),.TXNS(TXNS),.STRIDE(STRIDE))
 reference_impl(clk,reset_n,fabric_ready,display_boundary,cmd,reference_rsp);
 integer s,t,checks=0;
 task compare;
 begin
  if(reset_n)begin
   checks=checks+1;
   if(rsp !== reference_rsp) $fatal(1,"POOL_DIFF response (including invalid fields)");
`ifdef CHECK_LOCAL_FLAGS
   for(s=0;s<SLOTS;s=s+1)for(t=0;t<TXNS;t=t+1)
    if(candidate.slot_token_active[s][t] !== (candidate.token_busy[t] && candidate.token_slot[t]==s))
     $fatal(1,"POOL_DIFF token mirror s=%0d t=%0d",s,t);
`endif
`ifdef CHECK_COUNTER_STATE
   if(candidate.next_order !== reference_impl.next_order)
    $fatal(1,"POOL_DIFF full 64-bit order counter");
   for(t=0;t<TXNS;t=t+1)
    if(candidate.ticket[t] !== reference_impl.ticket[t] || candidate.token_busy[t] !== reference_impl.token_busy[t])
     $fatal(1,"POOL_DIFF full ticket/busy state t=%0d",t);
`endif
  end
 end endtask
 always @(posedge clk)begin #2;compare;end
 always @(negedge clk)begin #2;compare;end
 final $display("POOL_DIFF_CHECKS=%0d",checks);
endmodule
'''


RANDOM_TB = '''`timescale 1ns/1ps
import frame_manager_pkg::*;
module tb_pool_random;
 parameter integer SLOTS=3,TXNS=3;
 reg clk=0,reset_n=0,fabric_ready=0,display_boundary=0;
 frame_cmd_t cmd;frame_rsp_t rsp;integer seed=177,i,b;
 always #5 clk=~clk;
 frame_pool_bank #(.SLOTS(SLOTS),.TXNS(TXNS)) dut(clk,reset_n,fabric_ready,display_boundary,cmd,rsp);
 initial begin
  if($value$plusargs("SEED=%d",seed))begin end
  cmd='0;repeat(3)@(negedge clk);reset_n=1;
  for(i=0;i<30000;i=i+1)begin
   @(negedge clk);
   for(b=0;b<$bits(cmd);b=b+32)cmd[b+:32]=$random(seed);
   // Mix malformed/concurrent requests with legal zero-command drain edges.
   if((i%4)==0)cmd='0;
   fabric_ready=($random(seed)&7)!=0;display_boundary=($random(seed)&15)==0;
   reset_n=(i%601)!=0;
  end
  @(negedge clk);cmd='0;reset_n=1;repeat(5)@(negedge clk);
  $display("POOL_RANDOM_PASS");$finish;
 end
endmodule
'''

COUNTER_TB = '''`timescale 1ns/1ps
import frame_manager_pkg::*;
module tb_pool_counter_fences;
 reg clk=0,reset_n=0;always #5 clk=~clk;
 frame_cmd_t cmd;frame_rsp_t rsp;
 reg [63:0] seeds[0:4],held_ticket;integer i;
 frame_pool_bank #(.SLOTS(1),.TXNS(1)) dut(clk,reset_n,1'b1,1'b1,cmd,rsp);
 initial begin
  seeds[0]=64'hffff;seeds[1]=64'hffffffff;seeds[2]=64'hffffffffffff;
  seeds[3]=64'hfffffffffffffffe;seeds[4]=64'hffffffffffffffff;
  cmd='0;
  for(i=0;i<5;i=i+1)begin
   reset_n=0;cmd='0;repeat(3)@(negedge clk);reset_n=1;@(negedge clk);
   // Identical test-only deposits in independent implementations avoid
   // billions of transactions. Public operation/response checks remain live.
   dut.candidate.next_order=seeds[i];dut.reference_impl.next_order=seeds[i];
   dut.candidate.ticket[0]=seeds[i];dut.reference_impl.ticket[0]=seeds[i];
   cmd.alloc=1;cmd.meta.width=35;cmd.meta.height=33;cmd.meta.stride=6144;cmd.meta.format=2;
   cmd.meta.epoch=1;cmd.meta.frame_id=1;cmd.meta.capture_first=10;
   #1;
   if(i==4)begin
    if(rsp.alloc_ready)$fatal(1,"Order counter exhaustion wrapped");
    @(posedge clk);#3;
    if(dut.candidate.next_order!==seeds[i])$fatal(1,"Exhausted order counter changed");
   end else begin
    if(!rsp.alloc_ready)$fatal(1,"Boundary allocation not accepted");
    @(posedge clk);#3;
    if(dut.candidate.next_order!==(seeds[i]+64'd1))$fatal(1,"Order chunk carry");
    @(negedge clk);cmd='0;cmd.issue=1;cmd.issue_slot=0;cmd.issue_gen=1;cmd.issue_owner=0;
    #1;if(!rsp.issue_ready || rsp.issue_ticket!==(seeds[i]+64'd1))$fatal(1,"Ticket chunk carry response");
    held_ticket=rsp.issue_ticket;@(posedge clk);#3;
    if(dut.candidate.ticket[0]!==held_ticket)$fatal(1,"Ticket chunk state");
    @(negedge clk);cmd='0;cmd.complete=1;cmd.complete_ticket=held_ticket;cmd.complete_token=0;
    #1;if(!rsp.complete_ok)$fatal(1,"Boundary ticket did not retire");
    @(negedge clk);cmd='0;
   end
  end
  $display("POOL_COUNTER_FENCES_PASS");$finish;
 end
endmodule
'''


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--counter-state',action='store_true',
                        help='Compare full internal counters and test chunk carry/exhaustion boundaries')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga/'build'):
        raise ValueError('Frozen candidate required')
    run = candidate/datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    files = {'original.sv':candidate/'original_frame_pool_bank.sv',
             'candidate.sv':candidate/'source/rtl/memory/frame_pool_bank.sv'}
    for name in ['frame_manager_pkg.sv','frame_manager_layout.vh']:
        files[name] = candidate/'source/rtl/memory'/name
    # tb_frame_metadata_read specifically expects a speculative synchronous
    # metadata RAM edge. The current main design is asynchronous; its frozen
    # reference alone fails that fixture. Keep that diagnostic failure and
    # use the applicable default regression rather than changing its assertions.
    fixtures = ['tb_frame_manager_pressure','tb_frame_ticket_rollover']
    for name in fixtures:
        files[name+'.sv'] = fpga/'sim'/(name+'.sv')
    inputs = {str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in files.values()}
    for name,p in files.items():
        shutil.copyfile(p,run/name)
    for name,module in [('original.sv','frame_pool_reference'),('candidate.sv','frame_pool_candidate')]:
        p = run/name
        text = p.read_text(encoding='utf-8')
        assert text.count('module frame_pool_bank #(')==1
        p.write_text(text.replace('module frame_pool_bank #(', 'module '+module+' #('),encoding='utf-8')
    # The original exhaustion fixture deposits a ticket twice. Apply precisely
    # the same deposit to each independent implementation; no scoreboard/state
    # sharing or behavioral replacement participates in the proof.
    p = run/'tb_frame_ticket_rollover.sv'
    text = p.read_text(encoding='utf-8')
    text,count = re.subn(r'dut\.ticket\[0\]=([^;]+);',
        r'dut.candidate.ticket[0]=\1; dut.reference_impl.ticket[0]=\1;',text)
    assert count==2
    p.write_text(text,encoding='utf-8')
    (run/'wrapper.sv').write_text(WRAPPER,encoding='utf-8')
    (run/'tb_pool_random.sv').write_text(RANDOM_TB,encoding='utf-8')
    has_flags='slot_token_active' in (run/'candidate.sv').read_text(encoding='utf-8')
    if not has_flags and not args.counter_state:
        raise ValueError('Counter candidate requires full counter-state checking')
    if args.counter_state:
        (run/'tb_pool_counter_fences.sv').write_text(COUNTER_TB,encoding='utf-8')
    shutil.copyfile(__file__,run/'verification_script.py')
    runtime = fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result = dict(passed=False,inputs=inputs,four_state=True,all_response_bits_compared=True,
                  mirror_checked_on_both_edges=has_flags,internal_counter_state_compared=args.counter_state,
                  fixture_ticket_deposits_mirrored=count,tests=[])
    tests = [(n,n,[]) for n in fixtures]
    if args.counter_state:tests.append(('counter_fences','tb_pool_counter_fences',[]))
    tests += [('random_%s_%s_%s'%(s,t,seed),'tb_pool_random',
               ['-Ptb_pool_random.SLOTS='+str(s),'-Ptb_pool_random.TXNS='+str(t),'+SEED='+str(seed)])
              for s,t in [(1,1),(3,2),(3,3),(3,8)] for seed in [177,2718]]
    try:
        for name,top,options in tests:
            compile_args = [x for x in options if x.startswith('-P')]
            if has_flags:compile_args.append('-DCHECK_LOCAL_FLAGS')
            if args.counter_state:compile_args.append('-DCHECK_COUNTER_STATE')
            runtime_args = [x for x in options if x.startswith('+')]
            commands = [('compile',[str(runtime/'iverilog.exe'),'-g2012','-I',str(run),'-s',top,
                *compile_args,'-o',name+'.vvp','frame_manager_pkg.sv','original.sv','candidate.sv','wrapper.sv',top+'.sv']),
                ('run',[str(runtime/'vvp.exe'),name+'.vvp',*runtime_args])]
            for phase,command in commands:
                proc = subprocess.run(command,cwd=run,capture_output=True,timeout=120)
                output = proc.stdout+proc.stderr
                (run/(name+'_'+phase+'.log')).write_bytes(output)
                if proc.returncode:
                    raise RuntimeError(name+' '+phase+': '+output.decode(errors='replace')[-1500:])
            assert re.search(rb'POOL_DIFF_CHECKS=[1-9]\d*',output)
            result['tests'].append(dict(name=name,passed=True))
            print(name,'PASS',flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2))
        print('POOL_PROOF',run,flush=True)
    if not result['passed']:
        raise SystemExit(1)


if __name__ == '__main__':
    main()

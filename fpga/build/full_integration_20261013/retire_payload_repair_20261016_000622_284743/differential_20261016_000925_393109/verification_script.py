"""Check the selection-payload repair against independent original frame banks.

Each controller drives its own real frame manager. Compare all bank responses,
public controller outputs and active commands each cycle, including readiness
pauses, cancellation while paused, reset while acquiring, timeout and copy drain.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Freeze stimulus, both implementations and execution evidence together."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--regression-fixtures',type=Path,
                        help='Use already-passing frozen snapshot fixture with explicit bounded ACQUIRE waits')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga / 'build'):
        raise ValueError('Candidate must be under fpga/build')
    fixture_root=fpga/'sim'
    board_client_limits=False
    if args.regression_fixtures:
        regression=args.regression_fixtures.resolve()
        if not regression.is_relative_to(fpga/'build') or not json.loads((regression/'result.json').read_text()).get('passed'):
            raise ValueError('Passing frozen regression required for adapted fixtures')
        fixture_root=regression/'source'
        board_client_limits=bool(json.loads((regression/'result.json').read_text()).get('board_client_limits'))
    run = candidate / datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    inputs = {}
    names = ['frame_manager_pkg.sv', 'frame_manager_layout.vh', 'frame_pool_bank.sv',
             'frame_manager.sv', 'frame_snapshot_pair.sv']
    for name in names:
        p = candidate / 'source/rtl/memory' / name
        inputs[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
        shutil.copyfile(p, run / name)
    p = candidate / 'original_frame_snapshot_pair.sv'
    inputs[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
    (run / 'frame_snapshot_pair_baseline.sv').write_text(
        p.read_text(encoding='utf-8').replace('module frame_snapshot_pair ',
        'module frame_snapshot_pair_baseline ', 1), encoding='utf-8')
    # A synchronous bank may need a bounded ACK wait. The same frozen fixture
    # drives both independent banks; it never masks controller differences.
    p = fixture_root / 'tb_frame_snapshot_pair.sv'
    inputs[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
    tb = p.read_text(encoding='utf-8').replace('module tb_frame_snapshot_pair;',
        'module tb_frame_snapshot_pair #(parameter PAUSE=0);')
    # The reference controller receives responses from independent storage;
    # shared responses would hide an unintended reference-count mutation.
    extra = '''
 wire [5*CMD_BITS-1:0] ref_snapshot_bus, ref_command_bus;
 wire [5*RSP_BITS-1:0] ref_response_bus;
 wire ref_request_ready,ref_copy_valid,ref_copy_cancel,ref_pair_ready,ref_busy,ref_failed;
 wire [1:0] ref_copy_ss,ref_copy_rs;
 wire [31:0] ref_copy_sg,ref_copy_rg,ref_snap_sg,ref_snap_rg,ref_completed,ref_failures;
 wire frame_meta_t ref_sm,ref_rm;
 genvar shadow_lane;
 generate for(shadow_lane=0;shadow_lane<5;shadow_lane=shadow_lane+1)begin
  assign ref_command_bus[shadow_lane*CMD_BITS+:CMD_BITS]=external_command[shadow_lane] |
   ref_snapshot_bus[shadow_lane*CMD_BITS+:CMD_BITS];
 end endgenerate
 frame_manager reference_banks(clk,reset_n,fabric_ready,display_boundary,ref_command_bus,ref_response_bus);
 frame_snapshot_pair_baseline #(.WAIT_CYCLES(160)) reference_ctrl(clk,reset_n,fabric_ready,
  request,cancel,source_slot,result_slot,source_gen,result_gen,ref_request_ready,
  ref_response_bus,ref_snapshot_bus,ref_copy_valid,ref_copy_cancel,copy_ready,copy_done,copy_error,copy_drained,
  ref_copy_ss,ref_copy_rs,ref_copy_sg,ref_copy_rg,ref_snap_sg,ref_snap_rg,ref_sm,ref_rm,
  ref_pair_ready,ref_busy,ref_failed,ref_completed,ref_failures);
 // Only exact-selection payload with no SNAPSHOT acquire qualifier is inactive.
 // All other command fields, every bank response and public output must match.
 frame_cmd_t observed_command,reference_command;
 integer compare_lane,compared_cycles=0;
 always @(negedge clk)begin #2;
  if(reset_n)begin
   compared_cycles=compared_cycles+1;
   if(response_bus !== ref_response_bus)$fatal(1,"SNAPSHOT_DIFFERENTIAL bank response cycle=%0d",cycles);
   if({request_ready,copy_valid,copy_cancel,copy_ss,copy_rs,copy_sg,copy_rg,snap_sg,snap_rg,
       sm,rm,pair_ready,busy,failed,completed,failures} !==
      {ref_request_ready,ref_copy_valid,ref_copy_cancel,ref_copy_ss,ref_copy_rs,ref_copy_sg,ref_copy_rg,
       ref_snap_sg,ref_snap_rg,ref_sm,ref_rm,ref_pair_ready,ref_busy,ref_failed,ref_completed,ref_failures})
    $fatal(1,"SNAPSHOT_DIFFERENTIAL public output cycle=%0d",cycles);
   for(compare_lane=0;compare_lane<5;compare_lane=compare_lane+1)begin
    observed_command=snapshot_bus[compare_lane*CMD_BITS+:CMD_BITS];
    reference_command=ref_snapshot_bus[compare_lane*CMD_BITS+:CMD_BITS];
    if(!observed_command.acquire[SNAPSHOT])begin
     observed_command.snap_exact=0;observed_command.snap_slot=0;observed_command.snap_gen=0;
    end
    if(!reference_command.acquire[SNAPSHOT])begin
     reference_command.snap_exact=0;reference_command.snap_slot=0;reference_command.snap_gen=0;
    end
    if(observed_command !== reference_command)$fatal(1,"SNAPSHOT_DIFFERENTIAL active command");
   end
  end
 end
'''
    # Compare the controller repair against independent banks with the same
    # explicitly tested capacity. This proves the controller change under
    # that capacity; it does not claim old/new token capacities are equivalent.
    if board_client_limits:
        extra=extra.replace('frame_manager reference_banks(',
                            'frame_manager #(.BOARD_CLIENT_LIMITS(1)) reference_banks(',1)
    tb = tb.replace(' task tick;', extra+'\n task tick;', 1)
    tb = tb.replace('  request=0; while(!copy_valid && busy)tick;', '''  request=0;
  // Hold the first ACQUIRE edge: inactive descriptor bits may change but no
  // ownership or valid handshake may be committed until readiness returns.
  if(PAUSE!=0)begin
   fabric_ready=0;repeat(7)begin tick;check(!copy_valid && busy,"paused acquire holds");end
   @(negedge clk);fabric_ready=1;
  end
  while(!copy_valid && busy)tick;''', 1)
    marker = '  allocate(SRC,10,8,source_slot,source_gen);'
    probe = '''  // Cancel while the bank is unavailable, or asynchronously reset a
  // partially admitted request. Resume/cold-start must leave both banks equal.
  if(PAUSE>=2)begin
   allocate(SRC,8,8,source_slot,source_gen);allocate(DST,8,8,result_slot,result_gen);
   @(negedge clk);request=1;tick;request=0;fabric_ready=0;
   repeat(5)tick;
   if(PAUSE==2)begin
    @(negedge clk);cancel=1;repeat(5)tick;check(busy,"cancel waits while fabric held");
    @(negedge clk);fabric_ready=1;tick;cancel=0;
    while(busy)tick;repeat(3)tick;
    for(b=0;b<5;b=b+1)begin y=response[b];check(y.occupied==0,"cancel acquire no reference leak");end
   end
   @(negedge clk);reset_n=0;repeat(3)tick;
   @(negedge clk);reset_n=1;fabric_ready=1;tick;
  end
'''
    if tb.count(marker) != 1:
        raise ValueError('Unexpected snapshot fixture')
    tb = tb.replace(marker, probe+marker, 1)
    tb = tb.replace('$display("FRAME_SNAPSHOT_PAIR_PASS',
        '$display("DIFFERENTIAL_CYCLES %0d",compared_cycles);\n  $display("FRAME_SNAPSHOT_PAIR_PASS',1)
    (run / 'tb_frame_snapshot_pair.sv').write_text(tb, encoding='utf-8')
    shutil.copyfile(__file__, run / 'verification_script.py')
    runtime = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    status = dict(passed=False, cycle_equivalent=False, inputs=inputs, tests=[],
                  reference_board_client_limits=board_client_limits)
    status['scope']='Snapshot control payload gating only; common frame-bank implementation is separately validated for accepted metadata and bounded latency'
    try:
        for mode in range(4):
            name = 'pause_'+str(mode)
            exe = run / (name+'.vvp')
            sources = [str(run/n) for n in names if not n.endswith('.vh')]
            sources += [str(run/'frame_snapshot_pair_baseline.sv'),str(run/'tb_frame_snapshot_pair.sv')]
            cmd = [str(runtime/'iverilog.exe'),'-g2012','-I',str(run),'-s','tb_frame_snapshot_pair',
                   '-Ptb_frame_snapshot_pair.PAUSE='+str(mode),'-o',str(exe),*sources]
            for phase,command in [('compile',cmd),('run',[str(runtime/'vvp.exe'),str(exe)])]:
                proc = subprocess.run(command,cwd=run,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
                (run/(name+'.'+phase+'.log')).write_bytes(proc.stdout)
                log = proc.stdout.decode(errors='replace')
                if proc.returncode or (phase=='run' and 'FRAME_SNAPSHOT_PAIR_PASS' not in log):
                    raise RuntimeError(name+' '+phase+': '+log[-4000:])
            status['tests'].append(name)
            print(name,'PASS',flush=True)
        status['inputs_intact'] = all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in inputs.items())
        if not status['inputs_intact']:
            raise ValueError('Verification inputs changed')
        status.update(passed=True,cycle_equivalent=True)
    finally:
        (run/'result.json').write_text(json.dumps(status,indent=2),encoding='utf-8')
        print('RUN',run,flush=True)


if __name__ == '__main__':
    main()

"""Compare original and candidate fabrics on the complete ownership fixture.

Independent frame-manager and DMA state share the fixture's request/native
inputs. Compare every public output every cycle, including inactive payloads.
The original scoreboard still verifies actual write-readback and drain fences.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def main():
    """Bind exact reference/fixture bytes and run a dual-fabric simulation."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--regression-fixtures',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    candidate=args.candidate.resolve(); regression=args.regression_fixtures.resolve()
    if not all(p.is_relative_to(fpga/'build') for p in (candidate,regression)):
        raise ValueError('Frozen FPGA inputs required')
    previous_result=json.loads((regression/'result.json').read_text())
    if not previous_result.get('passed') or not previous_result.get('board_client_limits'):
        raise ValueError('Passing board-capacity fixtures required')
    run=candidate/datetime.now().strftime('retire_differential_%Y%m%d_%H%M%S_%f');run.mkdir()
    inputs={}
    def bound(path):
        inputs[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
        return path.read_text()
    original=candidate/'original_frame_memory_fabric.sv'
    old=bound(original)
    marker='module frame_memory_fabric #('
    if old.count(marker)!=1: raise ValueError('Unexpected original module')
    (run/'reference_fabric.sv').write_text(old.replace(marker,'module frame_memory_fabric_reference #(',1))
    fixture=regression/'source/tb_frame_memory_fabric.sv'
    test=bound(fixture)
    anchor=' frame_memory_fabric #(.BOARD_CLIENT_LIMITS(1)) dut(.*);'
    if test.count(anchor)!=1: raise ValueError('Unexpected board fixture')
    outputs={n:'[N-1:0]' for n in 'req_ready w_ready r_valid r_last done error cancelled'.split()}
    outputs.update(frame_response='[5*RSP_BITS-1:0]',r_data='[N*256-1:0]',
        done_tag='[N*32-1:0]',bus_bytes='[N*32-1:0]',max_wait_cycles='[N*32-1:0]',useful_write_bytes='[N*32-1:0]',
        fault='',awaddr='[27:0]',araddr='[27:0]',awlen='[3:0]',arlen='[3:0]',awid='[3:0]',arid='[3:0]',
        awvalid='',arvalid='',native_wdata='[255:0]',native_wstrb='[31:0]')
    ins='clk rst_n controller_ready display_boundary frame_command req_valid req_write req_addr req_tag req_beats req_bank req_owner req_slot req_generation urgent cancel w_valid w_data w_strb r_ready done_ready awready arready native_wready native_wlast native_wid native_rdata native_rvalid native_rlast native_rid'.split()
    extra='\n // Separate reference ownership and transport state; shared stimulus only.\n'
    extra+='\n'.join(' wire '+w+' ref_'+n+';' for n,w in outputs.items())+'\n'
    ports=['.'+n+'('+n+')' for n in ins]+['.'+n+'(ref_'+n+')' for n in outputs]
    extra+=' frame_memory_fabric_reference #(.BOARD_CLIENT_LIMITS(1)) reference_impl('+','.join(ports)+');\n'
    extra+=' integer compared_cycles=0;\n always @(negedge clk)begin #2; if(rst_n)begin\n compared_cycles=compared_cycles+1;\n'
    for n in outputs:
        extra+=' if('+n+' !== ref_'+n+')$fatal(1,"RETIRE_DIFFERENTIAL '+n+'");\n'
    extra+=' end end\n final begin if(compared_cycles<100)$fatal(1,"RETIRE_DIFFERENTIAL insufficient coverage"); $display("RETIRE_DIFFERENTIAL_PASS cycles=%0d",compared_cycles);end\n'
    (run/fixture.name).write_text(test.replace(anchor,anchor+extra,1))
    names=['frame_manager_pkg.sv','frame_manager_layout.vh','frame_pool_bank.sv','frame_manager.sv','ddr_native_dma.v','frame_memory_fabric.sv']
    for name in names:
        path=candidate/'source/rtl/memory'/name
        bound(path); shutil.copyfile(path,run/name)
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    sources=[str(run/n) for n in names if not n.endswith('.vh')]+[str(run/'reference_fabric.sv'),str(run/fixture.name)]
    result=dict(passed=False,cycle_equivalent=False,inputs=inputs,tests=[],
        scope='All public fabric outputs under the board-capacity ownership/readback fixture; no hardware or full-frame performance claim')
    try:
        image=run/'fabric.vvp'
        commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-I',str(run),'-s','tb_frame_memory_fabric','-o',str(image),*sources]),('run',[str(tool/'vvp.exe'),str(image)])]
        for phase,command in commands:
            proc=subprocess.run(command,cwd=run,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=180)
            (run/(phase+'.log')).write_bytes(proc.stdout)
            log=proc.stdout.decode(errors='replace')
            if proc.returncode or 'FATAL' in log or (phase=='run' and ('RETIRE_DIFFERENTIAL_PASS' not in log or 'FRAME_MEMORY_FABRIC_PASS' not in log)):
                raise RuntimeError(phase+': '+log[-5000:])
        result.update(passed=True,cycle_equivalent=True,tests=['full_readback_all_fabric_outputs'])
    finally:
        result['inputs_intact']=all(hashlib.sha256(Path(p).read_bytes()).hexdigest()==h for p,h in inputs.items())
        result['passed']=result['passed'] and result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print('RUN',run,flush=True)


if __name__=='__main__':
    main()

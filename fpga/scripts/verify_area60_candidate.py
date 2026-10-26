"""Source-bound functional and cycle checks for isolated area experiments."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess

from regional_scan_wrapper import ports


def sha(path):
    """Record the exact simulator inputs and prevent mutable-source claims."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Keep the existing independent oracle and add a frozen baseline peer."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1];candidate=args.candidate.resolve()
    identity=json.loads((candidate/'candidate.json').read_text())
    baseline=Path(identity['baseline'])
    manifest=json.loads((candidate/'sources.json').read_text())
    assert all(sha(candidate/'source'/n)==h for n,h in manifest.items())
    run=candidate/datetime.now().strftime('unit_%Y%m%d_%H%M%S_%f');run.mkdir()
    fabric=identity['variant']=='fabric_bounds';pack=identity['variant']=='pack_decode';stats=identity['variant']=='stats_share'
    top='rgb_frame_statistics' if stats else 'frame_memory_fabric' if fabric else 'dma_pixel_pack' if pack else 'geometry_tile_refill'
    bench='tb_statistics_area' if stats else 'tb_'+top+('_differential' if pack else '')
    suffix='.v' if pack else '.sv'
    module_path='rtl/'+('isp/' if stats else 'memory/')+top+suffix
    names=[module_path,'rtl/memory/ddr_native_dma.v']
    if fabric:names+=['rtl/memory/frame_manager.sv','rtl/memory/frame_pool_bank.sv',
                     'rtl/memory/frame_manager_layout.vh','rtl/memory/frame_manager_pkg.sv']
    origins={}
    for n in names:
        p=candidate/'source'/n;shutil.copyfile(p,run/p.name);origins[str(p)]=sha(p)
    old=baseline/'source'/module_path
    original=old.read_text();origins[str(old)]=sha(old)
    (run/(top+'_baseline.sv')).write_text(re.sub(r'\bmodule '+top+r'\b','module '+('baseline_pack' if pack else top+'_baseline'),original,count=1),encoding='utf-8')
    fixture=fpga/'sim'/(bench+'.sv');origins[str(fixture)]=sha(fixture)
    header=original
    if fabric:
        # Resolve only numeric layout constants for the port parser. Icarus
        # still compiles the unmodified header and package as real inputs.
        layout=(run/'frame_manager_layout.vh').read_text()
        for n,v in re.findall(r'^`define\s+(\w+)\s+(\d+)\s*$',layout,re.M):header=header.replace('`'+n,v)
    text=fixture.read_text();port_list=ports(header,top,{'N':6,'TAG_BITS':192})
    peer=top+'_baseline '+('#(.SUPPORT_ABORT(1)) ' if stats else '')+'reference('+','.join('.'+n+'(dut.'+n+')' for d,n,w in port_list if d=='input')+');\n'
    peer+='integer diff_cycles=0; always @(negedge clk) if(rst_n)begin diff_cycles++;\n'
    for direction,name,width in port_list:
        if direction!='output':continue
        if fabric and name=='r_data':
            peer+='for(integer dc=0;dc<6;dc++)if((dut.r_valid[dc] || reference.r_valid[dc]) && dut.r_data[dc*256+:256] !== reference.r_data[dc*256+:256])$fatal(1,"AREA_DIFF r_data");\n'
        else:
            guard='(dut.fill_valid || reference.fill_valid) && ' if name=='fill_rgb' else ''
            peer+='if('+guard+'dut.'+name+' !== reference.'+name+')$fatal(1,"AREA_DIFF '+name+'");\n'
    peer+='end\n final $display("AREA_DIFF cycles=%0d",diff_cycles);\n'
    instance=' '+top+(' #(.SUPPORT_ABORT(1))' if stats else '')+' dut(.*);'
    if not pack:text=text.replace(instance,instance+'\n // Compare control every cycle, and payload whenever it is valid.\n '+peer)
    (run/(bench+'.sv')).write_text(text,encoding='utf-8')
    shutil.copyfile(__file__,run/'verification_script.py')
    frozen={p.name:sha(p) for p in run.iterdir() if p.is_file()}
    binary=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    sources=[p for p in frozen if p.endswith(('.sv','.v'))]
    sources.sort(key=lambda n:0 if n=='frame_manager_pkg.sv' else 1)
    compile_cmd=[str(binary/'iverilog.exe'),'-g2012','-I',str(run),'-s',bench,'-o',str(run/'unit.vvp')]+[str(run/p) for p in sources]
    result=dict(passed=False,origins=origins,frozen_files=frozen,candidate=str(candidate),module=top,commands=[compile_cmd],hardware_tested=False)
    print('AREA_UNIT',run,flush=True)
    try:
        proc=subprocess.run(compile_cmd,cwd=run,input=b'',capture_output=True,timeout=120)
        (run/'compile.log').write_bytes(proc.stdout+proc.stderr)
        if proc.returncode:raise RuntimeError('Compile failed: '+(proc.stdout+proc.stderr).decode(errors='replace')[-1500:])
        cmd=[str(binary/'vvp.exe'),str(run/'unit.vvp')];result['commands'].append(cmd)
        proc=subprocess.run(cmd,cwd=run,input=b'',capture_output=True,timeout=180)
        output=proc.stdout+proc.stderr;(run/'run.log').write_bytes(output)
        result['passed']=proc.returncode==0 and (b'STATISTICS_AREA_PASS' if stats else b'FRAME_MEMORY_FABRIC_PASS' if fabric else b'PIXEL_PACK_DIFFERENTIAL_PASS' if pack else b'GEOMETRY_TILE_REFILL_PASS') in output and b'FATAL' not in output
        print(output.decode(errors='replace'),flush=True)
    finally:
        result['inputs_intact']=all(sha(Path(p))==h for p,h in origins.items()) and all(sha(run/n)==h for n,h in frozen.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':
    main()

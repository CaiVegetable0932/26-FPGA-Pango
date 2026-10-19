"""Exercise experimental dual-clock geometry using the native byte oracle."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,shutil,subprocess

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--regression',type=Path,required=True)
    parser.add_argument('--read-prefetch-proof',type=Path)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    original=args.regression.resolve()
    if not original.is_relative_to(fpga/'build') or not json.loads((original/'result.json').read_text())['passed']:
        raise ValueError('Passed frozen regression required')
    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_geometry_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    for p in (original/'source').iterdir():
        if p.suffix in ('.sv','.v','.vh') and not p.name.startswith('tb_'):shutil.copyfile(p,source/p.name)
    for name in ['geometry_processing_domain.sv','processing_job_cdc.sv','dma_write_cdc.sv']:
        shutil.copyfile(fpga/'experiments/proc150/rtl'/name,source/name)
    if args.read_prefetch_proof:
        # The second structural variant changes only the client delivery of
        # an already buffered read burst; all DMA ownership stays unchanged.
        checked=json.loads((args.read_prefetch_proof/'result.json').read_text())
        candidate=fpga/'experiments/proc150/rtl/dma_read_cdc_prefetch.sv'
        if not checked.get('passed') or len(checked.get('tests',[]))!=8 or any(
            hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h for p,h in checked['inputs'].items()):
            raise ValueError('Complete intact prefetch proof required')
        shutil.copyfile(candidate,source/candidate.name)
        adapter=source/'geometry_processing_domain.sv';adapter.write_text(adapter.read_text().replace(
            'dma_read_cdc source_bridge(','dma_read_cdc_prefetch source_bridge('),encoding='utf-8',newline='\n')
    fixture=original/'source/tb_geometry_frame_processor.sv'
    shutil.copyfile(fixture,run/'original_tb_geometry_frame_processor.sv')
    text=fixture.read_text(encoding='utf-8')
    # Only the module boundary, processor clock, and LUT programming clock
    # change. All original native backend, masks, guards and RGB byte checks
    # remain intact. Source scheduling and DDR still run at the original 125M.
    replacements={
        'geometry_frame_processor processor(.clk(clk),.rst_n(rst_n),':
        'geometry_processing_domain processor(.clk(clk),.rst_n(rst_n),.processing_clk(pclk),.processing_rst_n(prst_n),',
        'reg clk=0,rst_n=0,job_valid=0;always #4 clk=~clk;':
        'parameter real PROC_HALF=3.333,PROC_PHASE=0.7;\n reg pclk=0,prst_n=0;\n initial begin #PROC_PHASE;forever #PROC_HALF pclk=~pclk;end\n reg clk=0,rst_n=0,job_valid=0;always #4 clk=~clk;',
        'repeat(4)@(negedge clk);rst_n=1;':
        'repeat(4)@(negedge clk);rst_n=1;@(negedge pclk);prst_n=1;',
        'begin @(negedge clk);lut_write=1;': 'begin @(negedge pclk);lut_write=1;',
        '@(negedge clk);lut_write=0;lut_commit=1;@(negedge clk);lut_commit=0;':
        '@(negedge pclk);lut_write=0;lut_commit=1;@(negedge pclk);lut_commit=0;'}
    for old,new in replacements.items():
        if text.count(old)!=1:raise ValueError('Unexpected fixture boundary: '+old)
        text=text.replace(old,new)
    tb=source/'tb_geometry_frame_processor.sv';tb.write_text(text,encoding='utf-8',newline='\n')
    shutil.copyfile(__file__,run/'verification_script.py')
    hashes={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir()}
    (run/'sources.json').write_text(json.dumps(hashes,indent=2))
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    modules=['source/frame_manager_pkg.sv']+['source/'+n for n in hashes if n.endswith(('.v','.sv')) and n!='frame_manager_pkg.sv']
    result=dict(passed=False,production_instantiated=False,full_frame=False,physical_signed_off=False,
        read_prefetch_proof=str(args.read_prefetch_proof) if args.read_prefetch_proof else None,
        reference_regression=str(original),reference_fixture_sha256=hashlib.sha256(fixture.read_bytes()).hexdigest(),tests=[])
    try:
        for half,phase in [(3.333,.7),(3.333,3.9),(4.7,1.1)]:
            case=run/f'p{half}_phase{phase}';case.mkdir()
            commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-I',str(source),'-s','tb_geometry_frame_processor',
                '-Ptb_geometry_frame_processor.PROC_HALF='+str(half),'-Ptb_geometry_frame_processor.PROC_PHASE='+str(phase),
                '-o',str(case/'test.vvp'),*modules]),('run',[str(tool/'vvp.exe'),'test.vvp'])]
            for stage,cmd in commands:
                process=subprocess.run(cmd,cwd=run if stage=='compile' else case,capture_output=True,timeout=240)
                output=process.stdout+process.stderr;(case/(stage+'.log')).write_bytes(output)
                if process.returncode:raise RuntimeError(output.decode(errors='replace')[-3000:])
            if b'GEOMETRY_FRAME_PROCESSOR_PASS frames=3' not in output:raise ValueError('Native byte scoreboard did not finish')
            result['tests'].append(dict(processing_half_ns=half,phase_ns=phase,passed=True,summary=output.decode().strip()))
            print(case.name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256((source/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
        print('PROC150_GEOMETRY_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)

if __name__=='__main__':main()

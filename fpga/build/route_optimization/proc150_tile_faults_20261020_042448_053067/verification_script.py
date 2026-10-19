"""Inject completion faults into a frozen, passed tile-domain byte model."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,shutil,subprocess

def add_fault_tests(text):
    """Keep the native memory/byte oracle; alternate six failures and recoveries."""
    anchor='integer cycle=0,'
    extra=''' // Completion faults are injected only at the client interface AFTER
 // the real native transaction drains, retaining its original memory model.
 integer fault_kind=0,trigger=1,read_requests=0,write_requests=0;
 wire injected_source=read_requests>=trigger;
 wire injected_result=write_requests>=trigger;
 always @(posedge clk)if(rst_n)begin
  if(req_valid[0] && req_ready[0])read_requests=read_requests+1;
  if(req_valid[1] && req_ready[1])write_requests=write_requests+1;
 end
'''
    assert text.count(anchor)==1;text=text.replace(anchor,extra+anchor)
    old='.source_error(error[0]),.source_cancelled(cancelled[0]),.source_done_tag(done_tag[31:0]),'
    new=".source_error(error[0] || (fault_kind==1 && injected_source)),.source_cancelled(cancelled[0] || (fault_kind==2 && injected_source)),.source_done_tag(done_tag[31:0] ^ ((fault_kind==3 && injected_source)?32'd1:32'd0)),"
    assert text.count(old)==1;text=text.replace(old,new)
    old='.result_error(error[1]),.result_cancelled(cancelled[1]),.result_done_tag(done_tag[63:32]));'
    new=".result_error(error[1] || (fault_kind==4 && injected_result)),.result_cancelled(cancelled[1] || (fault_kind==5 && injected_result)),.result_done_tag(done_tag[63:32] ^ ((fault_kind==6 && injected_result)?32'd1:32'd0)));"
    assert text.count(old)==1;text=text.replace(old,new)
    text=text.replace('for(integer f=0;f<3;f++)begin','for(integer f=0;f<15;f++)begin')
    text=text.replace('enhancement=f;for(integer a=0;',
        'fault_kind=(f>=3 && f%2==1)?(f-1)/2:0;trigger=fault_kind%3+1;read_requests=0;write_requests=0;\n   enhancement=f<3?f:0;for(integer a=0;')
    marker='   if(job_failed || fault || wl!=0 || rl!=0 || result_metadata!=616\'h8000000000000007)$fatal(1,"PROCESSOR_FAIL metadata/failed/drain");'
    assert text.count(marker)==1
    text=text.replace(marker,'''   if(fault_kind!=0)begin
    if(!job_failed || fault || wl!=0 || rl!=0 || processor.fbusy || result_metadata!=616'h8000000000000007)
     $fatal(1,"FAULT_JOB_FAIL success or undrained traffic kind=%0d",fault_kind);
   end else begin
'''+marker)
    text=text.replace('if(f!=0)value=~value;','if(enhancement!=0)value=~value;')
    anchor='    checks++;\n   end\n  end\n  $display';assert text.count(anchor)==1
    text=text.replace(anchor,'    checks++;\n   end\n   end\n  end\n  $display')
    return text.replace('GEOMETRY_FRAME_PROCESSOR_PASS frames=3','GEOMETRY_FRAME_PROCESSOR_PASS frames=15 faults=6')

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--proof',type=Path,required=True)
    parser.add_argument('--reference',action='store_true',help='Run original synchronous processor with the same fault oracle')
    parser.add_argument('--pipeline-source',type=Path,help='Frozen single-file recovery candidate')
    args=parser.parse_args();f=Path(__file__).resolve().parents[1];base=args.proof.resolve()
    checked=json.loads((base/'result.json').read_text());hashes=json.loads((base/'sources.json').read_text())
    assert checked['passed'] and checked['inputs_intact'] and checked.get('tile_refill_proof') and len(checked['tests'])==3
    assert all(hashlib.sha256((base/'source'/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
    run=f/'build/route_optimization'/datetime.now().strftime('proc150_tile_faults_%Y%m%d_%H%M%S_%f')
    source=run/'source';shutil.copytree(base/'source',source)
    fixture=source/'tb_geometry_frame_processor.sv'
    text=(base/'original_tb_geometry_frame_processor.sv').read_text() if args.reference else fixture.read_text()
    text=add_fault_tests(text)
    if args.reference:
        text=text.replace('processor.fbusy','processor.refill_busy')
        text=text.replace('module tb_geometry_frame_processor;',
            'module tb_geometry_frame_processor;\n parameter real PROC_HALF=4.0,PROC_PHASE=0.0; // Unused in synchronous reference.')
    # Diagnostic text changes only the fatal message, retaining its condition.
    text=text.replace('$fatal(1,"PROCESSOR_FAIL metadata/failed/drain");',
        '$fatal(1,"PROCESSOR_FAIL frame=%0d kind=%0d failed=%0d native_fault=%0d wl=%0d rl=%0d",f,fault_kind,job_failed,fault,wl,rl);')
    fixture.write_text(text,encoding='utf-8',newline='\n')
    if args.pipeline_source:
        assert args.pipeline_source.resolve().is_relative_to(f/'build')
        shutil.copyfile(args.pipeline_source,source/'geometry_rgb_pipeline.sv')
    hashes={n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in hashes}
    (run/'sources.json').write_text(json.dumps(hashes,indent=2));shutil.copyfile(__file__,run/'verification_script.py')
    tool=f/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    modules=['source/frame_manager_pkg.sv']+['source/'+n for n in hashes if n.endswith(('.v','.sv')) and n!='frame_manager_pkg.sv']
    result=dict(passed=False,production_instantiated=False,reference_proof=str(base),completion_fault_kinds=6,
        synchronous_reference=args.reference,pipeline_source=str(args.pipeline_source) if args.pipeline_source else None,
        independent_recovery_byte_scoreboard=True,tests=[])
    try:
        cases=[(4.0,0.0)] if args.reference else [(3.333,.7),(3.333,3.9),(4.7,1.1)]
        for half,phase in cases:
            case=run/f'p{half}_phase{phase}';case.mkdir()
            commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-I',str(source),'-s','tb_geometry_frame_processor',
                '-Ptb_geometry_frame_processor.PROC_HALF='+str(half),'-Ptb_geometry_frame_processor.PROC_PHASE='+str(phase),
                '-o',str(case/'test.vvp'),*modules]),('run',[str(tool/'vvp.exe'),'test.vvp'])]
            for stage,cmd in commands:
                p=subprocess.run(cmd,cwd=run if stage=='compile' else case,capture_output=True,timeout=240)
                output=p.stdout+p.stderr;(case/(stage+'.log')).write_bytes(output)
                if p.returncode:raise RuntimeError(output.decode(errors='replace')[-3000:])
            if b'GEOMETRY_FRAME_PROCESSOR_PASS frames=15 faults=6' not in output:raise ValueError('Fault/recovery oracle did not finish')
            result['tests'].append(dict(processing_half_ns=half,phase_ns=phase,passed=True,summary=output.decode().strip()))
            print(case.name,'PASS',flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(hashlib.sha256((source/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2));print('TILE_DOMAIN_FAULT_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)

if __name__=='__main__':main()

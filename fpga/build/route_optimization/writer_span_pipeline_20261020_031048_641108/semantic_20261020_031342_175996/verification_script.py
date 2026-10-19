"""Verify intentional startup latency with independent byte/range scoreboards.

This is semantic equivalence, not cycle equivalence. Each implementation has
its own elastic producer and full-readback native DMA backend. The same
independent byte oracle checks complete frames, padding and 4 KiB splits.
"""
import argparse
from datetime import datetime
import hashlib,json,re,shutil,subprocess
from pathlib import Path


def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--reference-fixture',type=Path,required=True)
    parser.add_argument('--arithmetic-proof',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    candidate,fixture,arithmetic=[p.resolve() for p in (args.candidate,args.reference_fixture,args.arithmetic_proof)]
    if not all(p.is_relative_to(fpga/'build') for p in [candidate,fixture,arithmetic]):raise ValueError('Frozen paths required')
    checked=json.loads((fixture/'result.json').read_text());math=json.loads((arithmetic/'result.json').read_text())
    if not all(checked.get(k) for k in ('passed','storage_edges','cycle_equivalent','inputs_intact')):
        raise ValueError('The established full-readback storage fixture is required')
    if not all(math.get(k) for k in ('passed','full_height_sweep','four_state','inputs_intact')):
        raise ValueError('Full-product proof is required')
    if any(sha(Path(p))!=h for proof in [checked,math] for p,h in proof['inputs'].items()):raise ValueError('Upstream proof drift')
    original=candidate/'original_frame_pixel_writer.sv';current=candidate/'source/rtl/memory/frame_pixel_writer.sv'
    if sha(original) not in checked['inputs'].values() or sha(original) not in math['inputs'].values():
        raise ValueError('Both upstream proofs must bind the actual baseline')
    metadata=json.loads((candidate/'candidate.json').read_text())
    if metadata.get('extra_frame_startup_cycles')!=2 or metadata.get('per_segment_added_cycles')!=0:
        raise ValueError('Only the explicit two-cycle admission candidate is reviewed')
    paths={'baseline.sv':original,'candidate.sv':current,
        'dma_pixel_pack.v':candidate/'source/rtl/memory/dma_pixel_pack.v',
        'ddr_native_dma.v':candidate/'source/rtl/memory/ddr_native_dma.v',
        'admission_tb.sv':fpga/'sim/tb_writer_admission_pipeline.sv',
        'byte_fixture_with_cycle_monitor.sv':fixture/'tb_frame_pixel_writer.sv'}
    inputs={str(p):sha(p) for p in paths.values()}
    inputs.update({str(fixture/'result.json'):sha(fixture/'result.json'),str(arithmetic/'result.json'):sha(arithmetic/'result.json')})
    inputs.update(checked['inputs']);inputs.update(math['inputs'])
    run=candidate/datetime.now().strftime('semantic_%Y%m%d_%H%M%S_%f');run.mkdir()
    for name,p in paths.items():shutil.copyfile(p,run/name)
    text=(run/'byte_fixture_with_cycle_monitor.sv').read_text(encoding='utf-8')
    marker=re.search(r'\n wire\s+baseline_frame_ready;',text)
    if not marker or text.count('WRITER_DIFFERENTIAL control/latency')!=1:
        raise ValueError('Unexpected frozen byte fixture')
    # Remove ONLY the appended dual-instance cycle monitor. Keep the actual
    # independent producer, DDR readback backend and every byte assertion.
    (run/'tb_frame_pixel_writer.sv').write_text(text[:marker.start()]+'\nendmodule\n',encoding='utf-8')
    shutil.copyfile(__file__,run/'verification_script.py')
    tool=fpga/'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    result=dict(passed=False,cycle_equivalent=False,semantic_equivalent=False,four_state=True,
        extra_frame_startup_cycles=2,declared_per_segment_added_cycles=0,independent_byte_scoreboards=False,
        range_and_abort_tests=False,upstream_full_product_proof=str(arithmetic),inputs=inputs,tests=[])
    shapes=[(1,1),(10,7),(11,8),(21,9),(22,17),(31,9),(32,17),(33,8),(35,9),(64,17),(65,9),(1920,9)]
    try:
        for label,extra in [('baseline',0),('candidate',2)]:
            tests=[(f'{label}_bytes_{t}_{w}_{h}','tb_frame_pixel_writer',
                    ['-Ptb_frame_pixel_writer.TILED='+str(t),'-Ptb_frame_pixel_writer.W='+str(w),'-Ptb_frame_pixel_writer.H='+str(h)],
                    'tb_frame_pixel_writer.sv','FRAME_PIXEL_WRITER_PASS') for t in [0,1] for w,h in shapes]
            tests.append((label+'_admission','tb_writer_admission_pipeline',
                ['-Ptb_writer_admission_pipeline.EXTRA_STARTUP='+str(extra)],'admission_tb.sv','WRITER_ADMISSION_PASS'))
            for name,top,params,tb,marker in tests:
                commands=[('compile',[str(tool/'iverilog.exe'),'-g2012','-s',top,*params,'-o',name+'.vvp',
                    label+'.sv','dma_pixel_pack.v','ddr_native_dma.v',tb]),('run',[str(tool/'vvp.exe'),name+'.vvp'])]
                for phase,command in commands:
                    p=subprocess.run(command,cwd=run,capture_output=True,timeout=180)
                    output=p.stdout+p.stderr;(run/(name+'_'+phase+'.log')).write_bytes(output)
                    if p.returncode:raise RuntimeError(name+' '+phase+': '+output.decode(errors='replace')[-1800:])
                if marker.encode() not in output:raise ValueError('Missing independent completion marker')
                result['tests'].append(dict(name=name,passed=True))
                print(name,'PASS',flush=True)
        result.update(passed=True,semantic_equivalent=True,independent_byte_scoreboards=True,
            range_and_abort_tests=True,measured_legal_and_invalid_startup_extra_cycles=2)
    finally:
        result['inputs_intact']=all(sha(Path(p))==h for p,h in inputs.items())
        result['passed'] &= result['inputs_intact'];(run/'result.json').write_text(json.dumps(result,indent=2))
        print('WRITER_SEMANTIC_PROOF',run,flush=True)
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':main()

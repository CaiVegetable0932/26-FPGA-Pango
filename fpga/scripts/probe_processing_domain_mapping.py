"""Proof-bound experimental geometry-domain SYN only; no PnR or bitstream."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,re,shutil
from route_supervisor import run_supervised

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--proof',type=Path,required=True)
    parser.add_argument('--pause-file',type=Path,required=True)
    parser.add_argument('--projective',type=int,choices=(0,1),default=0)
    parser.add_argument('--integration-proof',type=Path,
                        help='Passed projective control/snapshot model binding the same adapter')
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];proof=args.proof.resolve()
    if not proof.is_relative_to(fpga/'build'):raise ValueError('Frozen experimental proof required')
    result=json.loads((proof/'result.json').read_text());hashes=json.loads((proof/'sources.json').read_text())
    if not result.get('passed') or not result.get('inputs_intact') or len(result.get('tests',[]))!=3:
        raise ValueError('Three complete native byte-scoreboard cases required')
    if not all(sha(proof/'source'/n)==h for n,h in hashes.items()):raise ValueError('Proof closure drift')
    if args.projective:
        if not args.integration_proof:raise ValueError('Projective mapping requires its integration proof')
        integrated=args.integration_proof.resolve()
        evidence=json.loads((integrated/'result.json').read_text())
        if not all(evidence.get(k) for k in ['passed','snapshot_intact','control_test','snapshot_test']):
            raise ValueError('Passed control and snapshot proof required')
        for name,group in [('geometry_processing_domain.sv','geometry'),('geometry_frame_processor.sv','geometry'),
                           ('processing_job_cdc.sv','memory'),('dma_write_cdc.sv','memory'),('dma_read_cdc.sv','memory')]:
            if sha(integrated/'source/rtl'/group/name)!=hashes[name]:raise ValueError('Integration source mismatch: '+name)
        if 'dma_read_cdc_prefetch.sv' in hashes and sha(integrated/'source/rtl/memory/dma_read_cdc_prefetch.sv')!=hashes['dma_read_cdc_prefetch.sv']:
            raise ValueError('Integration prefetch bridge mismatch')
    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_mapping_%Y%m%d_%H%M%S_%f')
    build=run/'source';shutil.copytree(proof/'source',build)
    # This isolated top has no parent to specialize PROJECTIVE. Change only
    # its compile-time default, preserving the recorded proof-source identity.
    if args.projective:
        top=build/'geometry_processing_domain.sv';text=top.read_text(encoding='utf-8')
        old='parameter META_BITS=616,PROJECTIVE=0'
        if text.count(old)!=1:raise ValueError('Unexpected isolated top parameters')
        top.write_text(text.replace(old,'parameter META_BITS=616,PROJECTIVE=1'),encoding='utf-8',newline='\n')
    mapped_hashes={n:sha(build/n) for n in hashes}
    # Installed PDS/ADS flow is the same synthesis-only flow used in the
    # regional probes. Both REAL target periods are declared. There are no
    # clock groups, false paths or relaxed periods to mask a crossing.
    clock=run/'clock.fdc';clock.write_text('create_clock -name memory_clk -period 8.000 [get_ports clk]\ncreate_clock -name processing_clk -period 6.666667 [get_ports processing_clk]\n')
    modules=['frame_manager_pkg.sv']+[n for n in hashes if n.endswith(('.v','.sv')) and n not in ['frame_manager_pkg.sv','tb_geometry_frame_processor.sv']]
    flow='set_dir -impl_directory {'+run.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
    flow+=''.join('add_design {'+(build/n).as_posix()+'}\n' for n in modules)
    flow+='add_constraint {'+clock.as_posix()+'}\ncompile -top_module geometry_processing_domain -system_verilog\n'
    flow+='synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing false -selected_syn_tool_opt 2\n'
    (run/'flow.tcl').write_text(flow);shutil.copyfile(__file__,run/'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'),run/'route_supervisor.py')
    out=dict(passed=False,proof=str(proof),proof_source_hashes=hashes,source_hashes=mapped_hashes,
             projective=args.projective,integration_proof=str(args.integration_proof) if args.integration_proof else None,
             production_instantiated=False,
             routed=False,timing_signed_off=False,cdc_constraints_signed_off=False,bitstream_generated=False)
    print('PROCESSING_DOMAIN_MAPPING',run,flush=True)
    try:
        supervision=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(run/'flow.tcl'),'-work_dir',str(run)],
            cwd=run,log_path=run/'syn.log',monitor_path=run/'synthesis_monitor.jsonl',timeout_seconds=1200,pause_path=args.pause_file)
        log=(run/'syn.log').read_text(errors='replace');out['supervision']=supervision
        out['errors']=re.findall(r'^E:.*',log,re.M)
        if supervision['status']!='COMPLETED' or out['errors']:raise RuntimeError('Experimental synthesis did not complete')
        report=run/'synthesize/geometry_processing_domain.snr';text=report.read_text(errors='replace')
        out['resources']={k:int(re.search(pattern,text)[1]) for k,pattern in [('LUT',r'Total LUTs: (\d+)'),('FF',r'Total Registers: (\d+)'),('controlsets',r'Number of unique control sets : (\d+)')]}
        out['report_sha256']=sha(report);out['passed']=True
    finally:
        out['inputs_intact']=all(sha(build/n)==h for n,h in mapped_hashes.items())
        out['passed'] &= out['inputs_intact'];(run/'result.json').write_text(json.dumps(out,indent=2))
        print('PROCESSING_DOMAIN_MAPPING_RESULT',run,flush=True)
    if not out['passed']:raise SystemExit(1)

if __name__=='__main__':main()

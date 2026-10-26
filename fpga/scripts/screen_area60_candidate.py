"""Run serialized, bounded native SYN comparisons for area candidates.

Dynamic unit ports avoid board constant propagation, so these measurements
screen hypotheses only. A final full-board explicit-SCF MAP is still required.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
from route_supervisor import run_supervised
from regional_scan_wrapper import ports


def sha(path):
    """Bind native source and reports to the tested candidate."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Use identical installed-device settings on both immutable inputs."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate',type=Path,required=True)
    parser.add_argument('--proof',type=Path,required=True)
    units={
      'geometry_tile_refill':('memory','.sv',[],{}),
      'dma_pixel_pack':('memory','.v',[],{}),
      'frame_memory_fabric':('memory','.sv',['memory/frame_manager_pkg.sv','memory/frame_manager_layout.vh','memory/frame_pool_bank.sv','memory/frame_manager.sv','memory/ddr_native_dma.v'],{'BOARD_CLIENT_LIMITS':'1'}),
      'mcu_readonly_client':('control','.sv',['control/uart_v2_parser.sv'],{'CONFIG_DIGEST_ONLY':'1'}),
      'pose_frame_selector':('control','.sv',[],{}),
      'pc_reference_upload':('control','.sv',[],{'ENTITY_MASK':"16'h1bca"}),
      'isp_colour_control':('isp','.sv',[],{'SUPPORT_AUTO':'0'}),
      'rgb_frame_statistics':('isp','.sv',[],{'SUPPORT_ABORT':'1'}),
      'motion_config_bank':('stabilization','.sv',[],{'SUPPORT_VIEWPORT':'0'})}
    parser.add_argument('--top',choices=list(units),required=True)
    a=parser.parse_args();fpga=Path(__file__).resolve().parents[1]
    candidate=a.candidate.resolve();proof=a.proof.resolve()
    if not candidate.is_relative_to(fpga/'build/area60_20261025'):raise ValueError('Area candidate required')
    checked=json.loads((proof/'result.json').read_text());assert checked['passed'] and checked['inputs_intact']
    assert all(sha(Path(p))==h for p,h in checked['origins'].items())
    identity=json.loads((candidate/'candidate.json').read_text());base=Path(identity['baseline'])
    group,suffix,dependencies,parameters=units[a.top]
    module_path='rtl/'+group+'/'+a.top+suffix
    for root in (candidate,base):
        p=root/'source'/module_path
        assert checked['origins'].get(str(p))==sha(p)
    run=candidate/datetime.now().strftime('screen_%Y%m%d_%H%M%S_%f');run.mkdir()
    shutil.copyfile(__file__,run/'screen_script.py')
    shutil.copyfile(fpga/'scripts/route_supervisor.py',run/'route_supervisor.py')
    result=dict(passed=False,proof=str(proof),proof_sha256=sha(proof/'result.json'),jobs=[],routed=False)
    print('AREA_SCREEN',run,flush=True)
    try:
        for label,root in [('baseline',base),('candidate',candidate)]:
            job=run/label;job.mkdir();source=job/(a.top+suffix);shutil.copyfile(root/'source'/module_path,source)
            inputs=[]
            for n in dependencies:
                p=root/'source/rtl'/n;target=job/p.name;shutil.copyfile(p,target)
                if p.suffix!='.vh':inputs.append(target)
            inputs.append(source)
            header=re.sub(r'\bsigned\s+','',source.read_text())
            if a.top=='frame_memory_fabric':
                for n,v in re.findall(r'^`define\s+(\w+)\s+(\d+)\s*$',(job/'frame_manager_layout.vh').read_text(),re.M):header=header.replace('`'+n,v)
            declared=ports(header,a.top,{'N':6,'TAG_BITS':192})
            params=dict(parameters)
            if label=='candidate' and a.top=='pc_reference_upload':params['STREAM_CCM']='1'
            if label=='candidate' and a.top=='isp_colour_control':params['CCM_PREVALIDATED']='1'
            # Keep every unit port dynamic but specialize only real board
            # capabilities. Both sides use the same exact signal boundary.
            wrapper='// Diagnostic only: identical dynamic ports; no I/O cells.\nmodule area_unit(\n'
            wrapper+=',\n'.join(d+' '+('['+str(w-1)+':0] ' if w>1 else '')+n for d,n,w in declared)+');\n'
            wrapper+=a.top+(' #('+','.join('.'+n+'('+v+')' for n,v in params.items())+')' if params else '')+' dut('+','.join('.'+n+'('+n+')' for d,n,w in declared)+');\nendmodule\n'
            (job/'area_unit.sv').write_text(wrapper);inputs.append(job/'area_unit.sv')
            # These selected units run in the 125 MHz DDR/user clock domain.
            (job/'clock.fdc').write_text('create_clock -name clk -period 8.000000 [get_ports clk]\n')
            flow='set_dir -impl_directory {'+job.as_posix()+'}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow+=''.join('add_design {'+p.as_posix()+'}\n' for p in inputs)+'add_constraint {'+(job/'clock.fdc').as_posix()+'}\n'
            flow+='compile -top_module area_unit -system_verilog\n'
            flow+='synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing true -selected_syn_tool_opt 2\n'
            (job/'flow.tcl').write_text(flow,encoding='utf-8')
            native=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(job/'flow.tcl'),'-work_dir',str(job)],
                cwd=job,log_path=job/'native.log',monitor_path=job/'monitor.jsonl',timeout_seconds=900,pause_path=run/'pause.json')
            errors=re.findall(r'^E:.*',(job/'native.log').read_text(errors='replace'),re.M)
            entry=dict(label=label,native=native,errors=errors,source_sha256=sha(source));result['jobs'].append(entry)
            if native['returncode'] or errors:raise RuntimeError('Native screen failed: '+label)
            report=job/'synthesize/area_unit.snr';text=report.read_text(errors='replace')
            entry['resources']={k:int(re.search(p,text)[1]) for k,p in dict(lut=r'Total LUTs: (\d+)',ff=r'Total Registers: (\d+)',control_sets=r'Number of unique control sets : (\d+)',lutram=r'LUTs as dram: (\d+)').items()}
            entry['report_sha256']=sha(report)
            apm=re.search(r'Total APMs = ([\d.]+)',text);entry['resources']['apm']=float(apm[1]) if apm else 0
            entry['frozen_inputs']={p.name:sha(p) for p in job.iterdir() if p.is_file() and p.suffix in ('.v','.sv','.vh','.tcl','.fdc')}
            print(label,json.dumps(entry['resources']),flush=True)
        result['passed']=True
    finally:
        result['inputs_intact']=all(sha(Path(p))==h for p,h in checked['origins'].items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    if not result['passed']:raise SystemExit(1)


if __name__=='__main__':
    main()

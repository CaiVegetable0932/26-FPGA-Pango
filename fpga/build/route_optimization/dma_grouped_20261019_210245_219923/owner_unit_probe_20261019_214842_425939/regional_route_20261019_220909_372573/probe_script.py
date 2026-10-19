"""Route only a proof-checked isolated DMA/boot pair; never generate bitstreams.

Installed PDS User Guide pp111-118, 249 and 251-254 and the frozen
PG2L100H pnr help define this bounded flow. Dynamic boundary ports use an
identical registered scan wrapper with legal IO buffers on both sides.
Results describe this isolated fixture, not board timing signoff.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil

from route_supervisor import run_supervised
from regional_scan_wrapper import ports,make_wrapper


def digest(path):
    """Bind diagnostic inputs and preserve native report identities."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Require successful A/B synthesis before an isolated physical screen."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--screen', type=Path, required=True)
    parser.add_argument('--pause-file', type=Path, required=True)
    parser.add_argument('--timeout-minutes', type=int, default=20)
    args = parser.parse_args()
    if not 1 <= args.timeout_minutes <= 20:
        parser.error('Regional screen allowance must be 1..20 minutes')
    fpga = Path(__file__).resolve().parents[1]
    screen = args.screen.resolve()
    if not screen.is_relative_to(fpga/'build/route_optimization'):
        raise ValueError('A reviewed regional screen is required')
    checked = json.loads((screen/'result.json').read_text(encoding='utf-8'))
    if not checked.get('passed') or not checked.get('inputs_intact'):
        raise ValueError('Both cycle-checked synthesis screens must pass first')
    if any(digest(Path(p)) != h for p,h in checked['inputs'].items()):
        raise ValueError('Synthesis input drift')
    top_match = re.search(r'compile -top_module (\w+) ',
                         (screen/'baseline/flow.tcl').read_text(encoding='utf-8'))
    if not top_match or top_match[1] not in ('ddr_native_dma','pc_video_boot'):
        raise ValueError('Only the two reviewed isolated tops are authorized')
    top = top_match[1]
    port_lists=[]
    for label in ('baseline','candidate'):
        filename='dma.v' if top=='ddr_native_dma' else 'pc_video_boot.sv'
        port_lists.append(ports((screen/label/filename).read_text(encoding='utf-8'),
                                top,dict(CLIENTS=7,TAG_BITS=32)))
    if port_lists[0]!=port_lists[1]:
        raise ValueError('A/B DUT port boundaries differ')
    wrapper,wrapper_metadata=make_wrapper(port_lists[0],top)
    # Reconstruct each diagnostic source from the functionally proven input.
    # The DMA screen changes only VERIFY_WRITES's isolated default to one.
    for label in ('baseline','candidate'):
        source = screen/label
        other_flow = (source/'flow.tcl').read_text(encoding='utf-8')
        normalized = other_flow.replace(source.as_posix(),'<REGION>')
        expected_flow = (screen/'baseline/flow.tcl').read_text(encoding='utf-8').replace(
            (screen/'baseline').as_posix(),'<REGION>')
        if normalized != expected_flow:
            raise ValueError('A/B synthesis settings differ')
        candidate = screen.parent
        if top == 'ddr_native_dma':
            original = (candidate/'original_ddr_native_dma.v' if label=='baseline' else
                        candidate/'source/rtl/memory/ddr_native_dma.v')
            expected = original.read_text(encoding='utf-8').replace(
                'parameter VERIFY_WRITES=0','parameter VERIFY_WRITES=1',1)
            if (source/'dma.v').read_text(encoding='utf-8') != expected:
                raise ValueError('Diagnostic DMA source drift')
        else:
            original = (candidate/'original_pc_video_boot.sv' if label=='baseline' else
                        candidate/'source/rtl/control/pc_video_boot.sv')
            if digest(source/'pc_video_boot.sv') != digest(original):
                raise ValueError('Diagnostic boot source drift')
            for name in ('uart_8n1.sv','uart_v2_parser.sv','parameter_entity_guard.sv'):
                if digest(source/name) != digest(candidate/'source/rtl/control'/name):
                    raise ValueError('Diagnostic dependency drift')
        if (source/'clock.fdc').read_text() != 'create_clock -name clk -period 8.000 [get_ports clk]\n':
            raise ValueError('Diagnostic clock constraint drift')
    run = screen/datetime.now().strftime('regional_route_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    shutil.copyfile(__file__,run/'probe_script.py')
    shutil.copyfile(Path(__file__).with_name('route_supervisor.py'),run/'route_supervisor.py')
    shutil.copyfile(Path(__file__).with_name('regional_scan_wrapper.py'),run/'regional_scan_wrapper.py')
    result = dict(scope='isolated_region', top=top, source_screen=str(screen),
                  board_timing_signoff=False, bitstream_generated=False,
                  hardware_tested=False, clock_period_ns=8.0, seed=11,
                  boundary='identical registered scan wrapper with legal IO buffers',
                  wrapper_metadata=wrapper_metadata,
                  wrapper_sha256=hashlib.sha256(wrapper.encode()).hexdigest(),
                  clean_build=True, jobs=[], completed=False)
    try:
        for label in ('baseline','candidate'):
            if args.pause_file.exists():
                raise RuntimeError('Regional pause requested')
            source = screen/label
            build = run/label
            build.mkdir()
            # Use a fresh isolated project and byte-identical diagnostic RTL.
            # Keep compile time separate in the native logs; no cache-speed claim.
            files = [p for p in source.iterdir() if p.suffix in ('.v','.sv','.fdc')]
            for p in files:
                shutil.copyfile(p,build/p.name)
            wrapper_path=build/'regional_wrapper.sv'
            wrapper_path.write_text(wrapper,encoding='utf-8',newline='\n')
            flow = (source/'flow.tcl').read_text(encoding='utf-8')
            if 'disable_io_insertion' not in flow or any(
                    token in flow for token in ('gen_bit_stream','pnr ','dev_map')):
                raise ValueError('Unexpected regional synthesis flow')
            flow = flow.replace(source.as_posix(),build.as_posix())
            # Physical DRC requires real IO buffers. The identical scan wrapper
            # supplies a small legal package boundary without tying DUT ports.
            flow=flow.replace(f'compile -top_module {top} ',
                f'add_design {{{wrapper_path.as_posix()}}}\ncompile -top_module regional_wrapper ')
            flow=flow.replace(' -disable_io_insertion','')
            flow += 'dev_map\n'
            flow += (f'pnr -action_timeout {args.timeout_minutes} -gplace_seed 11 '
                     '-plc_decongestion 1 -max_ctrl_chain_length 500 '
                     '-mode normal -congest_overlap_limit 200 '
                     '-dump_router_congestion_plot TRUE\n')
            flow += 'report_timing -delay_type min_max -max_path 30 -report_exception TRUE\n'
            script = build/'flow.tcl'
            script.write_text(flow,encoding='utf-8')
            inputs = {p.name:digest(build/p.name) for p in files}
            inputs[wrapper_path.name]=digest(wrapper_path)
            supervised = run_supervised(
                ['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe',
                 '-file',str(script),'-work_dir',str(build)],
                cwd=build,log_path=build/'physical.log',
                timeout_seconds=args.timeout_minutes*60,
                monitor_path=build/'physical_monitor.jsonl',
                pause_path=args.pause_file,watch_stall=True)
            text = (build/'physical.log').read_text(errors='replace')
            errors = re.findall(r'^E:.*',text,re.M)
            routed = build/'place_route/regional_wrapper_pnr.adf'
            report = build/'report_timing/regional_wrapper.rtr'
            intact = all(digest(build/name)==h for name,h in inputs.items())
            complete = (supervised['status']=='COMPLETED' and not errors and
                        intact and routed.is_file() and report.is_file())
            record = dict(label=label, supervision=supervised, error_count=len(errors),errors=errors[:20],
                          inputs=inputs, inputs_intact=intact, completed=complete,
                          wirelength=re.findall(r'Wirelength after detailed placement is (\d+)',text),
                          estimated_placement_slack_ps=re.findall(r'Worst slack is (-?\d+)',text),
                          report_sha256=digest(report) if report.exists() else None,
                          routed_db_sha256=digest(routed) if routed.exists() else None)
            result['jobs'].append(record)
            print(label,json.dumps(dict(completed=complete,status=supervised['status'],
                error_count=len(errors),first_errors=errors[:3],wirelength=record['wirelength'])),flush=True)
            if not complete:
                raise RuntimeError('Regional physical screen did not complete: '+label)
        result['completed']=True
    finally:
        result['finished_at']=datetime.now().astimezone().isoformat()
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n',encoding='utf-8')
        print('REGIONAL_ROUTE_RESULT',run,flush=True)


if __name__=='__main__':
    main()

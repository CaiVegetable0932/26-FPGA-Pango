"""Compare control RTL resource candidates with installed PG2L100H synthesis."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
from route_supervisor import run_supervised


def main():
    """Freeze each probe and serialize native jobs; abstract ports omit I/O."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--tops', nargs='+', default=['mcu_readonly_client'])
    options = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    root = fpga / 'build/mcu_resource_probes' / datetime.now().strftime('%Y%m%d_%H%M%S')
    root.mkdir(parents=True)
    shutil.copyfile(__file__, root/'probe_script.py')
    results = []
    for label, origin in [('baseline', options.baseline.resolve()), ('candidate', fpga)]:
        if not origin.is_relative_to(fpga):
            raise ValueError('probe source outside FPGA area')
        for top in options.tops:
            if top not in ('mcu_readonly_client', 'pc_video_boot', 'mcu_link_adapter'):
                raise ValueError('unsupported probe top')
            job = root/label/top
            job.mkdir(parents=True)
            paths = [origin/'rtl/memory/frame_manager_pkg.sv', *sorted((origin/'rtl/control').glob('*.sv'))]
            files = []
            for path in paths:
                dest = job/path.name
                shutil.copyfile(path, dest)
                if top=='pc_video_boot' and path.name=='pc_video_boot.sv':
                    # Probe the board's enabled entity mask, not default-only
                    # reference control. Both compared sources get this value.
                    dest.write_text(dest.read_text(encoding='utf-8').replace("ENTITY_MASK=16'h0200", "ENTITY_MASK=16'h1bee"), encoding='utf-8')
                files.append(dest)
            (job/'sources.json').write_text(json.dumps({p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in files},indent=2))
            (job/'clock.fdc').write_text('create_clock -name clk -period 8.0 [get_ports clk]\n')
            flow = f'set_dir -impl_directory {{{job.as_posix()}}}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            flow += ''.join(f'add_design {{{p.as_posix()}}}\n' for p in files)
            flow += f'add_constraint {{{(job/"clock.fdc").as_posix()}}}\n'
            flow += f'compile -top_module {top} -system_verilog\n'
            flow += 'synthesize -ads -disable_io_insertion -fanout_guide 64 -rw_check_on_ram -resource_sharing true -selected_syn_tool_opt 2\n'
            (job/'flow.tcl').write_text(flow)
            print('PROBE',label,top,job,flush=True)
            result = run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(job/'flow.tcl'),'-work_dir',str(job)],
                cwd=job,log_path=job/'native.log',monitor_path=job/'monitor.jsonl',timeout_seconds=1200)
            log = (job/'native.log').read_text(errors='replace')
            report = (job/'synthesize'/(top+'.snr')).read_text(errors='replace')
            lut = int(re.search(r'Total LUTs: (\d+)',report)[1])
            row = dict(label=label,top=top,lut=lut,native=result,errors=re.findall(r'^E:.*',log,re.M))
            results.append(row)
            (root/'result.json').write_text(json.dumps(results,indent=2))
            print(label,top,lut,flush=True)
            if result['returncode'] or row['errors']:
                raise RuntimeError('native probe failed')


if __name__ == '__main__':
    main()

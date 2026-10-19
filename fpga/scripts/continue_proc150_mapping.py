"""Continue a verified completed Compile DB through bounded SYN/MAP only."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,re,shutil
from route_supervisor import run_supervised
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--build',type=Path,required=True)
    p.add_argument('--pause-file',type=Path,required=True);a=p.parse_args();f=Path(__file__).resolve().parents[1]
    b=a.build.resolve();assert b.is_relative_to(f/'build/full_integration_20261013')
    parent=json.loads((b/'result.json').read_text());assert parent['experimental_proc150'] and parent['stage']=='dev_map'
    hashes=json.loads((b/'sources.json').read_text());assert all(sha(b/'source'/n)==v for n,v in hashes.items())
    compile_log=(b/'compile/run.log').read_text(errors='replace')
    assert 'Action compile: Real time elapsed' in compile_log
    db=b/'compile/pango_video_system_comp.adf';assert db.is_file() and not db.with_suffix('.adf.lock').exists()
    help_log=f/'build/route_optimization/session_20261019/native_map_help_0510/help.log'
    text=help_log.read_text();assert text.count('-input_db_file')==2 and text.count('-force_to_run')==2
    r=f/'build/route_optimization'/datetime.now().strftime('proc150_board_mapping_%Y%m%d_%H%M%S_%f');r.mkdir()
    shutil.copyfile(__file__,r/'continuation_script.py')
    prefix=(b/'flow.tcl').read_text().split('\ncompile ',1)[0]+'\n'
    prefix=prefix.replace(b.as_posix()+'}',r.as_posix()+'}',1)
    d=dict(passed=False,source_build=str(b),source_hashes=hashes,compile_db_sha256=sha(db),
           installed_help_sha256=sha(help_log),routed=False,bitstream_generated=False,phases=[])
    print('BOARD_MAPPING_CONTINUATION',r,flush=True)
    try:
        for action,budget in [('synthesize',1200),('dev_map',600)]:
            # SYN includes its slow database save; MAP gets its own allowance.
            # Both were fixed before launch and never request physical routing.
            command=action+' -force_to_run -input_db_file {'+db.as_posix()+'}'
            if action=='synthesize':command+=' -ads -rw_check_on_ram -resource_sharing false -fanout_guide 64 -selected_syn_tool_opt 2'
            flow=r/(action+'.tcl');flow.write_text(prefix+command+'\n')
            s=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(flow),'-work_dir',str(r)],cwd=r,
                log_path=r/(action+'.log'),monitor_path=r/(action+'_monitor.jsonl'),timeout_seconds=budget,pause_path=a.pause_file)
            d['phases'].append(dict(action=action,**s))
            log=(r/(action+'.log')).read_text(errors='replace')
            if s['status']!='COMPLETED' or s['returncode'] or re.search(r'^E:',log,re.M):raise RuntimeError(action+' failed')
            db=r/('synthesize' if action=='synthesize' else 'device_map')/('pango_video_system_'+('syn' if action=='synthesize' else 'map')+'.adf')
            assert db.is_file() and not db.with_suffix('.adf.lock').exists()
            d[action+'_db_sha256']=sha(db)
        d['passed']=True
    finally:
        d['inputs_intact']=all(sha(b/'source'/n)==v for n,v in hashes.items())
        d['passed'] &= d['inputs_intact'];(r/'result.json').write_text(json.dumps(d,indent=2))
        print('BOARD_MAPPING_RESULT',r,flush=True)
if __name__=='__main__':main()

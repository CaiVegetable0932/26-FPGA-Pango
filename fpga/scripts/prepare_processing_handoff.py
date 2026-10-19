"""Package a checked MAP for a separate routing agent; generate project only."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,re,shutil
from route_supervisor import run_supervised
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--mapping',type=Path,required=True)
    p.add_argument('--snapshot',type=Path,required=True);p.add_argument('--pause-file',type=Path,required=True)
    a=p.parse_args();f=Path(__file__).resolve().parents[1];m=a.mapping.resolve();b=a.snapshot.resolve()
    d=json.loads((m/'mapping_validation.json').read_text());assert d['passed']
    assert json.loads((m/'processing_mapping_audit.json').read_text())['passed']
    hs=json.loads((b/'sources.json').read_text());assert all(hs[n]==v for n,v in d['source_hashes'].items())
    assert all(sha(b/'source'/n)==v for n,v in hs.items())
    r=f/'build/full_integration_20261013'/datetime.now().strftime('handoff_%Y%m%d_%H%M%S_%f')
    shutil.copytree(b/'source',r/'source');shutil.copytree(m/'device_map',r/'device_map')
    (r/'sources.json').write_text(json.dumps(hs,indent=2))
    flow=(b/'flow.tcl').read_text().replace(b.as_posix(),r.as_posix());(r/'flow.tcl').write_text(flow)
    # tcl2prj parses a compile/SYN/MAP-only flow. It does not execute any of
    # those tasks and the package contains no placement or bitgen task.
    assert not re.search(r'^\s*(pnr|report_timing|gen_bit_stream)\b',flow,re.M)
    t=r/'generate_project.tcl';t.write_text('tcl2prj -tcl {'+(r/'flow.tcl').as_posix()+'}\n')
    supervision=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(t),'-work_dir',str(r)],
        cwd=r,log_path=r/'generation.log',monitor_path=r/'generation_monitor.jsonl',timeout_seconds=120,pause_path=a.pause_file)
    assert supervision['status']=='COMPLETED' and supervision['returncode']==0 and (r/'flow.pds').is_file()
    assert not re.search(r'^E:',(r/'generation.log').read_text(),re.M)
    assert all(sha(r/'source'/n)==v for n,v in hs.items())
    assert sha(r/'device_map/pango_video_system_map.adf')==sha(m/'device_map/pango_video_system_map.adf')
    record=dict(prepared=True,routed=False,bitstream_generated=False,mapping=str(m),source_snapshot=str(b),
        source_files=len(hs),native_inputs_identical=True,map_sha256=sha(r/'device_map/pango_video_system_map.adf'),
        physical_constraints_sha256=sha(r/'device_map/pango_video_system.pcf'),supervision=supervision,
        route_still_requires_current_readiness_gate=True)
    (r/'handoff_preparation.json').write_text(json.dumps(record,indent=2));print('PREPARED_HANDOFF',r)
if __name__=='__main__':main()

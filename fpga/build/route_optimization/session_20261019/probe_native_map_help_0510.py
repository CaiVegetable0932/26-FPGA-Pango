"""Read installed action syntax under the shared native tool lock."""
from pathlib import Path
import sys,json
S=Path(__file__).parent;F=S.parents[2];sys.path.insert(0,str(F/'scripts'))
from route_supervisor import run_supervised
r=S/'native_map_help_0510';r.mkdir()
(r/'help.tcl').write_text('help synthesize\nhelp dev_map\n')
d=run_supervised(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(r/'help.tcl'),'-work_dir',str(r)],cwd=r,log_path=r/'help.log',monitor_path=r/'monitor.jsonl',timeout_seconds=120,pause_path=S/'regional_stop_requested.json')
(r/'result.json').write_text(json.dumps(d,indent=2));print((r/'help.log').read_text(errors='replace'))

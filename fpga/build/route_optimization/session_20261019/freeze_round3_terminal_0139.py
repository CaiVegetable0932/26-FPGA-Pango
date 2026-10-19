"""Freeze terminal regional evidence and the unpromoted round-4 functional proof."""
from pathlib import Path
import hashlib,json,zipfile
ROOT=Path(__file__).resolve().parents[4];S=Path(__file__).resolve().parent
B=ROOT/'fpga/build/route_optimization/dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874/regional_route_20261020_012352_959075'
R=ROOT/'fpga/build/route_optimization/dma_stats_only_20261020_013741_777089'
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
files={Path(__file__).resolve(),S/'dma_round3_terminal_review_20261020.json',S/'head_source_coherence_20261020.json',ROOT/'fpga/scripts/prepare_dma_stats_only.py'}
for p in B.rglob('*'):
 if p.is_file() and p.suffix.lower() in {'.json','.jsonl','.log','.py','.tcl','.v','.sv','.fdc','.pds'}:files.add(p)
archive=B/'native_checkpoints.zip';members={}
with zipfile.ZipFile(archive,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
 for p in sorted((B/'candidate').rglob('*')):
  if p.is_file() and (p.suffix.lower() in {'.adf','.vm','.snr','.dmr','.prr','.rtr','.prt','.netlist','.pcf'} or 'CongestionNetInfo' in p.name):
   name=p.relative_to(B).as_posix();z.write(p,name);members[name]={'sha256':sha(p),'bytes':p.stat().st_size}
with zipfile.ZipFile(archive) as z:
 assert z.testzip() is None
 assert all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
manifest=B/'native_checkpoints_manifest.json';manifest.write_text(json.dumps({'archive_sha256':sha(archive),'members':members,'terminal_status':'COMPLETED_TIMING_FAILED'},indent=2));files.update([archive,manifest])
for name in ['source','differential_20261020_013748_090735','generic_parameters_20261020_013828_716013']:
 for p in (R/name).rglob('*'):
  if p.is_file() and p.suffix.lower() not in {'.vvp','.exe','.o'}:files.add(p)
for p in R.iterdir():
 if p.is_file():files.add(p)
for name in ['route_optimization_progress_20261019.md','route_optimization_handoff_20261020.md']:files.add(ROOT/'fpga/reports'/name)
entries={p.relative_to(ROOT).as_posix():{'bytes':p.stat().st_size,'sha256':sha(p)} for p in sorted(files)}
m=S/'round3_terminal_0139_manifest.json';m.write_text(json.dumps({'files':entries},indent=2))
(S/'round3_terminal_0139_scope.txt').write_text('\n'.join(entries)+'\n'+m.relative_to(ROOT).as_posix()+'\n')
print(len(entries),sum(v['bytes'] for v in entries.values()))

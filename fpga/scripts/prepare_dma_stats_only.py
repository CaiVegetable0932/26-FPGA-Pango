"""Prepare round-4 statistics-only candidate against the verified main design."""
from datetime import datetime
import hashlib,json,shutil
from pathlib import Path
from prepare_dma_local_cursor import localize_stats

def main():
 fpga=Path(__file__).resolve().parents[1]
 manifest=fpga/'build/route_optimization/session_20261019/unpack_finalist/sources.json'
 names=json.loads(manifest.read_text())
 run=fpga/'build/route_optimization'/datetime.now().strftime('dma_stats_only_%Y%m%d_%H%M%S_%f')
 source=run/'source'; source.mkdir(parents=True)
 for name,expected in names.items():
  original=fpga/name
  if hashlib.sha256(original.read_bytes()).hexdigest()!=expected: raise ValueError('Main source changed: '+name)
  dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(original,dest)
 target=source/'rtl/memory/ddr_native_dma.v'
 before=target.read_bytes();(run/'original_ddr_native_dma.v').write_bytes(before)
 # Only move the max-wait comparison to constant client slices. RAM addressing,
 # the central cursor, masks, reset and all externally visible cycles stay intact.
 target.write_text(localize_stats(before.decode('utf-8').replace('\r\n','\n')),encoding='utf-8',newline='\n')
 hashes={n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names}
 (run/'sources.json').write_text(json.dumps(hashes,indent=2))
 (run/'candidate.json').write_text(json.dumps(dict(review_round=4,status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',reference='main_12_verified',changed_files=['rtl/memory/ddr_native_dma.v'],extra_payload_latency_cycles=0,storage_type_unchanged=True,local_cursor_copies=False),indent=2))
 shutil.copyfile(__file__,run/'prepare_script.py');print(run)
if __name__=='__main__':main()

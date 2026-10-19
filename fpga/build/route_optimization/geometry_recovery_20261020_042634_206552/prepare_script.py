"""Isolate the previous-cache-fault/new-frame initialization race fix."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,shutil

def fix_pipeline(text):
    old='if(busy && (cache_fault || (map_v && map_r && !map_ok))) frame_failed<=1;'
    new='''// cache_start is deliberately delayed one edge after frame admission.
   // Until that edge clears the cache's previous frame_error, it belongs to
   // the retired job. No new ray can reach the cache during initialization.
   if(busy && !cache_start && (cache_fault || (map_v && map_r && !map_ok))) frame_failed<=1;'''
    if text.count(old)!=1:raise ValueError('Unexpected cache initialization/fault gate')
    return text.replace(old,new)

def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args();f=Path(__file__).resolve().parents[1];base=args.baseline.resolve()
    hashes=json.loads((base/'sources.json').read_text())
    assert len(hashes)==290 and all(hashlib.sha256((base/'source'/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
    run=f/'build/route_optimization'/datetime.now().strftime('geometry_recovery_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name='rtl/geometry/geometry_rgb_pipeline.sv';target=run/'source'/name
    shutil.copyfile(target,run/'before_geometry_rgb_pipeline.sv')
    target.write_text(fix_pipeline(target.read_text()),encoding='utf-8',newline='\n')
    hashes[name]=hashlib.sha256(target.read_bytes()).hexdigest()
    (run/'sources.json').write_text(json.dumps(hashes,indent=2))
    (run/'selection.json').write_text(json.dumps(dict(status='RECOVERY_FIX_NOT_PROMOTED',
        baseline=str(base),changed_from_baseline=[name],latency_added_cycles=0,normal_frame_precision_unchanged=True,
        previous_frame_cache_fault_masked_only_during_existing_initialization=True),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print('GEOMETRY_RECOVERY_CANDIDATE',run)

if __name__=='__main__':main()

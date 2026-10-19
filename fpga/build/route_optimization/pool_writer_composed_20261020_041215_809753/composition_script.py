"""Compose only the isolated pool candidate with the current 13-change writer."""
from pathlib import Path
from datetime import datetime
import hashlib,json,shutil

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    f=Path(__file__).resolve().parents[1];s=f/'build/route_optimization/session_20261019'
    candidate=f/'build/route_optimization/pool_chunk8_20261020_034402_468921'
    main=json.loads((s/'writer_pipeline_finalist/sources.json').read_text())
    old=json.loads((candidate/'sources.json').read_text())
    name='rtl/memory/frame_pool_bank.sv';writer='rtl/memory/frame_pixel_writer.sv'
    assert len(main)==len(old)==290 and all(sha(f/n)==h for n,h in main.items())
    assert all(sha(candidate/'source'/n)==h for n,h in old.items())
    assert {n for n in main if main[n]!=old[n]}=={name,writer}
    run=f/'build/route_optimization'/datetime.now().strftime('pool_writer_composed_%Y%m%d_%H%M%S_%f')
    for n in main:
        src=candidate/'source'/n if n==name else f/n
        target=run/'source'/n;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(src,target)
    shutil.copyfile(f/name,run/'before_frame_pool_bank.sv')
    hashes={n:sha(run/'source'/n) for n in main}
    (run/'sources.json').write_text(json.dumps(hashes,indent=2))
    (run/'selection.json').write_text(json.dumps(dict(status='COMPOSED_FUNCTIONAL_AND_STABILITY_PROOFS_PENDING',
        promoted=False,changed_from_main13=[name],selected_if_accepted=14,whole_design_route_allowed=False,
        main_source_manifest=str(s/'writer_pipeline_finalist/sources.json'),pool_candidate=str(candidate)),indent=2))
    shutil.copyfile(__file__,run/'composition_script.py');print('POOL_WRITER_COMPOSED',run)

if __name__=='__main__':main()

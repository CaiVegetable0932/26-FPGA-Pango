"""Remove arbitration from the idle write-bank prefetch address.

When IDLE no native write/readback consumes write-bank payload. Prefetching
beat zero throughout IDLE is sufficient for every subsequent accepted owner;
read clients keep their own next_consumed cursor. All active-state cursors,
readback, arbitration, cancellation and descriptor ownership stay unchanged.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Freeze one two-line control alternative without editing current jobs."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Baseline must be under fpga/build')
    before=json.loads((base/'sources.json').read_text(encoding='utf-8'))
    if hashes(base/'source')!=before:
        raise ValueError('Baseline changed')
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('dma_prefetch_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name='rtl/memory/ddr_native_dma.v';path=run/'source'/name
    original=path.read_text(encoding='utf-8')
    text=replace_once(original,'''  else if(state==IDLE && chosen>=0 && !fault && controller_ready &&
          !cancel[chosen[CLIENT_BITS-1:0]]) next_beat_index=0;''', '''  // No write/readback payload is consumed in IDLE. Keep all write-bank
  // prefetches at beat zero even before an owner wins arbitration, removing
  // eligible/loaded -> arbiter -> RAM address from the synchronous read path.
  // Accepted ownership already resets beat_index to zero; read-client cursors
  // use next_consumed independently and preserve their stalled output data.
  else if(state==IDLE) next_beat_index=0;''')
    path.write_text(text,encoding='utf-8')
    (run/'original_ddr_native_dma.v').write_text(original,encoding='utf-8')
    after=hashes(run/'source')
    if {n for n in before if before[n]!=after[n]}!={name}:
        raise ValueError('Unexpected source difference')
    (run/'sources.json').write_text(json.dumps(after,indent=2),encoding='utf-8')
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),candidate=str(run),
        changed=[name],functional_pass=False,routed=False,minimum_corrected_fps=30,
        programmed=False),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'preparation_script.py')
    print(run,flush=True)


if __name__=='__main__':
    main()

"""Aggregate independent native attempts without touching running ledgers.

The first legacy driver may still hold its campaign state in memory. Private
parallel jobs therefore keep separate campaign files; this parent index is the
authoritative five-completion review counter. Router iterations never count.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path


def main():
    """Read every reserved job, publish one deterministic batch observation."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--index',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    path=args.index.resolve()
    if not path.is_relative_to(fpga/'build'):
        raise ValueError('Index must be under fpga/build')
    index=json.loads(path.read_text(encoding='utf-8'))
    members=index['members']
    if not 1<=len(members)<=5 or sorted(m['number'] for m in members)!=list(range(1,len(members)+1)):
        raise ValueError('Batch must reserve sequential attempt numbers within 1..5')
    observations=[]
    for member in members:
        state_path=Path(member['campaign']).resolve()
        if not state_path.is_relative_to(path.parent):
            raise ValueError('Job ledger must remain inside this batch')
        if not state_path.exists():
            observations.append(dict(number=member['number'],phase='reserved',complete=False,passed=False))
            continue
        state=json.loads(state_path.read_text(encoding='utf-8'))
        attempts=state.get('attempts',[])
        if len(attempts)>1:
            raise ValueError('Indexed job ledger must contain one attempt only')
        if not attempts:
            observations.append(dict(number=member['number'],phase='prepared',complete=False,passed=False))
            continue
        attempt=attempts[0]
        if attempt['number']!=member['number']:
            raise ValueError('Global attempt number mismatch')
        observations.append({k:attempt.get(k) for k in
            ('number','phase','build','source_build','complete','passed','started_at','finished_at','options')})
    index['observed_at']=datetime.now().astimezone().isoformat()
    index['observations']=observations
    index['completed_attempts']=sum(bool(a['complete']) for a in observations)
    index['passed']=any(bool(a['passed']) for a in observations)
    index['review_required']=index['completed_attempts']>=5 and not index['passed']
    path.write_text(json.dumps(index,indent=2),encoding='utf-8')
    print(json.dumps(index),flush=True)


if __name__=='__main__':
    main()

"""Assess a fixed-MAP policy experiment and the combined production candidate."""
import argparse
import hashlib
import json
import re
from pathlib import Path
from control_route_feedback import metrics


def sha(path):
    """Bind the comparison to preserved native evidence."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Keep policy causality separate from the combined RTL+policy decision."""
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--study',required=True,type=Path)
    ap.add_argument('--original',required=True,type=Path)
    ap.add_argument('--output',required=True,type=Path)
    ap.add_argument('--previous-study',type=Path,action='append',default=[],help='Preserve completed rejected trials in the comparison')
    a=ap.parse_args();study=json.loads(a.study.read_text())
    old=metrics(a.original.resolve(),1800);new=study['candidate']
    # Check saved comparison inputs again. Historical results are evidence,
    # not immutable merely because a prior script marked them passed.
    for row in [study['baseline'],new]:
        base=Path(row['folder'])
        for name,key in [('result.json','result_sha256'),('place_route.log','log_sha256'),('place_route_monitor.jsonl','monitor_sha256')]:
            assert sha(base/name)==row[key]
    allowed={study.get('study_option') or 'placement_decongestion','native_timeout_minutes','host_timeout_minutes'}
    options_equal=all(v==new['options'][k] for k,v in old['options'].items() if k not in allowed)
    checks=dict(valid_same_map_policy_experiment=study['passed'] and all(study['checks'].values()),
        only_declared_physical_parameter_changed=options_equal,original_input_intact=old['snapshot_intact'])
    n=new['window_best_unrouted'];o=old['window_best_unrouted']
    nw=new['wirelength'].get('detailed placement');ow=old['wirelength'].get('detailed placement')
    convergence=n is not None and o is not None and n<o
    wire=nw is not None and ow is not None and nw<=ow
    timing=new['placement_slack_raw'] is not None and old['placement_slack_raw'] is not None and new['placement_slack_raw']>=old['placement_slack_raw']
    result=dict(passed=all(checks.values()),checks=checks,baseline=old,candidate=new,
        experiment='combined_RTL_and_policy_vs_original',policy_study=study,
        policy_study_path=str(a.study.resolve()),policy_study_sha256=sha(a.study),
        convergence_better=convergence,wirelength_not_worse=wire,placement_timing_not_worse=timing,
        recommend_adoption=all(checks.values()) and (new['routing_completed'] or (convergence and wire and timing)),
        partial_run_is_not_signoff=not new['routing_completed'],hardware_tested=False,
        decision_basis='Combined candidate must improve original-baseline convergence and not regress original wirelength or placement slack. Separate same-MAP study isolates policy effects.')
    # Earlier rejected trials remain explicit, rather than disappearing when
    # a later policy is tested or selected.
    result['previous_policy_studies']=[dict(path=str(p.resolve()),sha256=sha(p),result=json.loads(p.read_text())) for p in a.previous_study]
    # Native placement fingerprints distinguish an actual placement change
    # from wall-time variation on an otherwise identical physical solution.
    fingerprints={}
    for key,row in [('prior',study['baseline']),('trial',new)]:
        text=(Path(row['folder'])/'place_route.log').read_text(errors='replace')
        fingerprints[key]=dict(re.findall(r'Wirelength after (.+?) is \d+ and checksum is ([A-F0-9]+)',text))
    result['placement_fingerprints']=fingerprints
    result['same_detailed_placement_checksum']=bool(fingerprints['prior'].get('detailed placement') and fingerprints['prior'].get('detailed placement')==fingerprints['trial'].get('detailed placement'))
    a.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({k:result[k] for k in ['passed','convergence_better','wirelength_not_worse','placement_timing_not_worse','recommend_adoption']}))


if __name__=='__main__':main()

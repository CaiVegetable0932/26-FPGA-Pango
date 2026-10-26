"""Compare bounded physical feedback at equal wall time, without claiming signoff."""
import argparse
from collections import Counter
import hashlib
import json
from pathlib import Path
import re
from route_supervisor import route_iterations
from implementation_readiness import require_routed_lut_budget


def sha(p):
    """Bind metrics to the exact native log and monitor bytes."""
    return hashlib.sha256(p.read_bytes()).hexdigest()


def metrics(folder, seconds):
    """Separate actual placement/router output from device capacity tables."""
    log=folder/'place_route.log'; monitor=folder/'place_route_monitor.jsonl'
    text=log.read_text(errors='replace'); result=json.loads((folder/'result.json').read_text())
    samples=[json.loads(line) for line in monitor.read_text().splitlines() if line.strip()]
    in_window=[s for s in samples if s['elapsed_seconds']<=seconds]
    # Monitoring is periodic. Record the actual last sampled time, not an
    # invented exact 30-minute count or a later completed router iteration.
    last=in_window[-1] if in_window else None
    first={}
    for sample in samples:
        for row in sample.get('rounds',[]):
            first.setdefault(str(row['iteration']),dict(first_observed_seconds=sample['elapsed_seconds'],**row))
    wire={name:int(value) for name,value in re.findall(r'Wirelength after (.+?) is (\d+)',text)}
    origins=re.findall(r'^Origin (.+?) replicates:',text,re.M)
    groups=Counter('/'.join(n.split('/')[:2]) if n.startswith('core/') else n.split('/')[0] for n in origins)
    copied=re.findall(r'^\s+CLM[AS]_\d+_\d+\(.+?\)\s+:\s+(.+)',text,re.M)
    slack=re.search(r'Worst slack is (-?\d+), TNS after placement is (-?\d+)',text)
    subnets=re.search(r'Total (\d+) subnets',text)
    try:
        routed_budget=require_routed_lut_budget(folder.parent)
        routing_completed='Routing done.' in text and routed_budget['below_70_percent']
    except (ValueError,KeyError):
        routing_completed=False
    return dict(folder=str(folder),result_sha256=sha(folder/'result.json'),log_sha256=sha(log),monitor_sha256=sha(monitor),
        snapshot_intact=result['snapshot_intact'],status=result['optimization_status'],options=result['physical_options'],
        wirelength=wire,placement_slack_raw=int(slack[1]) if slack else None,placement_tns_raw=int(slack[2]) if slack else None,
        replication_origins=len(origins),replicated_instances=len(copied),replication_by_group=dict(groups),
        total_subnets=int(subnets[1]) if subnets else None,rounds=route_iterations(text),first_observed_rounds=first,
        comparison_budget_seconds=seconds,window_sample_seconds=last['elapsed_seconds'] if last else None,
        window_best_unrouted=last.get('best_unrouted') if last else None,
        routing_completed=routing_completed,
        physical_timing_met=result.get('internal_timing_met') is True)


def main():
    """Use routing evidence as the decision input, with LUT only a capacity gate."""
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--baseline',type=Path,required=True);ap.add_argument('--candidate',type=Path,required=True)
    ap.add_argument('--output',type=Path,required=True);ap.add_argument('--seconds',type=int,default=1800)
    ap.add_argument('--study-decongestion', action='store_true', help='Compare the same MAP with only placement expansion changed')
    ap.add_argument('--study-option',choices=['placement_decongestion','mode'],help='The single declared policy parameter being varied')
    a=ap.parse_args(); old=metrics(a.baseline.resolve(),a.seconds); new=metrics(a.candidate.resolve(),a.seconds)
    excluded={'native_timeout_minutes','host_timeout_minutes'}
    study_option=a.study_option or ('placement_decongestion' if a.study_decongestion else None)
    if a.study_option and a.study_decongestion:raise ValueError('Specify only one policy study option')
    if study_option:excluded.add(study_option)
    options_equal={k:v for k,v in old['options'].items() if k not in excluded}=={k:v for k,v in new['options'].items() if k not in excluded}
    checks=dict(same_physical_options=options_equal,inputs_intact=old['snapshot_intact'] and new['snapshot_intact'])
    # A parameter experiment must hold the actual netlist and constraints
    # fixed. Its options are deliberately different, never label it a pure
    # RTL comparison or infer causality from two simultaneous changes.
    if study_option:
        checks['other_physical_options_equal']=checks.pop('same_physical_options')
        old_map=a.baseline.resolve().parent;new_map=a.candidate.resolve().parent
        files=['sources.json','device_map/pango_video_system_map.adf','device_map/pango_video_system.pcf']
        checks['same_mapped_input']=all(sha(old_map/n)==sha(new_map/n) for n in files)
        checks['only_declared_parameter_changed']=old['options'][study_option]!=new['options'][study_option]
    # Partial routing is only an early-convergence result. Require both fewer
    # unresolved connections at equal time and no increase in detailed wire
    # length before recommending adoption from a bounded diagnostic.
    old_n=old['window_best_unrouted'];new_n=new['window_best_unrouted']
    old_w=old['wirelength'].get('detailed placement');new_w=new['wirelength'].get('detailed placement')
    convergence_better=old_n is not None and new_n is not None and new_n<old_n
    wire_not_worse=old_w is not None and new_w is not None and new_w<=old_w
    timing_not_worse=old['placement_slack_raw'] is not None and new['placement_slack_raw'] is not None and new['placement_slack_raw']>=old['placement_slack_raw']
    recommendation=all(checks.values()) and (new['routing_completed'] or (convergence_better and wire_not_worse and timing_not_worse))
    result=dict(passed=all(checks.values()),checks=checks,baseline=old,candidate=new,
        experiment='same_MAP_policy' if study_option else 'same_options_RTL',study_option=study_option,
        convergence_better=convergence_better,wirelength_not_worse=wire_not_worse,
        placement_timing_not_worse=timing_not_worse,
        recommend_adoption= recommendation,
        decision_basis='Actual routing completion, or fewer unrouted connections at equal sampled wall time with non-increasing detailed-placement wirelength and non-worsening placement slack; LUT is not a performance score.',
        partial_run_is_not_signoff=not new['routing_completed'],hardware_tested=False)
    a.output.parent.mkdir(parents=True,exist_ok=True)
    a.output.write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps(result),flush=True)


if __name__=='__main__':main()

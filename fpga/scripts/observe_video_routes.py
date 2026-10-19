"""Record native route and placement-probe observations without changing builds."""
import argparse
from datetime import datetime
import json
from pathlib import Path
import re
import subprocess


def process_inventory():
    """Read only PDS process metadata; paths never enter executable shell text."""
    command = (
        "Get-CimInstance Win32_Process -Filter \"name='pds_shell.exe'\" | "
        "ForEach-Object { $taskInfo = Get-Process -Id $_.ProcessId -ErrorAction SilentlyContinue; "
        "[pscustomobject]@{ PID=$_.ProcessId; Parent=$_.ParentProcessId; "
        "CPU=$taskInfo.CPU; WorkingSetBytes=$taskInfo.WorkingSet64; "
        "PrivateBytes=$taskInfo.PrivateMemorySize64; CommandLine=$_.CommandLine } } | "
        "ConvertTo-Json -Compress"
    )
    output = subprocess.run(
        ['powershell', '-NoProfile', '-Command', command], capture_output=True,
        text=True, check=True, creationflags=0x08000000).stdout.strip()
    rows = json.loads(output) if output else []
    return [rows] if isinstance(rows, dict) else rows


def observe(build_root, attempt, processes):
    """Separate detailed iterations from similarly worded global-route output.

    A log without completion, or a placement slack estimate, provides no STA
    signoff. Process presence and CPU snapshots only establish current activity.
    """
    build = build_root / attempt['build']
    log = build / attempt['resume'] / 'place_route.log'
    content = log.read_text(errors='replace')
    prefix = build.resolve().as_posix().lower() + '/'
    owned = [row for row in processes
             if prefix in (row.get('CommandLine') or '').replace('\\', '/').lower()]
    matches = re.findall(
        r'Unrouted nets (\d+) at the end of iteration (\d+)\.\s*'
        r'route iteration \d+, CPU time elapsed ([\d.]+) sec\.', content)
    totals = re.findall(r'Total (\d+) subnets\.', content)
    detail = None
    if matches:
        remaining, iteration, cpu = matches[-1]
        detail = dict(iteration=int(iteration), unrouted=int(remaining),
                      total_subnets=int(totals[-1]), iteration_cpu_seconds=float(cpu))
    phase_lines = re.findall(r'^Phase [^\n]+', content, re.M)
    phase = 'detailed_route' if detail else ('routing' if 'Routing started.' in content else 'placement')
    result_file = build / 'result.json'
    result = json.loads(result_file.read_text(encoding='utf-8')) if result_file.exists() else {}
    return dict(build=attempt['build'], resume=attempt['resume'],
                session=attempt.get('session'), processes=owned, observed_phase=phase, detailed_route=detail,
                last_placement_phase=phase_lines[-1] if phase_lines else None,
                log_bytes=log.stat().st_size,
                log_modified=datetime.fromtimestamp(log.stat().st_mtime).astimezone().isoformat(),
                native_errors=re.findall(r'^E:.*', content, re.M),
                result_native_runs=result.get('native_runs', []),
                result_internal_timing_met=result.get('internal_timing_met', False),
                routed_database_present=(build / 'place_route/pango_video_system_pnr.adf').is_file(),
                bitstream_present=(build / 'generate_bitstream/pango_video_system.sbit').is_file(),
                tail=content[-400:])


def observe_placement_probe(build_root, probe, processes):
    """Expose one cheap placement trial separately from real routed candidates.

    A PLC or placement-only PASS never establishes routing or timing signoff.
    An incomplete JSON write is reported as pending and retried on the next
    observation; it must not cause an otherwise healthy build to be restarted.
    """
    build = build_root / probe['build']
    evidence = build / probe['evidence']
    path = evidence / 'place_only.log'
    content = path.read_text(errors='replace') if path.exists() else ''
    prefix = build.resolve().as_posix().lower() + '/'
    owned = [{key: row.get(key) for key in ('PID', 'Parent', 'CPU', 'PrivateBytes')}
             for row in processes
             if prefix in (row.get('CommandLine') or '').replace('\\', '/').lower()]
    phases = re.findall(r'^Phase [^\n]+', content, re.M)
    try:
        result = json.loads((evidence / 'result.json').read_text(encoding='utf-8'))
    except (FileNotFoundError, json.JSONDecodeError):
        result = None
    return dict(build=probe['build'], session=probe.get('session'),
                kind='placement_only', processes=owned,
                last_phase=phases[-1] if phases else None,
                native_errors=re.findall(r'^E:.*', content, re.M),
                result=result, timing_signoff=False, bitstream_generated=False)


def main():
    """Append observations only in the FPGA build tree; never alter native files."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--state', type=Path,
                        default=Path('fpga/build/full_integration_20261013/active_work_state.json'))
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    state_path = args.state.resolve()
    if not state_path.is_relative_to(fpga / 'build'):
        raise ValueError('route observations belong inside the FPGA build tree')
    state = json.loads(state_path.read_text(encoding='utf-8'))
    processes = process_inventory()
    record = dict(observed_at=datetime.now().astimezone().isoformat(),
                  attempts=[observe(state_path.parent, attempt, processes)
                            for attempt in state['active_native_attempts']])
    # Keep the placement-only alternative out of routed-candidate accounting.
    if state.get('placement_probe'):
        record['placement_probe'] = observe_placement_probe(
            state_path.parent, state['placement_probe'], processes)
        state['placement_probe']['last_observation'] = record['placement_probe']
        state['placement_probe']['last_observed_at'] = record['observed_at']
    # Keep a time series for long native iterations instead of declaring a
    # failure from one unchanged log tail. Existing build evidence is untouched.
    with (state_path.parent / 'route_observations.jsonl').open('a', encoding='utf-8') as log:
        log.write(json.dumps(record, ensure_ascii=False)+'\n')
    # Refresh only observation fields in the work ledger. Native completion,
    # timing and release decisions remain the responsibility of the build
    # driver; a current process or a partially written database proves neither.
    observations = {row['build']: row for row in record['attempts']}
    for attempt in state['active_native_attempts']:
        observed = observations[attempt['build']]
        attempt['last_observed_at'] = record['observed_at']
        attempt['last_observed_phase'] = observed['observed_phase']
        attempt['last_observed_processes'] = [
            {key: process.get(key) for key in ('PID', 'Parent', 'CPU', 'PrivateBytes')}
            for process in observed['processes']]
        if observed['detailed_route']:
            attempt['last_observed_route'] = dict(
                observed['detailed_route'], observed_at=record['observed_at'])
        if attempt['build'] == state['latest_board']:
            state['last_observed_route'] = attempt.get('last_observed_route')
    state['last_native_observation_at'] = record['observed_at']
    state_path.write_text(json.dumps(state, ensure_ascii=False, indent=2)+'\n', encoding='utf-8')
    summary = dict(observed_at=record['observed_at'], attempts=[])
    if 'placement_probe' in record:
        summary['placement_probe'] = record['placement_probe']
    for attempt in record['attempts']:
        row = {key: value for key, value in attempt.items()
               if key not in ('processes', 'tail', 'last_placement_phase', 'result_native_runs')}
        row['processes'] = [{key: process.get(key) for key in ('PID', 'Parent', 'CPU', 'PrivateBytes')}
                            for process in attempt['processes']]
        summary['attempts'].append(row)
    print(json.dumps(summary, ensure_ascii=False))


if __name__ == '__main__':
    main()

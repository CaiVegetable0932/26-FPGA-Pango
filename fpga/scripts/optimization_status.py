"""Record project progress and account quota without retaining chat payloads.

Only timestamp and rate-limit fields are read from recent local Codex event
logs. Authentication files and conversation content are never exported.
"""
import argparse
from datetime import datetime, timezone
import json
from pathlib import Path
import time
from route_supervisor import process_resources


def latest_quota(sessions):
    """Return the newest explicit account limit event, never a token estimate."""
    records = []
    files = sorted(sessions.rglob('*.jsonl'), key=lambda p: p.stat().st_mtime, reverse=True)[:3]
    for path in files:
        with path.open('rb') as stream:
            stream.seek(max(0, path.stat().st_size-512_000))
            for line in stream:
                if b'"rate_limits"' not in line:
                    continue
                try:
                    event = json.loads(line)
                    limits = event.get('payload', {}).get('rate_limits')
                    if event.get('type') != 'event_msg' or not limits:
                        continue
                    windows = {key: limits[key] for key in ('primary', 'secondary')
                               if limits.get(key) is not None}
                    if windows:
                        records.append(dict(at=event['timestamp'], windows=windows))
                except (ValueError, KeyError):
                    continue
    if not records:
        return dict(available=False, remaining_percent=None)
    record = max(records, key=lambda r: r['at'])
    remaining = min(100-window['used_percent'] for window in record['windows'].values())
    return dict(available=True, remaining_percent=remaining, **record)


def record_status(session, codex_sessions):
    """Append one sample and stop only this session at the account reserve."""
    root = Path(__file__).resolve().parents[1]
    session = session.resolve()
    if not session.is_relative_to(root/'build/route_optimization'):
        raise ValueError('Optimization records must stay under fpga/build/route_optimization')
    quota = latest_quota(codex_sessions)
    now = datetime.now(timezone.utc)
    age = ((now-datetime.fromisoformat(quota['at'].replace('Z', '+00:00'))).total_seconds()
           if quota['available'] else None)
    # A stale/missing sample cannot prove that the requested reserve remains.
    stop = quota['available'] and quota['remaining_percent'] <= 10
    record = dict(observed_at=now.isoformat(), quota=quota, quota_age_seconds=age,
                  stop_new_optimization=stop, quota_fresh=age is not None and age < 300,
                  campaigns=[])
    for path in session.glob('*/campaign.json'):
        state = json.loads(path.read_text(encoding='utf-8'))
        for attempt in state.get('attempts', []):
            build = Path(attempt['build'])
            monitors = sorted(build.glob('resume_*/*_monitor.jsonl'))
            current = None
            if monitors:
                lines = monitors[-1].read_text(encoding='utf-8').splitlines()
                current = json.loads(lines[-1]) if lines else None
            resources = process_resources(current['pid']) if current and current['status']=='RUNNING' else None
            record['campaigns'].append(dict(path=str(path), attempt=attempt,
                                           monitor=current, observed_resources=resources))
    with (session/'quota_observations.jsonl').open('a', encoding='utf-8') as stream:
        stream.write(json.dumps(record, ensure_ascii=False)+'\n')
    if stop:
        # Existing supervisors observe this explicit session stop request. It
        # applies only to builds launched with this session's --pause-file.
        (session/'stop_requested.json').write_text(json.dumps(dict(
            reason='Codex account remaining quota <= 10 percent', quota=quota), indent=2))
    return record


def main():
    """Optionally watch in 30-second steps until reserve or session completion."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--session', type=Path, required=True)
    parser.add_argument('--codex-sessions', type=Path, default=Path.home()/'.codex/sessions')
    parser.add_argument('--watch', action='store_true')
    args = parser.parse_args()
    while True:
        record = record_status(args.session, args.codex_sessions)
        if not args.watch:
            print(json.dumps(record, ensure_ascii=False))
            return
        # Keep terminal output compact; complete resource evidence stays in
        # the session JSONL. The assistant sends the requested hourly report.
        print(json.dumps(dict(at=record['observed_at'], quota=record['quota'],
                              stop=record['stop_new_optimization'],
                              phases=[c['monitor']['status'] if c['monitor'] else c['attempt']['phase']
                                      for c in record['campaigns']])), flush=True)
        if record['stop_new_optimization'] or (args.session/'session_complete.json').exists():
            return
        time.sleep(30)


if __name__ == '__main__':
    main()

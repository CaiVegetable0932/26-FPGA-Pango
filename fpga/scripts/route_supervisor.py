"""Supervise an owned PDS process and retain native convergence evidence.

This supervisor changes no device, clocks, source bytes or timing gates. A
timeout or convergence stall is a failed experiment, never routed signoff.
"""
from datetime import datetime, timezone
from contextlib import contextmanager
import json
import math
import os
from pathlib import Path
import re
import signal
import subprocess
import time


def process_resources(pid):
    """Sample the owned tree; unavailable counters remain explicitly unknown.

    Optional psutil enriches evidence without becoming a native-build
    dependency. RSS totals are sampled usage, not a claimed exact peak.
    """
    try:
        import psutil
    except ImportError:
        return dict(available=False, reason='psutil is not installed')
    try:
        root = psutil.Process(pid)
        processes = [root, *root.children(recursive=True)]
    except psutil.Error:
        return dict(available=False, reason='owned process already exited')
    rows = []
    for process in processes:
        try:
            memory = process.memory_info()
            cpu = process.cpu_times()
            rows.append(dict(pid=process.pid, name=process.name(),
                             created_at=process.create_time(), cpu_seconds=cpu.user+cpu.system,
                             rss_bytes=memory.rss, private_bytes=getattr(memory, 'private', None),
                             peak_working_set_bytes=getattr(memory, 'peak_wset', None)))
        except psutil.Error:
            continue
    return dict(available=bool(rows), processes=rows,
                sampled_rss_bytes=sum(row['rss_bytes'] for row in rows),
                sampled_cpu_seconds=sum(row['cpu_seconds'] for row in rows))


def route_iterations(content):
    """Parse completed detailed-route rounds, excluding global-route text."""
    matches = re.findall(
        r'Unrouted nets (\d+) at the end of iteration (\d+)\.\s*'
        r'route iteration \d+, CPU time elapsed ([\d.]+) sec\.', content)
    return [dict(iteration=int(i), unrouted=int(n), cpu_seconds=float(cpu))
            for n, i, cpu in matches]


def stalled(rounds, window=5, minimum=1000, improvement=0.01, warmup=5):
    """Compare five completed transitions after the first five warmup rounds.

    Use the best value in the window rather than just the last round, so a
    temporary regression cannot hide real progress. Near convergence retains
    the hard timeout but does not use this percentage threshold.
    """
    if len(rounds) < warmup + window:
        return False
    recent = rounds[-(window + 1):]
    start = recent[0]['unrouted']
    best = min(row['unrouted'] for row in recent)
    return best > minimum and (start - best) / start < improvement


def live_descendants(known):
    """Revalidate PID plus creation time before acting on a prior descendant."""
    try:
        import psutil
    except ImportError:
        return []
    alive = []
    for row in known.values():
        try:
            process = psutil.Process(row['pid'])
            if process.create_time() == row['created_at'] and process.status() != psutil.STATUS_ZOMBIE:
                alive.append(process)
        except psutil.Error:
            continue
    return alive


def stop_owned(child, known=None):
    """Reap the root and only identity-checked descendants observed here."""
    if child.poll() is None and os.name == 'nt':
        stopped = subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                                 capture_output=True, creationflags=0x08000000)
        if stopped.returncode and child.poll() is None:
            raise RuntimeError('Unable to stop owned native tree: '+str(child.pid))
    elif child.poll() is None:
        os.killpg(child.pid, signal.SIGTERM)
    child.wait(timeout=30)
    # A native root can exit before its worker. Do not release the shared slot
    # while such a worker survives; stale PID reuse must never target a user job.
    for process in live_descendants(known or {}):
        import psutil
        try:
            process.kill()
            process.wait(timeout=30)
        except (ProcessLookupError, ChildProcessError, psutil.NoSuchProcess):
            continue


def phase_budget(timeout_seconds, baseline_success_seconds=None):
    """Apply the plan's successful-baseline stop and early-warning rules."""
    if not math.isfinite(timeout_seconds) or timeout_seconds<=0:
        raise ValueError('Positive finite phase allowance required')
    if baseline_success_seconds is None:
        return timeout_seconds,timeout_seconds*0.8
    if not math.isfinite(baseline_success_seconds) or baseline_success_seconds<=0:
        raise ValueError('Successful baseline duration must be positive and finite')
    stop=min(timeout_seconds,2*baseline_success_seconds+300)
    return stop,min(stop*0.8,1.5*baseline_success_seconds)


def run_supervised(command, *, cwd, log_path, timeout_seconds,
                   monitor_path, poll_seconds=30, watch_stall=False,
                   pause_path=None, stall_window=5, stall_minimum=1000,
                   stall_improvement=0.01, warmup_rounds=5,
                   baseline_success_seconds=None, monitor_only=False):
    """Run one owned native phase and persist observations before returning.

    Native logs are kept verbatim. The JSONL stream records all completed
    rounds, elapsed wall time and the warning/terminal state. No-log silence
    alone never stops a job. Explicit monitor_only disables deadline/stall
    termination. Existing PDS jobs are never adopted or killed.
    """
    # Explicit monitor-only mode keeps sampling stalls/silence but imposes no
    # host deadline. User stop files, native failures and cleanup still apply.
    if poll_seconds <= 0 or (timeout_seconds <= 0 and not monitor_only):
        raise ValueError('A positive host timeout and polling interval are required')
    if stall_window < 1 or warmup_rounds < 1 or stall_minimum < 0 or not 0 < stall_improvement < 1:
        raise ValueError('Invalid convergence policy')
    requested_timeout_seconds=timeout_seconds
    timeout_seconds,warning_seconds=(None,None) if monitor_only else phase_budget(timeout_seconds,baseline_success_seconds)
    log_path, monitor_path = Path(log_path), Path(monitor_path)
    # Freeze numeric rules before launch. These are project management
    # thresholds, not vendor guarantees or a replacement for routed STA.
    policy = dict(timeout_seconds=timeout_seconds,warning_seconds=warning_seconds,
                  requested_timeout_seconds=requested_timeout_seconds,
                  poll_seconds=poll_seconds, stall_enabled=watch_stall and not monitor_only,
                  monitor_only=monitor_only,
                  stall_window=stall_window, stall_minimum_unrouted=stall_minimum,
                  stall_minimum_improvement=stall_improvement, warmup_rounds=warmup_rounds,
                  baseline_success_seconds=baseline_success_seconds, baseline_acceleration_claim=False,
                  no_log_investigation_seconds=600)
    monitor_path.with_suffix('.policy.json').write_text(json.dumps(policy, indent=2)+'\n')
    started = time.monotonic()
    state = 'RUNNING'
    known = {}
    last_log_bytes, last_log_change = None, started
    options = dict(creationflags=0x08000000) if os.name == 'nt' else dict(start_new_session=True)
    with native_slot(), log_path.open('wb') as log, monitor_path.open('a', encoding='utf-8') as monitor:
        # A reserve/user stop already on disk must prevent process creation,
        # including the transition from one completed regional side to another.
        if pause_path and Path(pause_path).exists():
            monitor.write(json.dumps(dict(at=datetime.now(timezone.utc).isoformat(),
                pid=None, elapsed_seconds=0, status='PAUSED', warning=False,
                timeout_seconds=timeout_seconds, rounds=[], log_bytes=0,
                launch_prevented=True))+'\n')
            monitor.flush()
            return dict(status='PAUSED', returncode=1, elapsed_seconds=0,
                        pid=None, monitor=str(monitor_path), policy=policy,
                        launch_prevented=True)
        child = subprocess.Popen(command, cwd=cwd, stdout=log,
                                 stderr=subprocess.STDOUT, **options)
        try:
            while True:
                elapsed = time.monotonic() - started
                content = log_path.read_text(errors='replace')
                rounds = route_iterations(content)
                exit_code = child.poll()
                resources = process_resources(child.pid)
                for process in resources.get('processes', []):
                    if process['pid'] != child.pid:
                        known[process['pid']] = process
                log_bytes = log_path.stat().st_size
                if log_bytes != last_log_bytes:
                    last_log_bytes, last_log_change = log_bytes, time.monotonic()
                # Native completion wins over a simultaneous observation cutoff.
                if exit_code is not None:
                    state = ('ORPHANED' if live_descendants(known) else
                             'COMPLETED' if exit_code == 0 else 'FAILED')
                elif pause_path and Path(pause_path).exists():
                    state = 'PAUSED'
                elif timeout_seconds is not None and elapsed >= timeout_seconds:
                    state = 'TIMEOUT'
                elif watch_stall and not monitor_only and stalled(rounds, stall_window, stall_minimum,
                                              stall_improvement, warmup_rounds):
                    state = 'STALLED'
                row = dict(at=datetime.now(timezone.utc).isoformat(), pid=child.pid,
                           elapsed_seconds=elapsed, status=state,
                           warning=warning_seconds is not None and elapsed >= warning_seconds,
                           stall_observed=watch_stall and stalled(rounds, stall_window, stall_minimum, stall_improvement, warmup_rounds),
                           timeout_seconds=timeout_seconds, rounds=rounds,
                           log_bytes=log_bytes,
                           log_idle_seconds=time.monotonic()-last_log_change,
                           investigation_required=time.monotonic()-last_log_change >= 600,
                           best_unrouted=min((r['unrouted'] for r in rounds), default=None),
                           resources=resources)
                monitor.write(json.dumps(row)+'\n')
                monitor.flush()
                if state != 'RUNNING':
                    if exit_code is None or state == 'ORPHANED':
                        stop_owned(child, known)
                    return dict(status=state, returncode=child.returncode,
                                elapsed_seconds=time.monotonic()-started,
                                pid=child.pid, monitor=str(monitor_path), policy=policy)
                time.sleep(poll_seconds if timeout_seconds is None else min(poll_seconds, max(0.01, timeout_seconds-elapsed)))
        except BaseException:
            # Reaping on interruption prevents a hidden implementation from
            # surviving an aborted driver and colliding with the next attempt.
            stop_owned(child, known)
            raise
@contextmanager
def native_slot():
    """Serialize supervised heavy phases; retain stale locks for inspection."""
    root = Path(__file__).resolve().parents[1]/'build/route_optimization'
    root.mkdir(parents=True, exist_ok=True)
    lock = root/'native_phase.lock'
    with lock.open('x', encoding='utf-8') as stream:
        json.dump(dict(owner_pid=os.getpid(), at=datetime.now(timezone.utc).isoformat()), stream)
    try:
        yield
    except BaseException:
        # Unhandled launch/cleanup errors require identity review before the
        # machine slot can be reused. Normal failed native results return
        # explicitly and release it through the success path below.
        raise
    else:
        lock.unlink()

"""Bound an owned PDS process and retain native convergence evidence.

This supervisor changes no device, clocks, source bytes or timing gates. A
timeout or convergence stall is a failed experiment, never routed signoff.
"""
from datetime import datetime, timezone
from contextlib import contextmanager
import json
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


def stalled(rounds, window=5, minimum=1000, improvement=0.01):
    """Compare five completed transitions after the first five warmup rounds.

    Use the best value in the window rather than just the last round, so a
    temporary regression cannot hide real progress. Near convergence retains
    the hard timeout but does not use this percentage threshold.
    """
    if len(rounds) < 5 + window:
        return False
    recent = rounds[-(window + 1):]
    start = recent[0]['unrouted']
    best = min(row['unrouted'] for row in recent)
    return best > minimum and (start - best) / start < improvement


def stop_owned(child):
    """Terminate only the process tree created here, then reap its root."""
    if child.poll() is not None:
        return
    if os.name == 'nt':
        stopped = subprocess.run(['taskkill', '/PID', str(child.pid), '/T', '/F'],
                                 capture_output=True, creationflags=0x08000000)
        if stopped.returncode and child.poll() is None:
            raise RuntimeError('Unable to stop owned native tree: '+str(child.pid))
    else:
        os.killpg(child.pid, signal.SIGTERM)
    child.wait(timeout=30)


def run_supervised(command, *, cwd, log_path, timeout_seconds,
                   monitor_path, poll_seconds=30, watch_stall=False,
                   pause_path=None):
    """Run one bounded native phase and persist observations before returning.

    Native logs are kept verbatim. The JSONL stream records all completed
    rounds, elapsed wall time and the warning/terminal state. No-log silence
    alone never stops a job. Existing PDS jobs are never adopted or killed.
    """
    if timeout_seconds <= 0 or poll_seconds <= 0:
        raise ValueError('A positive host timeout and polling interval are required')
    log_path, monitor_path = Path(log_path), Path(monitor_path)
    started = time.monotonic()
    state = 'RUNNING'
    options = dict(creationflags=0x08000000) if os.name == 'nt' else dict(start_new_session=True)
    with native_slot(), log_path.open('wb') as log, monitor_path.open('a', encoding='utf-8') as monitor:
        child = subprocess.Popen(command, cwd=cwd, stdout=log,
                                 stderr=subprocess.STDOUT, **options)
        try:
            while True:
                elapsed = time.monotonic() - started
                content = log_path.read_text(errors='replace')
                rounds = route_iterations(content)
                exit_code = child.poll()
                # Native completion wins over a simultaneous observation cutoff.
                if exit_code is not None:
                    state = 'COMPLETED' if exit_code == 0 else 'FAILED'
                elif pause_path and Path(pause_path).exists():
                    state = 'PAUSED'
                elif elapsed >= timeout_seconds:
                    state = 'TIMEOUT'
                elif watch_stall and stalled(rounds):
                    state = 'STALLED'
                row = dict(at=datetime.now(timezone.utc).isoformat(), pid=child.pid,
                           elapsed_seconds=elapsed, status=state,
                           warning=elapsed >= timeout_seconds * 0.8,
                           timeout_seconds=timeout_seconds, rounds=rounds,
                           log_bytes=log_path.stat().st_size,
                           best_unrouted=min((r['unrouted'] for r in rounds), default=None),
                           resources=process_resources(child.pid))
                monitor.write(json.dumps(row)+'\n')
                monitor.flush()
                if state != 'RUNNING':
                    if exit_code is None:
                        stop_owned(child)
                    return dict(status=state, returncode=child.returncode,
                                elapsed_seconds=time.monotonic()-started,
                                pid=child.pid, monitor=str(monitor_path))
                time.sleep(min(poll_seconds, max(0.01, timeout_seconds-elapsed)))
        except BaseException:
            # Reaping on interruption prevents a hidden implementation from
            # surviving an aborted driver and colliding with the next attempt.
            stop_owned(child)
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
    finally:
        lock.unlink()

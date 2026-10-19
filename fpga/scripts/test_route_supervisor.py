"""Exercise timeout, convergence and owned-process cleanup without PDS."""
import json
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from contextlib import nullcontext
from unittest.mock import patch
from route_supervisor import route_iterations, run_supervised, stalled,phase_budget


class SupervisorTests(unittest.TestCase):
    """Small subprocess fixtures cover behavior that protects long builds."""
    def test_successful_baseline_budget_and_warning(self):
        self.assertEqual(phase_budget(1200,60),(420,90))
        self.assertEqual(phase_budget(120,60),(120,90))
        self.assertEqual(phase_budget(1200),(1200,960))

    def test_invalid_baseline_cannot_extend_or_disable_timeout(self):
        for value in (0,-1,float('inf'),float('nan')):
            with self.assertRaises(ValueError):phase_budget(1200,value)
    def run_child(self, text, timeout=5, watch_stall=False, pause=False):
        """Isolate evidence in the FPGA build tree, never in vendor folders."""
        root = Path(__file__).resolve().parents[1]/'build/route_optimization'
        root.mkdir(parents=True, exist_ok=True)
        with tempfile.TemporaryDirectory(dir=root) as directory:
            directory = Path(directory)
            pause_file = directory/'pause.json'
            if pause:
                pause_file.write_text('{}')
            # Fake lightweight children do not reserve the real PDS slot.
            # Production builds still use the exclusive machine-level lock.
            with patch('route_supervisor.native_slot', nullcontext):
                result = run_supervised(
                    [sys.executable, '-u', '-c', text], cwd=directory,
                    log_path=directory/'native.log', monitor_path=directory/'monitor.jsonl',
                    timeout_seconds=timeout, poll_seconds=0.05,
                    watch_stall=watch_stall, pause_path=pause_file)
            rows = [json.loads(s) for s in (directory/'monitor.jsonl').read_text().splitlines()]
            return result, rows

    def test_convergence_policy(self):
        """Warmup, best-in-window progress and the near-finish exemption differ."""
        flat = [dict(iteration=i, unrouted=33000) for i in range(1, 11)]
        self.assertFalse(stalled(flat[:9]))
        self.assertTrue(stalled(flat))
        progress = [dict(r) for r in flat]
        progress[-2]['unrouted'] = 32000
        self.assertFalse(stalled(progress))
        near = [dict(r, unrouted=1000) for r in flat]
        self.assertFalse(stalled(near))
        boundary = [dict(r, unrouted=10000) for r in flat]
        boundary[-1]['unrouted'] = 9900
        self.assertFalse(stalled(boundary))

    def test_parser_excludes_incomplete_round(self):
        content = ('Total 100568 subnets.\nUnrouted nets 33000 at the end of iteration 6.\n'
                   'route iteration 6, CPU time elapsed 1214.078125 sec.\n'
                   'Unrouted nets 32900 at the end of iteration 7.\n')
        self.assertEqual(route_iterations(content),
                         [dict(iteration=6, unrouted=33000, cpu_seconds=1214.078125)])

    def test_success_and_failure(self):
        result, rows = self.run_child('print("native complete")')
        self.assertEqual(result['status'], 'COMPLETED')
        self.assertEqual(rows[-1]['status'], 'COMPLETED')
        result, _ = self.run_child('raise SystemExit(7)')
        self.assertEqual(result['status'], 'FAILED')
        self.assertEqual(result['returncode'], 7)

    def test_timeout_reaps_owned_tree(self):
        result, rows = self.run_child('import time; time.sleep(60)', timeout=0.3)
        self.assertEqual(result['status'], 'TIMEOUT')
        self.assertIsNotNone(result['returncode'])
        self.assertEqual(rows[-1]['status'], 'TIMEOUT')

    def test_pause_stops_without_timeout(self):
        result, _ = self.run_child('import time; time.sleep(60)', pause=True)
        self.assertEqual(result['status'], 'PAUSED')

    def test_stall_stops_running_process(self):
        content = ''.join(f'Unrouted nets 33000 at the end of iteration {i}.\n'
                          f'route iteration {i}, CPU time elapsed 1.0 sec.\n'
                          for i in range(1, 11))
        result, rows = self.run_child(
            'import time; print('+repr(content)+', flush=True); time.sleep(60)',
            watch_stall=True)
        self.assertEqual(result['status'], 'STALLED')
        self.assertEqual(len(rows[-1]['rounds']), 10)

    def test_native_root_cannot_leave_an_observed_worker(self):
        """A successful launcher exit cannot conceal a still-running worker."""
        result, rows = self.run_child(
            'import subprocess,sys,time; '
            'subprocess.Popen([sys.executable,"-c","import time; time.sleep(60)"]); '
            'time.sleep(0.3)')
        self.assertEqual(result['status'], 'ORPHANED')
        self.assertEqual(rows[-1]['status'], 'ORPHANED')


if __name__ == '__main__':
    unittest.main()

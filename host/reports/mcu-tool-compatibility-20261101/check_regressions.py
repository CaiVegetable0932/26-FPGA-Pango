"""Verify repaired host behavior using the unchanged MCU branch C firmware.

The board and host use one virtual monotonic clock. Hardware is simulated;
wire parsing, lease, event queue and command acceptance are real firmware code.
"""
import ctypes
import json
from pathlib import Path
import subprocess
import sys
from types import SimpleNamespace
from check_compatibility import ROOT, GatewaySerial, MCUControl
import pango_video.mcu_control as controller
import mcu_pose_v2 as wire


def run_case(name):
    """Run each scenario in a fresh process to isolate firmware static state."""
    peer = GatewaySerial()
    lib = peer.lib
    lib.audit_time.restype = ctypes.c_uint64
    controller.time = SimpleNamespace(monotonic=lambda: lib.audit_time() / 1e6)
    if name == 'old_event_replay':
        for _ in range(20):
            lib.audit_emit_event()
    control = MCUControl(lambda **options: peer)
    control.connect('simulated-f4')
    control.stop.set()
    control.thread.join(1)
    def step(us=200000):
        lib.audit_tick(us)
        control._poll_once()
    try:
        if name == 'async_zero':
            assert control.action('zero', {})['zero_operation']['status'] == 'pending'
            for _ in range(28):
                step()
            result = control.status()['zero_operation']
            assert result['status'] == 'completed' and lib.audit_fault() == 0
            assert peer.commands.count(0x4c) == 28
            return {'passed': True, 'zero': result['status'], 'heartbeats': 28,
                    'elapsed_board_seconds': 5.6, 'fault': lib.audit_fault()}
        if name == 'continuous_motion':
            for _ in range(100):
                control.action('move', {'pitch': 3, 'yaw': -3})
                step()
                step()
                assert control.status()['last_command']['status'] == 'completed'
            assert lib.audit_event_count() == 200 and lib.audit_ack() == 200
            assert lib.audit_fault() == 0
            return {'passed': True, 'motions': 100, 'events': 200, 'ack': 200, 'fault': 0}
        if name == 'query_busy':
            step()
            lib.audit_tick(20000)
            count = peer.commands.count(0x44)
            control.action('read', {})
            assert peer.commands.count(0x44) == count
            # Force a genuinely early query to independently test BUSY handling.
            control.query_after = 0
            control._poll_once()
            assert control.status()['connected'] and lib.audit_fault() == 0
            step()
            assert control.status()['angles'] == {'pitch': 1.234, 'yaw': -5.678}
            return {'passed': True, 'coalesced': True, 'busy_keeps_connection': True}
        if name == 'old_event_replay':
            control.action('move', {'pitch': 3, 'yaw': -3})
            for _ in range(25):
                step()
            assert lib.audit_event_count() == 22 and lib.audit_ack() == 22
            assert control.status()['last_command']['motion_id'] == 2
            assert control.status()['last_command']['status'] == 'completed'
            assert lib.audit_fault() == 0
            return {'passed': True, 'old_events_drained': 20, 'new_motion': 2, 'ack': 22}
        if name == 'firmware_queue_boundary':
            for _ in range(65):
                lib.audit_emit_event()
            assert lib.audit_fault() == 9
            return {'passed': True, 'unacked_overflow_still_enforced': True}
        raise ValueError(name)
    finally:
        control.close()


def main():
    """Build locally, retain the pre-fix findings, and save new regression data."""
    if len(sys.argv) == 2:
        print(json.dumps(run_case(sys.argv[1]), ensure_ascii=False))
        return
    build = subprocess.run([
        'gcc', '-std=c11', '-shared', '-fPIC', '-O0', '-Wall', '-Wextra',
        '-Istubs', '-Ireference/mcu/firmware/common',
        '-Ireference/mcu/firmware/longmenjia/Core/Inc', 'gateway_bridge.c',
        'reference/mcu/firmware/common/wire.c', '-o', 'gateway_bridge.so'],
        cwd=ROOT, capture_output=True, text=True)
    (ROOT / 'build.log').write_text(build.stdout + build.stderr)
    build.check_returncode()
    cases = {}
    for name in ('async_zero', 'continuous_motion', 'query_busy', 'old_event_replay', 'firmware_queue_boundary'):
        run = subprocess.run([sys.executable, '-B', __file__, name], capture_output=True, text=True)
        if run.returncode:
            raise RuntimeError(f'{name}: {run.stdout}\n{run.stderr}')
        cases[name] = json.loads(run.stdout)
    results = {'hardware_tested': False, 'mcu_commit': '22452f36dae80ebac5b5386a60a2e92481862b0e', 'cases': cases}
    (ROOT / 'results-after.json').write_text(json.dumps(results, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(results, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()

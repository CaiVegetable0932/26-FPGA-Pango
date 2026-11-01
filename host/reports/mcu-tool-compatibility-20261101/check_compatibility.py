"""Reproduce compatibility findings against unchanged MCU gateway C code.

Run with Python 3 from any directory. Each case runs in its own process to reset
firmware globals. No physical UART is opened and no motor is driven.
"""
from pathlib import Path
import ctypes
import json
import subprocess
import sys
import time

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[2]
sys.path.insert(0, str(REPO / 'host/src'))
import mcu_pose_v2 as wire
from pango_video.mcu_control import MCUControl


class GatewaySerial:
    """Transport actual host bytes through the C firmware parser and replies."""
    def __init__(self):
        self.lib = ctypes.CDLL(str(ROOT / 'gateway_bridge.so'))
        self.lib.audit_write.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        self.lib.audit_read.argtypes = [ctypes.c_void_p, ctypes.c_uint]
        self.lib.audit_init()
        self.commands = []

    def write(self, packet):
        self.commands.append(wire.decode(packet)[0])
        self.lib.audit_write(packet, len(packet))

    def read(self, size):
        data = ctypes.create_string_buffer(size)
        n = self.lib.audit_read(data, size)
        if not n:
            # Advance board time while a delayed response is outstanding.
            time.sleep(.001)
            self.lib.audit_tick(1000)
        return data.raw[:n]

    def close(self):
        pass


def run_case(name):
    """Check both compatible layouts and reproducible failures, not a mock ACK."""
    peer = GatewaySerial()
    control = MCUControl(lambda **options: peer)
    control.connect('simulated-f4')
    control.stop.set()
    control.thread.join(1)
    lib = peer.lib
    try:
        if name == 'basic':
            assert control.status()['angles'] == {'pitch': 1.234, 'yaw': -5.678}
            control.action('move', {'pitch': 12, 'yaw': -60})
            assert control.status()['last_command']['result'] == 1
            lib.audit_tick(300000)
            control.action('home', {})
            assert control.status()['last_command']['result'] == 1
            return {'compatible': True, 'checks': ['handshake', 'state', 'move', 'home']}
        if name == 'zero_timeout':
            started = time.monotonic()
            try:
                control.action('zero', {})
            except OSError as error:
                elapsed = time.monotonic() - started
                assert lib.audit_zero_pending() == 1
                assert elapsed < 1
                # Continue valid heartbeats until firmware finishes normally.
                for _ in range(27):
                    control._request(0x4c)
                    lib.audit_tick(200000)
                control._read()
                assert lib.audit_zero_pending() == 0 and lib.audit_fault() == 0
                return {'reproduced': True, 'error': str(error),
                        'host_timeout_seconds': round(elapsed, 3),
                        'firmware_completed_after_5s_with_heartbeat': True}
            raise AssertionError('expected premature zero timeout')
        if name == 'event_overflow':
            for _ in range(33):
                control.action('move', {'pitch': 3, 'yaw': -3})
                lib.audit_tick(300000)
                control._read()
                lib.audit_tick(300000)
            assert lib.audit_fault() == 9
            assert lib.audit_ack() == 0 and 0x49 not in peer.commands
            return {'reproduced': True, 'motions': 33, 'events': lib.audit_event_count(),
                    'fault': lib.audit_fault(), 'ack': lib.audit_ack()}
        if name == 'query_busy_disconnect':
            lib.audit_tick(200000)
            control.action('read', {})
            lib.audit_tick(20000)
            class Once:
                """Run exactly one background poll after a recent manual read."""
                calls = 0
                def wait(self, seconds):
                    self.calls += 1
                    return self.calls > 1
                def set(self):
                    pass
            control.stop = Once()
            control._poll()
            state = control.status()
            assert not state['connected'] and 'BUSY' in state['error']
            return {'reproduced': True, 'connected': state['connected'], 'error': state['error']}
        if name == 'event_boundary':
            for _ in range(64):
                lib.audit_emit_event()
            assert lib.audit_fault() == 0
            lib.audit_emit_event()
            assert lib.audit_fault() == 9
            return {'reproduced': True, 'first_overflow_event': 65, 'fault': 9}
        raise ValueError(name)
    finally:
        control.close()


def main():
    """Build the reference gateway, run isolated checks and save exact results."""
    if len(sys.argv) == 2:
        print(json.dumps(run_case(sys.argv[1]), ensure_ascii=False))
        return
    build = subprocess.run([
        'gcc', '-std=c11', '-shared', '-fPIC', '-O0', '-Wall', '-Wextra',
        '-Istubs', '-Ireference/mcu/firmware/common',
        '-Ireference/mcu/firmware/longmenjia/Core/Inc',
        'gateway_bridge.c', 'reference/mcu/firmware/common/wire.c',
        '-o', 'gateway_bridge.so'], cwd=ROOT, capture_output=True, text=True)
    (ROOT / 'build.log').write_text(build.stdout + build.stderr)
    build.check_returncode()
    cases = {}
    for name in ('basic', 'zero_timeout', 'event_overflow', 'query_busy_disconnect', 'event_boundary'):
        run = subprocess.run([sys.executable, '-B', __file__, name],
                             capture_output=True, text=True)
        if run.returncode:
            raise RuntimeError(f'{name}: {run.stdout}\n{run.stderr}')
        cases[name] = json.loads(run.stdout)
    result = {'mcu_commit': '22452f36dae80ebac5b5386a60a2e92481862b0e',
              'hardware_tested': False, 'cases': cases}
    (ROOT / 'results.json').write_text(json.dumps(result, ensure_ascii=False, indent=2) + '\n')
    print(json.dumps(result, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()

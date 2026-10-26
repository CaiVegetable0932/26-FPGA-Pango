"""Keep one identity-checked route awake on AC; restore its temporary power plan.

No PDS process is modified or stopped. The Windows execution request allows
display sleep and manual sleep. A stop sentinel releases only this helper.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime
import json
import os
from pathlib import Path
import re
import subprocess

from observe_native_child_exit import (
    WindowsProcessApi, cim_inventory, validate_guard, filetime_iso,
    write_record, utc_now, WAIT_TIMEOUT, WAIT_OBJECT_0,
)


class PowerStatus(ctypes.Structure):
    """Native SYSTEM_POWER_STATUS layout; unknown supply never enables boosts."""
    _fields_ = [('ACLineStatus', wintypes.BYTE), ('BatteryFlag', wintypes.BYTE),
                ('BatteryLifePercent', wintypes.BYTE), ('SystemStatusFlag', wintypes.BYTE),
                ('BatteryLifeTime', wintypes.DWORD), ('BatteryFullLifeTime', wintypes.DWORD)]


def powercfg(*args):
    """Use fixed argument vectors and hidden subprocesses, never shell strings."""
    return subprocess.run(['powercfg', *args], capture_output=True, check=True,
                          creationflags=subprocess.CREATE_NO_WINDOW,
                          timeout=15).stdout.decode('utf-8', errors='replace')


def active_scheme():
    """Extract locale-independent GUID, refusing ambiguous command output."""
    values = re.findall(r'[0-9a-fA-F]{8}(?:-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}',
                        powercfg('/getactivescheme'))
    if len(values) != 1:
        raise ValueError('cannot identify current power scheme')
    return values[0].lower()


def main():
    """Hold the original child handle so PID reuse cannot extend this request."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--identity', type=Path, required=True)
    parser.add_argument('--build', type=Path, required=True)
    parser.add_argument('--record', type=Path, required=True)
    parser.add_argument('--performance-scheme',
                        help='Optional existing scheme; omit to preserve all power-plan choices.')
    parser.add_argument('--check-only', action='store_true')
    args = parser.parse_args()
    build = args.build.resolve()
    record_path = args.record.resolve()
    root = Path(__file__).resolve().parents[1] / 'build'
    if not build.is_relative_to(root) or not record_path.is_relative_to(root):
        raise ValueError('all build and record paths must be under fpga/build')
    if args.performance_scheme and not re.fullmatch(r'[0-9a-f-]{36}', args.performance_scheme):
        raise ValueError('invalid scheme GUID')
    identities = json.loads(args.identity.read_text(encoding='utf-8-sig'))
    children = [r for r in identities if ' -action place_route ' in r['CommandLine']]
    if len(children) != 1:
        raise ValueError('expected exactly one native route child')
    expected = children[0]
    api = WindowsProcessApi()
    handle = api.open(expected['ProcessId'])
    changed = False
    owns_record = False
    original = None
    record = {'helper_pid': os.getpid(), 'started_at': utc_now(), 'build': str(build),
              'stop_file': str(record_path.with_suffix('.stop')), 'events': []}
    api.kernel.SetThreadExecutionState.argtypes = [wintypes.DWORD]
    api.kernel.SetThreadExecutionState.restype = wintypes.DWORD
    api.kernel.GetSystemPowerStatus.argtypes = [ctypes.POINTER(PowerStatus)]
    api.kernel.GetSystemPowerStatus.restype = wintypes.BOOL
    try:
        # Validate saved identity as well as the retained handle's current identity.
        target = dict(handle=handle, parent=expected['ParentProcessId'], build=build)
        row = cim_inventory([expected['ProcessId']]).get(expected['ProcessId'])
        record['identity'] = validate_guard(api, target, row)
        actual_time = datetime.fromisoformat(filetime_iso(api.times(handle)[0]))
        if abs((actual_time - datetime.fromisoformat(expected['CreationDate'])).total_seconds()) > .005:
            raise ValueError('saved process creation time mismatch')
        if api.argv(row['CommandLine']) != api.argv(expected['CommandLine']):
            raise ValueError('saved full native command mismatch')
        original = active_scheme()
        if args.performance_scheme and args.performance_scheme not in powercfg('/list').lower():
            raise ValueError('requested existing performance scheme not found')
        if args.check_only:
            print(json.dumps(dict(guard_passed=True, original_scheme=original)))
            return
        # Exclusive record prevents accidental duplicate guardians. Save recovery
        # details before changing any host setting; no plan values are edited.
        record.update(original_scheme=original, temporary_scheme=args.performance_scheme,
                      status='starting', manual_sleep_allowed=True)
        with record_path.open('x', encoding='utf-8') as stream:
            json.dump(record, stream, indent=2)
        owns_record = True
        while True:
            wait = api.kernel.WaitForSingleObject(handle, 0)
            if wait == WAIT_OBJECT_0:
                record['status'] = 'route_child_ended'
                break
            if wait != WAIT_TIMEOUT:
                raise RuntimeError('native process wait failed')
            if record_path.with_suffix('.stop').exists():
                record['status'] = 'stop_requested'
                break
            supply = PowerStatus()
            if not api.kernel.GetSystemPowerStatus(ctypes.byref(supply)):
                raise ctypes.WinError(ctypes.get_last_error())
            if supply.ACLineStatus != 1:
                record['status'] = 'released_on_battery_or_unknown_supply'
                break
            if (args.performance_scheme and record['status'] == 'active_on_ac'
                    and active_scheme() != args.performance_scheme):
                record['status'] = 'released_after_external_plan_change'
                break
            if not api.kernel.SetThreadExecutionState(0x80000001):
                raise ctypes.WinError(ctypes.get_last_error())
            # Awake-only mode deliberately leaves vendor/user plan choices alone.
            if args.performance_scheme and not changed and original != args.performance_scheme:
                changed = True  # Ensure finally restores even if verification fails.
                powercfg('/setactive', args.performance_scheme)
                if active_scheme() != args.performance_scheme:
                    raise RuntimeError('power scheme switch did not persist')
                record['events'].append(dict(at=utc_now(), action='selected_performance'))
            times = api.times(handle)
            record.update(status='active_on_ac', last_observed_at=utc_now(),
                          cpu_seconds=(times[2] + times[3]) / 10000000,
                          sleep_request='ES_CONTINUOUS | ES_SYSTEM_REQUIRED')
            write_record(record_path, record)
            # Low overhead handle wait wakes immediately at route exit.
            api.kernel.WaitForSingleObject(handle, 30000)
    except Exception as exc:
        record.update(status='error', error=str(exc))
        raise
    finally:
        # Respect any intervening user power-plan change; never overwrite it.
        api.kernel.SetThreadExecutionState(0x80000000)
        try:
            if changed and active_scheme() == args.performance_scheme:
                powercfg('/setactive', original)
                record['restored_original_scheme'] = active_scheme() == original
        finally:
            api.kernel.CloseHandle(handle)
            if owns_record:
                record.update(ended_at=utc_now(), sleep_request_released=True)
                write_record(record_path, record)


if __name__ == '__main__':
    main()

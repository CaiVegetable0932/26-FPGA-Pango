"""Observe guarded Windows PDS children through retained, read-only handles.

This observer never controls PDS, changes native files, or infers route/STA
success. A retained handle identifies the original process after PID reuse.
"""
import argparse
import ctypes
from ctypes import wintypes
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import time


SYNCHRONIZE = 0x00100000
QUERY_LIMITED_INFORMATION = 0x1000
WAIT_OBJECT_0 = 0
WAIT_TIMEOUT = 258
WAIT_FAILED = 0xFFFFFFFF
FILETIME_EPOCH = 116444736000000000


def utc_now():
    """Use explicit UTC for observation time and native process exit time."""
    return datetime.now(timezone.utc).isoformat()


def sha_file(path):
    """Hash files in bounded chunks; no native database is opened while alive."""
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def write_record(path, record):
    """Atomically replace only this observer's JSON, never native results."""
    temporary = path.with_name(path.name + f'.{os.getpid()}.tmp')
    temporary.write_text(json.dumps(record, ensure_ascii=False, indent=2) + '\n',
                         encoding='utf-8')
    os.replace(temporary, path)


class WindowsProcessApi:
    """Declare pointer-sized HANDLE types and explicit Win32 signatures."""
    def __init__(self):
        self.kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.shell = ctypes.WinDLL('shell32', use_last_error=True)
        self.kernel.OpenProcess.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.kernel.OpenProcess.restype = wintypes.HANDLE
        self.kernel.CloseHandle.argtypes = [wintypes.HANDLE]
        self.kernel.CloseHandle.restype = wintypes.BOOL
        self.kernel.WaitForSingleObject.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.kernel.WaitForSingleObject.restype = wintypes.DWORD
        self.kernel.GetExitCodeProcess.argtypes = [wintypes.HANDLE, ctypes.POINTER(wintypes.DWORD)]
        self.kernel.GetExitCodeProcess.restype = wintypes.BOOL
        self.kernel.GetProcessTimes.argtypes = [wintypes.HANDLE] + [ctypes.POINTER(wintypes.FILETIME)] * 4
        self.kernel.GetProcessTimes.restype = wintypes.BOOL
        self.shell.CommandLineToArgvW.argtypes = [wintypes.LPCWSTR, ctypes.POINTER(ctypes.c_int)]
        self.shell.CommandLineToArgvW.restype = ctypes.POINTER(wintypes.LPWSTR)
        self.kernel.LocalFree.argtypes = [ctypes.c_void_p]
        self.kernel.LocalFree.restype = ctypes.c_void_p

    def open(self, pid):
        """Request only synchronization and limited query, no control rights."""
        handle = self.kernel.OpenProcess(SYNCHRONIZE | QUERY_LIMITED_INFORMATION, False, pid)
        if not handle:
            raise ctypes.WinError(ctypes.get_last_error())
        return handle

    def times(self, handle):
        """Read native creation/exit FILETIMEs from the already-held handle."""
        values = [wintypes.FILETIME() for _ in range(4)]
        if not self.kernel.GetProcessTimes(handle, *(ctypes.byref(v) for v in values)):
            raise ctypes.WinError(ctypes.get_last_error())
        ticks = [(int(v.dwHighDateTime) << 32) | int(v.dwLowDateTime) for v in values]
        return ticks

    def argv(self, command):
        """Use Windows command-line parsing; do not execute the native command."""
        count = ctypes.c_int()
        pointer = self.shell.CommandLineToArgvW(command, ctypes.byref(count))
        if not pointer:
            raise ctypes.WinError(ctypes.get_last_error())
        try:
            return [pointer[i] for i in range(count.value)]
        finally:
            self.kernel.LocalFree(ctypes.cast(pointer, ctypes.c_void_p))


def filetime_iso(ticks):
    """Keep raw FILETIME alongside its readable representation for precision."""
    if not ticks:
        return None
    return datetime.fromtimestamp((ticks - FILETIME_EPOCH) / 10000000,
                                  timezone.utc).isoformat()


def cim_inventory(pids):
    """Query integer PIDs once, with hidden PowerShell and structured output."""
    expression = ' OR '.join(f'ProcessId={pid}' for pid in pids)
    command = (
        f'Get-CimInstance Win32_Process -Filter "{expression}" | '
        'ForEach-Object { [pscustomobject]@{ ProcessId=$_.ProcessId; '
        'ParentProcessId=$_.ParentProcessId; Name=$_.Name; '
        'ExecutablePath=$_.ExecutablePath; CommandLine=$_.CommandLine; '
        'CreationDateUtc=$_.CreationDate.ToUniversalTime().ToString("o") } } | '
        'ConvertTo-Json -Depth 3 -Compress'
    )
    run = subprocess.run(['powershell', '-NoProfile', '-NonInteractive', '-Command', command],
                         capture_output=True, text=True, check=True,
                         creationflags=subprocess.CREATE_NO_WINDOW, timeout=30)
    rows = json.loads(run.stdout.strip()) if run.stdout.strip() else []
    if isinstance(rows, dict):
        rows = [rows]
    return {int(row['ProcessId']): row for row in rows}


def normalized(path):
    return str(Path(path).resolve()).replace('\\', '/').casefold()


def validate_guard(api, target, row):
    """Bind handle creation time, exact parent/build/action to one identity."""
    if not row or int(row['ParentProcessId']) != target['parent']:
        raise ValueError('CIM PID/parent guard failed')
    expected_exe = 'E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe'
    if row['Name'].casefold() != 'pds_shell.exe' or normalized(row['ExecutablePath']) != normalized(expected_exe):
        raise ValueError('CIM executable guard failed')
    creation_ticks = api.times(target['handle'])[0]
    held_created = datetime.fromisoformat(filetime_iso(creation_ticks))
    cim_created = datetime.fromisoformat(row['CreationDateUtc'].replace('Z', '+00:00'))
    if abs((held_created - cim_created).total_seconds()) > .005:
        raise ValueError('PID reuse / creation-time guard failed')
    argv = api.argv(row['CommandLine'])
    def option(name):
        indexes = [i for i, value in enumerate(argv) if value.casefold() == name]
        if len(indexes) != 1 or indexes[0] + 1 >= len(argv):
            raise ValueError(f'missing or duplicated {name}')
        return argv[indexes[0] + 1]
    build = target['build']
    if option('-action').casefold() != 'place_route':
        raise ValueError('native action guard failed')
    if int(option('-parent_process_key')) != target['parent']:
        raise ValueError('native parent argument guard failed')
    if normalized(option('-input_db_file')) != normalized(build / 'device_map/pango_video_system_map.adf'):
        raise ValueError('exact mapped input guard failed')
    if normalized(option('-project_file')) != normalized(build / 'place_route.pds'):
        raise ValueError('exact project/build guard failed')
    return dict(cim=row, held_creation_filetime=creation_ticks,
                held_creation_utc=filetime_iso(creation_ticks), guard_passed=True,
                access_mask=SYNCHRONIZE | QUERY_LIMITED_INFORMATION,
                access_rights=['SYNCHRONIZE', 'QUERY_LIMITED_INFORMATION'])


def input_snapshot(build):
    """Recompute all 290 actual source hashes and preserve manifest evidence."""
    manifest_file = build / 'sources.json'
    manifest = json.loads(manifest_file.read_text(encoding='utf-8'))
    if not isinstance(manifest, dict) or len(manifest) != 290:
        raise ValueError('expected the existing 290-entry source manifest')
    source = (build / 'source').resolve()
    actual, mismatches = {}, []
    for name, expected in sorted(manifest.items()):
        path = (source / name).resolve()
        if not path.is_relative_to(source):
            raise ValueError('source manifest escapes frozen source directory')
        actual[name] = sha_file(path) if path.is_file() else None
        if actual[name] != expected:
            mismatches.append(name)
    return dict(observed_at=utc_now(), manifest_sha256=sha_file(manifest_file),
                entry_count=len(manifest), actual_sha256=actual,
                matches_manifest=not mismatches, mismatches=mismatches)


def final_evidence(target):
    """Only after child exit, hash native databases and inspect text logs."""
    build = target['build']
    logs = {}
    for label, path in [('resume', target['resume'] / 'place_route.log'),
                        ('native', build / 'place_route/run.log')]:
        if path.is_file():
            text = path.read_text(encoding='utf-8', errors='replace')
            logs[label] = dict(path=str(path), sha256=sha_file(path), size=path.stat().st_size,
                               errors=re.findall(r'^E:.*$', text, re.M),
                               route_warnings=re.findall(r'^[WC]: Route-.*$', text, re.M),
                               tail=text[-1600:])
        else:
            logs[label] = dict(path=str(path), exists=False)
    databases = [dict(path=str(path), size=path.stat().st_size, sha256=sha_file(path))
                 for path in sorted((build / 'place_route').glob('*.adf')) if path.is_file()]
    after = input_snapshot(build)
    before = target['record']['inputs_before']
    differences = [name for name in sorted(set(before['actual_sha256']) | set(after['actual_sha256']))
                   if before['actual_sha256'].get(name) != after['actual_sha256'].get(name)]
    return dict(inputs_after=after, before_after_changed_inputs=differences,
                manifest_changed=before['manifest_sha256'] != after['manifest_sha256'],
                logs=logs, databases_hashed_after_observed_child_exit=databases,
                routed_database_exists=(build / 'place_route/pango_video_system_pnr.adf').is_file(),
                pnr_success_inferred=False, timing_success_inferred=False)


def main():
    """Retain all handles before hashing; monitor asynchronously to PDS work."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--target', nargs=4, action='append', required=True,
                        metavar=('PID', 'PARENT_PID', 'BUILD', 'RESUME_NAME'))
    parser.add_argument('--poll-ms', type=int, default=1000)
    parser.add_argument('--heartbeat-seconds', type=int, default=60)
    args = parser.parse_args()
    if os.name != 'nt':
        raise ValueError('this observer requires Windows process handles')
    if not 100 <= args.poll_ms <= 5000 or args.heartbeat_seconds < 30:
        raise ValueError('use bounded short waits and sparse JSON heartbeats')
    api = WindowsProcessApi()
    fpga_build = Path(__file__).resolve().parents[1] / 'build'
    targets = []
    for pid, parent, build_arg, resume_name in args.target:
        build = Path(build_arg).resolve()
        resume = (build / resume_name).resolve()
        if not build.is_relative_to(fpga_build) or resume.parent != build or not resume.is_dir():
            raise ValueError('observer outputs must be in an existing FPGA build resume directory')
        output = resume / 'native_child_exit_observation.json'
        if output.exists():
            raise ValueError(f'refusing to replace an existing observation: {output}')
        target = dict(pid=int(pid), parent=int(parent), build=build, resume=resume,
                      output=output, handle=None)
        target['record'] = dict(schema='native_child_exit_observation.v1', observer_pid=os.getpid(),
                                observer_script=str(Path(__file__).resolve()),
                                observer_script_sha256=sha_file(Path(__file__).resolve()),
                                started_at=utc_now(), child_pid=int(pid), parent_pid=int(parent),
                                build=str(build), resume=str(resume), status='opening_handle',
                                pnr_success_inferred=False, timing_success_inferred=False)
        targets.append(target)
    if len({target['pid'] for target in targets}) != len(targets):
        raise ValueError('duplicate child PID')
    try:
        # No later OpenProcess call is used: these original handles survive exit.
        for target in targets:
            try:
                target['handle'] = api.open(target['pid'])
            except Exception as exc:
                target['record'].update(status='guard_failed', observation_error=str(exc))
        inventory = cim_inventory([target['pid'] for target in targets])
        for target in targets:
            try:
                if target['handle'] is None:
                    continue
                target['record']['identity'] = validate_guard(api, target, inventory.get(target['pid']))
                target['record']['inputs_before'] = input_snapshot(target['build'])
                target['record'].update(status='waiting_for_child_exit', handle_retained=True,
                                        last_observed_at=utc_now(), poll_ms=args.poll_ms)
            except Exception as exc:
                target['record'].update(status='guard_failed', observation_error=str(exc))
            finally:
                write_record(target['output'], target['record'])
        print(json.dumps({'event': 'observer_ready', 'observer_pid': os.getpid(), 'targets': [
            dict(pid=t['pid'], parent=t['parent'], status=t['record']['status'],
                 guard_passed=t['record'].get('identity', {}).get('guard_passed', False),
                 input_count=t['record'].get('inputs_before', {}).get('entry_count'),
                 inputs_intact=t['record'].get('inputs_before', {}).get('matches_manifest'),
                 output=str(t['output'])) for t in targets]}, ensure_ascii=False), flush=True)
        next_heartbeat = time.monotonic() + args.heartbeat_seconds
        while any(t['record']['status'] == 'waiting_for_child_exit' for t in targets):
            for target in targets:
                if target['record']['status'] != 'waiting_for_child_exit':
                    continue
                result = api.kernel.WaitForSingleObject(target['handle'], args.poll_ms)
                if result == WAIT_TIMEOUT:
                    continue
                if result != WAIT_OBJECT_0:
                    error = ctypes.WinError(ctypes.get_last_error()) if result == WAIT_FAILED else f'wait result {result}'
                    target['record'].update(status='observation_failed', observation_error=str(error))
                    write_record(target['output'], target['record'])
                    continue
                # Signalled handle proves exit even if the actual exit code is 259.
                code = wintypes.DWORD()
                if not api.kernel.GetExitCodeProcess(target['handle'], ctypes.byref(code)):
                    raise ctypes.WinError(ctypes.get_last_error())
                times = api.times(target['handle'])
                target['record'].update(status='child_exited', observed_exit_at=utc_now(),
                                        native_exit_code=int(code.value), native_exit_code_hex=f'0x{code.value:08X}',
                                        native_exit_filetime=times[1], native_exit_utc=filetime_iso(times[1]),
                                        exit_code_from_retained_handle=True)
                try:
                    target['record']['final_evidence'] = final_evidence(target)
                except Exception as exc:
                    target['record']['final_evidence_error'] = str(exc)
                write_record(target['output'], target['record'])
                print(json.dumps({'event': 'child_exited', 'pid': target['pid'],
                                  'native_exit_code': int(code.value), 'output': str(target['output'])}), flush=True)
            if time.monotonic() >= next_heartbeat:
                for target in targets:
                    if target['record']['status'] == 'waiting_for_child_exit':
                        target['record']['last_observed_at'] = utc_now()
                        write_record(target['output'], target['record'])
                next_heartbeat = time.monotonic() + args.heartbeat_seconds
    finally:
        for target in targets:
            if target['handle'] is not None:
                api.kernel.CloseHandle(target['handle'])


if __name__ == '__main__':
    main()

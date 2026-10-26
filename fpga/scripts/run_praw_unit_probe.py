"""Measure the prepared PRAW pair serially under a bounded resource policy.

This is unit compile/SYN only, not a sixth place-and-route attempt. A fresh
memory/process audit permits one auxiliary job while the five existing routes
continue. Native shells must exit before the second unit is launched.
"""
import argparse
import ctypes
import ctypes.wintypes
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess


def inventory():
    """Read process identity and memory with fixed, read-only PowerShell code."""
    command = ("$taskMem=Get-CimInstance Win32_OperatingSystem; "
        "$taskShells=@(Get-CimInstance Win32_Process -Filter \"Name = 'pds_shell.exe'\" | "
        "Select-Object ProcessId,ParentProcessId,CreationDate,CommandLine); "
        "[pscustomobject]@{at=(Get-Date).ToString('o'); "
        "free_physical_kib=$taskMem.FreePhysicalMemory; "
        "free_virtual_kib=$taskMem.FreeVirtualMemory; shells=$taskShells} | ConvertTo-Json -Depth 5 -Compress")
    child = subprocess.run(['powershell', '-NoProfile', '-Command', command],
        capture_output=True, text=True, check=True, creationflags=0x08000000)
    return json.loads(child.stdout)


def main():
    """Recheck frozen inputs, run one unit at a time, retain native evidence."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--probe', type=Path, required=True)
    parser.add_argument('--batch-index', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    run = args.probe.resolve()
    if not run.is_relative_to(fpga/'build'):
        raise ValueError('Probe must remain inside FPGA build tree')
    prepared = json.loads((run/'prepared.json').read_text())
    if (run/'result.json').exists():
        raise ValueError('Preserve prior probe results; do not overwrite or restart')
    intact = lambda: all(hashlib.sha256(Path(n).read_bytes()).hexdigest() == h
        for n, h in prepared['inputs'].items())
    if not intact():
        raise ValueError('Prepared unit inputs changed')
    index = json.loads(args.batch_index.read_text())
    prefixes = []
    for member in index['members']:
        state = json.loads(Path(member['campaign']).read_text())
        for attempt in state['attempts']:
            prefixes.append(Path(attempt['build']).as_posix().lower()+'/')

    def audit(label, minimum):
        """Allow only the already reserved route processes; reject leftovers."""
        observed = inventory()
        (run/(label+'.json')).write_text(json.dumps(observed, indent=2)+'\n')
        shells = observed['shells']
        if int(observed['free_physical_kib']) < minimum or len(shells) > 10:
            raise ValueError('Insufficient unit-probe resource margin')
        if any(not any(prefix in (s['CommandLine'] or '').replace('\\', '/').lower()
            for prefix in prefixes) for s in shells):
            raise ValueError('Another native job or residual unit shell requires inspection')
        return observed

    initial = audit('launch_audit', 6000000)
    # Supersede the conservative preparation-time reservation only after actual
    # free memory grows above 6,000,000 KiB. No clocks, gates or PnR count change.
    decision = dict(at=datetime.now().astimezone().isoformat(),
        reason='Fresh memory exceeds 6000000 KiB; only the five existing routes own PDS shells. Run one small unit at a time with BelowNormal priority.',
        prior_policy=prepared['launch_policy'], initial_audit=initial,
        before_each_unit_minimum_free_physical_kib=4000000,
        unit_parallelism=1, new_place_route_attempts=0)
    (run/'launch_decision.json').write_text(json.dumps(decision, indent=2)+'\n')
    kernel = ctypes.WinDLL('kernel32', use_last_error=True)
    kernel.GetCurrentProcess.restype = ctypes.wintypes.HANDLE
    kernel.SetPriorityClass.argtypes = [ctypes.wintypes.HANDLE, ctypes.wintypes.DWORD]
    kernel.SetPriorityClass.restype = ctypes.wintypes.BOOL
    if not kernel.SetPriorityClass(kernel.GetCurrentProcess(), 0x4000):
        raise ctypes.WinError(ctypes.get_last_error())
    shutil.copyfile(__file__, run/'execution_script.py')
    result = dict(passed=False, native_completed=False, board_timing_signoff=False,
        inputs=prepared['inputs'], native_runs=[], programmed=False)
    try:
        for label in ('baseline', 'candidate'):
            audit(label+'_before', 4000000)
            build = run/label
            print('PRAW_UNIT_SYN', label, build, flush=True)
            with (build/'native.log').open('wb') as log:
                child = subprocess.run([prepared['tool'], '-file', str(build/'flow.tcl'),
                    '-work_dir', str(build)], cwd=build, stdout=log, stderr=subprocess.STDOUT,
                    creationflags=0x08000000)
            errors = re.findall(r'^E:.*', (build/'native.log').read_text(errors='replace'), re.M)
            result['native_runs'].append(dict(label=label, exit=child.returncode, errors=errors))
            # A completed parent alone is insufficient: require all of this
            # unit's PDS children to have gone before progressing or returning.
            audit(label+'_after', 0)
            if child.returncode or errors:
                raise RuntimeError('Native unit synthesis failed: '+label)
            report = (build/'synthesize/praw_udp_tx.snr').read_text(errors='replace')
            resources = {name: int(re.search(pattern, report)[1]) for name, pattern in [
                ('LUT', r'Total LUTs: (\d+)'), ('FF', r'Total Registers: (\d+)'),
                ('LUTRAM', r'LUTs as dram: (\d+)'), ('controlsets', r'Number of unique control sets : (\d+)')]}
            resources['DRM'] = float(re.search(r'Total DRM = ([\d.]+)', report)[1])
            result[label+'_resources'] = resources
            print(label, resources, flush=True)
        if not intact():
            raise ValueError('Unit input changed during synthesis')
        result.update(passed=True, native_completed=True)
    finally:
        result['inputs_intact'] = intact()
        (run/'result.json').write_text(json.dumps(result, indent=2)+'\n')


if __name__ == '__main__':
    main()

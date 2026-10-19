"""Bound regional preparation, PnR and STA independently under the native slot.

The installed PDS explicit-DB/force_to_run flow matches resume_video_system.py.
No bit generation is supported; sources and constraints remain unchanged.
"""
from pathlib import Path
import hashlib
import re
from route_supervisor import run_supervised


def native_pnr_seconds(text):
    """Use the action's own duration, even across standalone native phases."""
    matches = re.findall(r'Action pnr: Real time elapsed is (\d+)h:(\d+)m:(\d+)s', text)
    if not matches:
        return None
    h, m, s = map(int, matches[-1])
    return h*3600+m*60+s


def run_regional_phases(build, flow, *, timeout_seconds, pause_path,
                        baseline_success_seconds=None):
    """Keep the plan's PnR allowance separate from costly RTL compilation.

    Preparation <=20 minutes, PnR <=the selected <=20-minute allowance
    (or the successful-baseline adaptive budget), and STA <=120 seconds.
    This is a new budget mode; old full-flow timeout results are not relabelled.
    """
    if not 0 < timeout_seconds <= 1200:
        raise ValueError('Regional PnR allowance must be at most 20 minutes')
    build = Path(build)
    if flow.count('\npnr ') != 1 or flow.count('\nreport_timing ') != 1 or 'gen_bit_stream' in flow:
        raise ValueError('One reviewed regional PnR and min/max report required')
    prefix = flow.split('\ncompile ', 1)[0]+'\n'
    prepare = flow.split('\npnr ', 1)[0]+'\n'
    pnr = next(line for line in flow.splitlines() if line.startswith('pnr '))
    timing = next(line for line in flow.splitlines() if line.startswith('report_timing '))
    mapped = build/'device_map/regional_wrapper_map.adf'
    physical = build/'device_map/regional_wrapper.pcf'
    routed = build/'place_route/regional_wrapper_pnr.adf'
    pnr = pnr.replace('pnr ', 'pnr -force_to_run -input_db_file {'+mapped.as_posix()+'} ', 1)
    timing = timing.replace('report_timing ',
        'report_timing -force_to_run -input_db_file {'+routed.as_posix()+'} ', 1)
    context = prefix+'add_constraint {'+physical.as_posix()+'}\n'
    plans = [('prepare', prepare, 1200, None),
             ('place_route', context+pnr+'\n', timeout_seconds, baseline_success_seconds),
             ('report_timing', context+timing+'\n', 120, None)]
    combined = build/'physical.log'
    combined.write_bytes(b'')
    records = []
    checkpoint_inputs = {}
    for phase, body, limit, baseline in plans:
        # Explicit-DB commands must consume the exact saved dependency, never
        # silently trigger recompilation or start against incomplete mapping.
        if phase == 'place_route' and not (mapped.is_file() and physical.is_file()):
            raise ValueError('Preparation did not produce mapped DB and PCF')
        if phase == 'report_timing' and not routed.is_file():
            raise ValueError('PnR did not produce a routed DB')
        dependencies = (mapped, physical) if phase == 'place_route' else (routed,) if phase == 'report_timing' else ()
        for path in dependencies:
            checkpoint_inputs[str(path)]=hashlib.sha256(path.read_bytes()).hexdigest()
        script = build/(phase+'.tcl')
        script.write_text(body, encoding='utf-8')
        log = build/(phase+'.log')
        print('REGIONAL_PHASE',phase,'limit_seconds',limit,flush=True)
        result = run_supervised(
            ['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe', '-file',
             str(script), '-work_dir', str(build)], cwd=build, log_path=log,
            timeout_seconds=limit, monitor_path=build/(phase+'_monitor.jsonl'),
            pause_path=pause_path, watch_stall=phase == 'place_route',
            baseline_success_seconds=baseline)
        with combined.open('ab') as output:
            output.write(log.read_bytes())
        records.append(dict(phase=phase, **result))
        if result['status'] != 'COMPLETED' or re.search(r'^E:', log.read_text(errors='replace'), re.M):
            break
    last = records[-1]
    status = last['status']
    if len(records) != 3 and status == 'COMPLETED':
        status = 'FAILED'
    if re.search(r'^E:', combined.read_text(errors='replace'), re.M):
        status = 'FAILED'
    checkpoint_inputs_intact=all(Path(p).is_file() and hashlib.sha256(Path(p).read_bytes()).hexdigest()==h
                                for p,h in checkpoint_inputs.items())
    if not checkpoint_inputs_intact:
        status='FAILED'
    return dict(status=status, returncode=last['returncode'], pid=last['pid'],
                elapsed_seconds=sum(r['elapsed_seconds'] for r in records),
                monitor=last['monitor'], phases=records,
                budget_mode='PREPARE_20_PNR_SELECTED_STA_2_MINUTES',
                checkpoint_inputs=checkpoint_inputs,checkpoint_inputs_intact=checkpoint_inputs_intact,
                maximum_total_seconds=1200+timeout_seconds+120)

"""Generate offline bits from the exact PDS database whose STA already passed."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from implementation_readiness import require_whole_design_ready, require_routed_lut_budget
from route_supervisor import run_supervised
from constraint_report import require_native_constraints


def generate_from_timed_database(run: Path, shell: str, log_path: Path, *, pause_path=None):
    """Keep the routed database/report immutable across the standalone action.

    Installed PDS gen_bit_stream help documents force_to_run/input_db_file
    and persist_pin. Explicit user release preserves the PG2L100H default
    required by the board's shared configuration pins (Guide printed p152).
    The status override permits a standalone project; it never substitutes
    for the explicit completed min/max STA gate below. No programmer is used.
    """
    # Route readiness and bitstream authorization are separate boundaries.
    # The current task stops before bitgen; false, absent, or merely truthy
    # values cannot authorize Tcl creation or a native process launch.
    state = require_whole_design_ready()
    if state.get('bitstream_generation_allowed') is not True:
        raise ValueError('Bitstream generation is blocked: implementation_readiness.json '
                         'must explicitly set bitstream_generation_allowed=true')
    # A nominal "All Constraints Met" report can omit unmatched paths.
    # Check the exact candidate's CCR and native logs before writing Tcl or
    # launching bitgen, including direct checkpoint-entry calls.
    require_native_constraints(run)
    # Placement can replicate logic after MAP. Enforce the user's strict
    # resource budget on the completed physical report before creating Tcl.
    routed_budget = require_routed_lut_budget(run)
    report = run / 'report_timing/pango_video_system.rtr'
    database = run / 'place_route/pango_video_system_pnr.adf'
    if not report.is_file() or not database.is_file():
        raise ValueError('completed routed database and timing report required')
    if not re.search(r'^Design Summary\s*:\s*All Constraints Met\.',
                     report.read_text(errors='replace'), re.M):
        raise ValueError('native timing gate has not passed')
    paths = {'timing_report': report, 'routed_database': database}
    before = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    tcl = run / 'bitgen_from_checkpoint.tcl'
    tcl.write_text(
        '# Standalone native bitgen only AFTER host-verified min/max STA.\n'
        f'set_dir -impl_directory {{{run.as_posix()}}}\n'
        'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
        f'gen_bit_stream -force_to_run -input_db_file {{{database.as_posix()}}} -scbv {{High Voltage}} -persist_pin {{Release For USER}}\n',
        encoding='utf-8')
    # Offline bit generation also owns its native process tree and is bounded.
    supervised=run_supervised([shell,'-file',str(tcl),'-work_dir',str(run)],
        cwd=run,log_path=log_path,monitor_path=log_path.with_suffix('.monitor.jsonl'),
        timeout_seconds=300,pause_path=pause_path)
    child=subprocess.CompletedProcess([],supervised['returncode'])
    after = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    (run / 'bitgen_checkpoint.json').write_text(json.dumps({
        'schema': 'native_bitgen_checkpoint.v1', 'before': before, 'after': after,
        'routed_lut_gate': routed_budget,
        'native_exit': child.returncode, 'supervision':supervised,'checkpoint_intact': before == after,
        'hardware_tested': False, 'programmed': False}, indent=2)+'\n', encoding='utf-8')
    if before != after:
        raise RuntimeError('routed database or completed STA report changed during bitgen')
    if supervised['status']!='COMPLETED':
        raise RuntimeError('Offline bitgen did not complete: '+supervised['status'])
    return child

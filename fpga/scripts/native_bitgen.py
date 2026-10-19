"""Generate offline bits from the exact PDS database whose STA already passed."""
import hashlib
import json
from pathlib import Path
import re
import subprocess
from implementation_readiness import require_whole_design_ready


def generate_from_timed_database(run: Path, shell: str, log_path: Path):
    """Keep the routed database/report immutable across the standalone action.

    Installed PDS gen_bit_stream help documents force_to_run/input_db_file.
    The status override permits a standalone project; it never substitutes
    for the explicit completed min/max STA gate below. No programmer is used.
    """
    # A historical routed checkpoint cannot bypass the user's design gate.
    require_whole_design_ready()
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
        f'gen_bit_stream -force_to_run -input_db_file {{{database.as_posix()}}} -scbv {{High Voltage}}\n',
        encoding='utf-8')
    with log_path.open('wb') as log:
        child = subprocess.run([shell, '-file', str(tcl), '-work_dir', str(run)], cwd=run,
                               stdout=log, stderr=subprocess.STDOUT, timeout=300, creationflags=0x08000000)
    after = {name: hashlib.sha256(path.read_bytes()).hexdigest() for name, path in paths.items()}
    (run / 'bitgen_checkpoint.json').write_text(json.dumps({
        'schema': 'native_bitgen_checkpoint.v1', 'before': before, 'after': after,
        'native_exit': child.returncode, 'checkpoint_intact': before == after,
        'hardware_tested': False, 'programmed': False}, indent=2)+'\n', encoding='utf-8')
    if before != after:
        raise RuntimeError('routed database or completed STA report changed during bitgen')
    return child

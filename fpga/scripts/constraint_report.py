"""Expose native CCR diagnostics without equating MAP completion with signoff."""
from collections import Counter
import hashlib
from pathlib import Path
import re


def read_constraint_report(path):
    """Retain summary, severity and code counts; absent evidence stays unknown."""
    path = Path(path)
    result = dict(path=str(path), available=path.is_file(), summary_valid=False,
                  errors=None, critical_warnings=None, warnings=None,
                  constraint_count=None, diagnostic_counts={}, diagnostics=[],
                  requires_review=True)
    if not result['available']:
        return result
    raw = path.read_bytes()
    content = raw.decode('utf-8', errors='replace')
    result['sha256'] = hashlib.sha256(raw).hexdigest()
    match = re.search(r'Found (\d+) error\(s\), (\d+) critical warning\(s\), '
                      r'(\d+) warning\(s\), out of (\d+) constraint\(s\)', content)
    rows = re.findall(r'^\s*([ECW]): ([\w-]+):[^\r\n]*', content, re.M)
    result['diagnostic_counts'] = dict(Counter(code for _, code in rows))
    result['diagnostics'] = [line.strip() for line in content.splitlines()
                             if re.match(r'\s*[ECW]:', line)]
    if match:
        result.update(zip(('errors', 'critical_warnings', 'warnings', 'constraint_count'),
                          map(int, match.groups())))
        # A truncated report must not look clean just because its header survived.
        counts = Counter(severity for severity, _ in rows)
        result['summary_valid'] = all(counts[key] == result[name] for key, name in
                                     [('E', 'errors'), ('C', 'critical_warnings'), ('W', 'warnings')])
        result['requires_review'] = (not result['summary_valid'] or
                                    any(result[key] for key in ('errors', 'critical_warnings', 'warnings')))
    return result


def require_postsyn_constraints(build):
    """Prove the frozen reset SCF reached the actual mapped constraint set.

    ADS project registration alone did not consume K's post-SYN SCF. Match
    all ten distinct raw commands against DMR, normalizing whitespace only;
    a silent omission must fail even when CCR and native logs have no errors.
    This proves report inheritance, not physical timing or exception safety.
    """
    build = Path(build)
    scf = build / 'source/constraints/video_system/reset_fsm_postsyn.scf'
    if not scf.is_file():
        return dict(required=False, reason='No frozen reset post-SYN SCF')
    raw = scf.read_bytes()
    commands = [' '.join(line.split()) for line in raw.decode('utf-8').splitlines()
                if line.strip() and not line.lstrip().startswith('#')]
    if (len(commands) != 10 or len(set(commands)) != 10 or
            any(not re.fullmatch(r'set_false_path -from \{i:[^{}]+\} -to \{t:[^{}]+\}', line)
                for line in commands)):
        raise ValueError('Native constraint gate: reset SCF must contain ten distinct raw pin exceptions')
    dmr = build / 'device_map/pango_video_system.dmr'
    if not dmr.is_file():
        raise ValueError('Native constraint gate: DMR required to prove reset SCF consumption')
    mapped_raw = dmr.read_bytes()
    mapped_commands = {' '.join(line.split()) for line in
                       mapped_raw.decode('utf-8', errors='replace').splitlines()
                       if re.match(r'^\s*set_false_path\s', line)}
    missing = [line for line in commands if line not in mapped_commands]
    if missing:
        raise ValueError('Native constraint gate: mapped DMR missing '
                         + str(len(missing)) + '/10 reset SCF exceptions: '
                         + '\n'.join(missing))
    return dict(required=True, consumed=True, command_count=10,
                scf_path=str(scf), scf_sha256=hashlib.sha256(raw).hexdigest(),
                dmr_path=str(dmr), dmr_sha256=hashlib.sha256(mapped_raw).hexdigest(),
                physical_timing_signed_off=False)


def require_native_constraints(build):
    """Reject known broken timing constraints before physical work or bitgen.

    The MAP log and a complete CCR are mandatory. Include physical/resume logs
    because post-synthesis or post-map constraints (including LCF) may lose a
    path only in a later native phase. Old failed routing is retryable; known
    unmatched constraints in this immutable candidate are not. Shared-pin
    critical warnings remain visible for review rather than becoming errors.
    """
    build = Path(build)
    ccr = read_constraint_report(build / 'constraint_check/constraint_check.ccr')
    if not ccr['summary_valid'] or ccr['errors']:
        raise ValueError('Native constraint gate: missing/invalid CCR or CCR errors')
    if ccr['diagnostic_counts'].get('STA-3015'):
        raise ValueError('Native constraint gate: unmatched timing paths in CCR')
    map_log = build / 'console.log'
    if not map_log.is_file():
        raise ValueError('Native constraint gate: MAP console log is required')
    paths = [map_log]
    physical = build / 'physical_console.log'
    if physical.is_file():
        paths.append(physical)
    for pattern in ('resume_*/place_route.log', 'resume_*/report_timing.log'):
        paths.extend(sorted(build.glob(pattern)))
    logs = []
    for path in paths:
        raw = path.read_bytes()
        text = raw.decode('utf-8', errors='replace')
        unmatched = re.findall(r'^\s*[CW]: STA-3015:.*', text, re.M)
        if unmatched:
            raise ValueError('Native constraint gate: unmatched timing paths in '
                             + str(path) + ': ' + '\n'.join(unmatched))
        if path == map_log and re.search(r'^\s*E:', text, re.M):
            raise ValueError('Native constraint gate: errors in MAP console')
        logs.append(dict(path=str(path), sha256=hashlib.sha256(raw).hexdigest()))
    postsyn = require_postsyn_constraints(build)
    return dict(constraint_check=ccr, verified_logs=logs, postsyn_constraint_gate=postsyn,
                no_known_unmatched_timing_paths=True, physical_timing_signed_off=False)

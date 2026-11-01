"""Enforce the user's design-completion gate at whole-design entry points."""
import hashlib
import json
import os
import re
import tempfile
from datetime import datetime
from pathlib import Path


def validate_route_scope(state, build=None, options=None):
    """Bind a scoped physical allowance to reviewed input bytes and options.

    Legacy records without a scope retain their prior gate behavior. A scoped
    allowance cannot authorize a fresh compile, another MAP, or bit generation.
    Frozen source contents are checked by the resume preflight as well.
    """
    scope=state.get('route_scope')
    if scope is None:return
    if not state.get('pre_route_review_complete') or state.get('bitstream_generation_allowed'):
        raise ValueError('Scoped routing requires completed review and bitstream=false')
    if build is None or Path(build).resolve()!=Path(scope['build']).resolve():
        raise ValueError('Route permission is restricted to the reviewed MAP directory')
    if options is None:raise ValueError('Scoped routing requires explicit reviewed resume options')
    for name,expected in scope['options'].items():
        actual=getattr(options,name,None)
        # JSON stores paths as strings; argparse produces Path objects.
        # Compare canonical paths for both scoped path-valued options.
        if name in ('pause_file','installed_pnr_help') and expected is not None:
            equal=actual is not None and Path(actual).resolve()==Path(expected).resolve()
        else:equal=actual==expected
        if not equal:raise ValueError('Route option outside reviewed scope: '+name)
    base=Path(build).resolve()
    for name,expected in scope['files'].items():
        path=(base/name).resolve()
        if not path.is_relative_to(base) or not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest()!=expected:
            raise ValueError('Scoped route input changed: '+name)


def require_whole_design_ready(build=None, options=None):
    """Fail closed before creating or resuming whole-design physical jobs.

    Regional probes deliberately use separate, top-restricted entry points.
    Updating this record is a reviewed project change, not a CLI bypass flag.
    """
    record = Path(__file__).resolve().parents[1]/'config/implementation_readiness.json'
    state = json.loads(record.read_text(encoding='utf-8'))
    # The user explicitly requested reviewing the next whole-board run in the
    # GUI. Preparation helpers may open a scope, but cannot clear this pending
    # approval flag. Clear it only after recording the user's actual approval.
    if state.get('user_gui_approval_required'):
        raise ValueError('Whole-design implementation awaits the user-requested GUI review and approval')
    required = ('design_complete','selected_source_simulation_passed',
                'resource_and_constraints_reviewed','whole_design_route_allowed')
    missing = [name for name in required if state.get(name) is not True]
    if missing:
        raise ValueError('Whole-design implementation is blocked by the user design-completion gate: '
                         + ', '.join(missing) + '. See '+str(record))
    validate_route_scope(state,build,options)
    return state


def close_route_scope(scope_id,result_path,record=None):
    """Close only this attempt's permission; preserve a newer owner's record."""
    if scope_id is None:return False
    record=Path(record) if record is not None else Path(__file__).resolve().parents[1]/'config/implementation_readiness.json'
    state=json.loads(record.read_text(encoding='utf-8'))
    if state.get('route_scope',{}).get('id')!=scope_id:return False
    state.update(whole_design_route_allowed=False,bitstream_generation_allowed=False,
                 route_scope_status='CLOSED_AFTER_ATTEMPT',
                 scoped_route_result=str(Path(result_path).resolve()),
                 latest_physical_status='SCOPED_ROUTE_ATTEMPT_FINISHED',
                 updated_at=datetime.now().astimezone().isoformat())
    fd,name=tempfile.mkstemp(prefix='.readiness-',dir=record.parent);os.close(fd)
    temporary=Path(name)
    try:
        temporary.write_text(json.dumps(state,indent=2)+'\n',encoding='utf-8')
        os.replace(temporary,record)
    finally:
        if temporary.exists():temporary.unlink()
    return True


DEVICE_LUT_CAPACITY = 66600
# User priority (2026-10-30): all physical LUTs may be used. Keep the old
# 70% statistic for comparisons only; it no longer authorizes/rejects a run.
STRICT_LUT_LIMIT = DEVICE_LUT_CAPACITY + 1
LEGACY_70_PERCENT_LUT = 46620


def read_mapped_resources(build):
    """Read actual MAP utilization, never rounded percentages or SYN estimates.

    Installed PDS 2022.2-SP6.4 Fabric Compiler emits a single LUT Used /
    Available row in pango_video_system.dmr, then 'Device mapping done.'.
    A partial, ambiguous or different-device report cannot authorize PnR.
    The selected build owns this exact report; no latest-file search is used.
    """
    report = Path(build).resolve() / 'device_map/pango_video_system.dmr'
    if not report.is_file():
        raise ValueError('Missing native MAP LUT evidence: ' + str(report))
    payload = report.read_bytes()
    text = payload.decode('utf-8', errors='replace').replace('\r\n', '\n')
    if not text.startswith('Generated by Fabric Compiler ( version 2022.2-SP6.4 <build 146967> )'):
        raise ValueError('Unsupported native MAP report/version: ' + str(report))
    if text.count('Device Utilization Summary:') != 1 or not re.search(r'^Device mapping done\.$', text, re.M):
        raise ValueError('Incomplete or ambiguous native MAP utilization: ' + str(report))
    if re.search(r'^E:', text, re.M):
        raise ValueError('Native MAP report contains an error: ' + str(report))
    section = text.split('Device Utilization Summary:', 1)[1].split('Device mapping done.', 1)[0]
    rows = re.findall(r'^\|\s*LUT\s*\|([^\r\n]*)$', section, re.M)
    if len(rows) != 1:
        raise ValueError('Missing or ambiguous native MAP LUT row: ' + str(report))
    fields = [field.strip() for field in rows[0].split('|')]
    if len(fields) not in (3, 4) or (len(fields) == 4 and fields[3]) or not all(re.fullmatch(r'[0-9]+', field) for field in fields[:3]):
        raise ValueError('Invalid integer native MAP LUT row: ' + str(report))
    used, capacity, rounded_percent = map(int, fields[:3])
    if capacity != DEVICE_LUT_CAPACITY or not 0 < used <= capacity or not 0 <= rounded_percent <= 100:
        raise ValueError('Invalid PG2L100H MAP LUT capacity/count: ' + str(report))
    return dict(report=str(report), report_sha256=hashlib.sha256(payload).hexdigest(),
                device_lut_capacity=capacity, strict_limit_exclusive=STRICT_LUT_LIMIT,
                total_lut=used, utilization_percent=100 * used / capacity,
                within_device_capacity=used <= DEVICE_LUT_CAPACITY,
                artificial_lut_limit_enabled=False,
                below_70_percent=used < LEGACY_70_PERCENT_LUT,
                needed_reduction_for_strict_limit=max(0, used - STRICT_LUT_LIMIT + 1),
                evidence_stage='native MAP, before placement/routing')


def require_mapped_lut_budget(build):
    """Validate native MAP evidence/capacity without a percentage budget.

    Source/simulation/constraint review remains in the independent readiness
    gate. The parser still rejects missing, malformed and over-device counts.
    """
    return read_mapped_resources(build)


def read_routed_resources(build):
    """Read completed native PR physical CLMA+CLMS LUT use, including LUTRAM.

    PDS 2022.2-SP6.4 User Guide PDF page 113 documents placement cell
    duplication; MAP cannot certify the final area. The installed PRR format
    is demonstrated by fpga/build/camera_input_20261012/pds/place_route/
    camera_input_bench.prr. CLMS Distributed RAM is a LUT subset, not another
    resource to add. Per-module totals are not the physical utilization table.
    This parser certifies area evidence only, not STA or source provenance.
    """
    report = Path(build).resolve() / 'place_route/pango_video_system.prr'
    if not report.is_file():
        raise ValueError('Missing native routed LUT evidence: ' + str(report))
    payload = report.read_bytes()
    text = payload.decode('utf-8', errors='replace').replace('\r\n', '\n')
    if not text.startswith('Generated by Fabric Compiler ( version 2022.2-SP6.4 <build 146967> )'):
        raise ValueError('Unsupported native PR report/version: ' + str(report))
    # A placement-only or truncated report may already have plausible resource
    # rows. Require actual routing success, one complete summary and the final
    # native completion footer, and reject explicit error/failure diagnostics.
    markers = (r'^Routing started\.$', r'^Routing done\.$',
               r'^Device Utilization Summary :$',
               r'^Device Utilization Summary Of Each Module:$',
               r'^Flow Command: pnr(?: .*)?$',
               r'^Total real time to pnr completion : \d+h:\d+m:\d+s\s*\Z')
    matches = [list(re.finditer(pattern, text, re.M)) for pattern in markers]
    if any(len(items) != 1 for items in matches):
        raise ValueError('Incomplete or ambiguous native routed utilization: ' + str(report))
    positions = [items[0].start() for items in matches]
    if positions != sorted(positions) or '-place_only' in matches[4][0].group():
        raise ValueError('Native PR report is not a completed route: ' + str(report))
    if re.search(r'^\s*(?:E:|ERROR\b|FATAL\b)|\b(?:routing|placement|pnr)\s+(?:failed|aborted)\b', text, re.M | re.I):
        raise ValueError('Native PR report contains an error: ' + str(report))
    section = text[positions[2]:positions[3]]
    module_section = text[positions[3]:positions[4]]
    if len(re.findall(r'^\|\s*pango_video_system\s*\|', module_section, re.M)) != 1:
        raise ValueError('Missing whole-board native PR module identity: ' + str(report))

    # Track the parent resource row so LUT-FF pairs, module rows and DRAM cannot
    # accidentally be counted as additional LUTs. Exact split capacities bind
    # this gate to the installed PG2L100H device rather than another family.
    counts = {}
    current = None
    parents = []
    for line in section.splitlines():
        if not line.startswith('|'):
            continue
        fields = [field.strip() for field in line.split('|')[1:]]
        if fields and fields[-1] == '':
            fields.pop()
        label = fields[0] if fields else ''
        if label.startswith('Use of '):
            current = label[7:]
            if current in ('CLMA', 'CLMS'):
                parents.append(current)
        if label not in ('LUT', 'Distributed RAM'):
            continue
        if current not in ('CLMA', 'CLMS') or (label == 'Distributed RAM' and current != 'CLMS'):
            raise ValueError('Unscoped native PR LUT row: ' + str(report))
        key = (current, label)
        if key in counts or len(fields) != 4 or not all(re.fullmatch(r'[0-9]+', value) for value in fields[1:]):
            raise ValueError('Invalid or ambiguous native PR LUT row: ' + str(report))
        used, capacity, percent = map(int, fields[1:])
        expected = 46700 if current == 'CLMA' else 19900
        if capacity != expected or not 0 <= used <= capacity or not 0 <= percent <= 100:
            raise ValueError('Invalid PG2L100H routed LUT capacity/count: ' + str(report))
        counts[key] = used
    expected_keys = {('CLMA', 'LUT'), ('CLMS', 'LUT'), ('CLMS', 'Distributed RAM')}
    if parents != ['CLMA', 'CLMS'] or set(counts) != expected_keys:
        raise ValueError('Missing or ambiguous native PR LUT resource blocks: ' + str(report))
    clma, clms = counts['CLMA', 'LUT'], counts['CLMS', 'LUT']
    dram = counts['CLMS', 'Distributed RAM']
    used = clma + clms
    if used == 0 or dram > clms:
        raise ValueError('Invalid native PR LUT/Distributed RAM subset count: ' + str(report))
    return dict(report=str(report), report_sha256=hashlib.sha256(payload).hexdigest(),
                device_lut_capacity=DEVICE_LUT_CAPACITY, strict_limit_exclusive=STRICT_LUT_LIMIT,
                clma_lut=clma, clms_lut=clms, distributed_ram_lut=dram,
                total_lut=used, utilization_percent=100 * used / DEVICE_LUT_CAPACITY,
                within_device_capacity=used <= DEVICE_LUT_CAPACITY,
                artificial_lut_limit_enabled=False,
                below_70_percent=used < LEGACY_70_PERCENT_LUT,
                needed_reduction_for_strict_limit=max(0, used - STRICT_LUT_LIMIT + 1),
                evidence_stage='native PR, after completed routing')


def require_routed_lut_budget(build):
    """Require complete real routing and valid capacity, with no LUT % veto.

    This change does not turn placement-only/timeout reports into successful
    routes and does not alter the separate timing or bitstream release gates.
    """
    return read_routed_resources(build)

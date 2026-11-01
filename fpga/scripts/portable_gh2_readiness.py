"""One independent GH2 destination allowance; historical development scopes do not apply."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path


def record_path():
    return Path(__file__).resolve().parents[1] / 'build/portable_gh2/readiness.json'


def validate_route_scope(state, build, options):
    """Bind relocated inputs, destination shell, runtime scripts and exact options."""
    scope = state.get('route_scope', {})
    if (not scope or not state.get('pre_route_review_complete')
            or state.get('bitstream_generation_allowed')):
        raise ValueError('GH2 portable scope absent/unreviewed')
    if Path(build).resolve() != Path(scope['build']).resolve():
        raise ValueError('Different GH2 portable build')
    if vars(options) != scope['options']:
        raise ValueError('Options differ from the single GH2 scope')
    base = Path(build).resolve()
    for name, digest in scope['files'].items():
        path = (base / name).resolve()
        if (not path.is_relative_to(base) or not path.is_file()
                or hashlib.sha256(path.read_bytes()).hexdigest() != digest):
            raise ValueError('GH2 portable input drift: ' + name)
    for name, digest in scope['external_files'].items():
        path = Path(name)
        if not path.is_file() or hashlib.sha256(path.read_bytes()).hexdigest() != digest:
            raise ValueError('GH2 tool/proof drift: ' + name)


def require_whole_design_ready(build, options):
    """Only the newly prepared destination gate can admit this physical run."""
    state = json.loads(record_path().read_text(encoding='utf-8'))
    required = ('design_complete', 'selected_source_simulation_passed',
                'resource_and_constraints_reviewed', 'whole_design_route_allowed')
    if any(state.get(key) is not True for key in required) or state.get('user_gui_approval_required'):
        raise ValueError('GH2 portable physical allowance is closed')
    validate_route_scope(state, build, options)
    return state


def close_route_scope(scope_id, result_path, record=None):
    """Consume this allowance on every attempted run, including native failure."""
    path = Path(record) if record is not None else record_path()
    state = json.loads(path.read_text(encoding='utf-8'))
    if state.get('route_scope', {}).get('id') != scope_id:
        return False
    state.update(whole_design_route_allowed=False, bitstream_generation_allowed=False,
                 route_scope_status='CLOSED_AFTER_ATTEMPT',
                 scoped_route_result=str(Path(result_path).resolve()),
                 updated_at=datetime.now().astimezone().isoformat())
    temporary = path.with_suffix('.closing.json')
    temporary.write_text(json.dumps(state, indent=2) + '\n', encoding='utf-8')
    os.replace(temporary, path)
    return True

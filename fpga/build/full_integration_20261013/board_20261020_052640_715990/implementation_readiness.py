"""Enforce the user's design-completion gate at whole-design entry points."""
import json
from pathlib import Path


def require_whole_design_ready():
    """Fail closed before creating or resuming whole-design physical jobs.

    Regional probes deliberately use separate, top-restricted entry points.
    Updating this record is a reviewed project change, not a CLI bypass flag.
    """
    record = Path(__file__).resolve().parents[1]/'config/implementation_readiness.json'
    state = json.loads(record.read_text(encoding='utf-8'))
    required = ('design_complete','selected_source_simulation_passed',
                'resource_and_constraints_reviewed','whole_design_route_allowed')
    missing = [name for name in required if state.get(name) is not True]
    if missing:
        raise ValueError('Whole-design implementation is blocked by the user design-completion gate: '
                         + ', '.join(missing) + '. See '+str(record))
    return state

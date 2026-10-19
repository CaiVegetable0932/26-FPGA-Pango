"""Promote exactly one reviewed file after binding its complete proof closure."""
from datetime import datetime
import hashlib
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parents[4]
FPGA = ROOT/'fpga'
SESSION = Path(__file__).resolve().parent
FINALIST = SESSION/'unpack_finalist'
MODEL = FPGA/'build/full_integration_20261013/verilator_20261020_001232_095496'
REGRESSION = FPGA/'build/full_integration_20261013/sim_20261020_001153_047628'
CANDIDATE = FPGA/'build/route_optimization/unpack_local_capture_20261019_221324_680300'
HOST = ROOT/'host/reports/fpga_rgb_vectors_20261020_003432_815058.json'
NAME = 'rtl/memory/dma_byte_unpack.v'


def sha(path):
    """Compare exact bytes under the existing no-newline-conversion rules."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def load(path):
    return json.loads(path.read_text(encoding='utf-8'))


def atomic_json(path, data):
    """Publish complete metadata even while a read-only observer is active."""
    temporary = path.with_suffix('.write.tmp')
    temporary.write_text(json.dumps(data, indent=2)+'\n', encoding='utf-8')
    os.replace(temporary, path)


# Keep frozen evidence unchanged. Every source must still match its manifest.
closure = load(FINALIST/'sources.json')
assert all(sha(FINALIST/'source'/n) == h for n, h in closure.items())
differences = [n for n, h in closure.items() if sha(FPGA/n) != h]
assert differences == [NAME], differences
assert sha(FPGA/NAME) == sha(CANDIDATE/'original_dma_byte_unpack.v')
assert sha(FINALIST/'source'/NAME) == sha(CANDIDATE/'source'/NAME)
proof = load(CANDIDATE/'differential_20261019_221418_033659/result.json')
assert all(proof.get(k) for k in ('passed', 'cycle_equivalent', 'inputs_intact'))
assert all(sha(Path(n)) == h for n, h in proof['inputs'].items())
model_result = load(MODEL/'result.json')
assert model_result['passed'] and model_result['snapshot_intact']
model_sources = load(MODEL/'sources.json')
assert all(sha(MODEL/'source'/n) == h for n, h in model_sources.items())
assert all(closure.get(n) == h for n, h in model_sources.items() if n.startswith('rtl/'))
regression = load(REGRESSION/'result.json')
assert regression['passed'] and len(regression['tests']) == 20
regression_sources = load(REGRESSION/'sources.json')
assert all(sha(REGRESSION/'source'/Path(n).name) == h for n, h in regression_sources.items())
assert all(closure.get(n) == h for n, h in regression_sources.items() if n.startswith('rtl/'))
assert all(v['identical'] for v in load(MODEL/'snapshot_baseline_comparison.json').values())
host = load(HOST)
assert host['passed'] and host['companion_snapshot_intact']
assert Path(host['input_directory']) == MODEL
assert all(sha(Path(host['companion_snapshot_directory'])/n) == h
           for n, h in host['companion_files_sha256'].items())
seeds = load(CANDIDATE/'unit_screen_20261019_233122_395009/three_seed_summary.json')
assert seeds['all_three_both_internal_sta_pass'] and seeds['sample_count'] == 3

# Back up the original before a single atomic RTL replacement. The complete
# source closure was already checked; no unrelated candidate files are copied.
backup = SESSION/'unpack_promotion_20261020'
backup.mkdir()
target = FPGA/NAME
before = target.read_bytes()
(backup/'before_dma_byte_unpack.v').write_bytes(before)
temporary = target.with_suffix('.promotion.tmp')
temporary.write_bytes((FINALIST/'source'/NAME).read_bytes())
os.replace(temporary, target)
try:
    assert all(sha(FPGA/n) == h for n, h in closure.items())
    assert all(sha(FPGA/n) == h for n, h in model_sources.items() if n.startswith('rtl/'))
except BaseException:
    temporary.write_bytes(before)
    os.replace(temporary, target)
    raise
record = dict(at=datetime.now().astimezone().isoformat(), promoted_file=NAME,
    before_sha256=hashlib.sha256(before).hexdigest(), after_sha256=sha(target),
    source_files_bound=len(closure), model_inputs_bound=len(model_sources),
    model=str(MODEL), regression=str(REGRESSION), host_report=str(HOST),
    median_pnr_reduction_percent=seeds['median_reduction_percent'],
    target_30_percent_met=False, whole_design_route_allowed=False,
    reason='Modest consistent three-seed real-reader improvement, full functional and byte proofs passed')
atomic_json(backup/'promotion.json', record)
selection = load(FINALIST/'selection.json')
selection.update(status='PROMOTED_SINGLE_FILE', full_frame_status='PASS',
                 host_report=str(HOST), promotion_record=str(backup/'promotion.json'))
atomic_json(FINALIST/'selection_promoted_20261020.json', selection)
print('PROMOTED', NAME, 'all', len(closure), 'source hashes match verified finalist')

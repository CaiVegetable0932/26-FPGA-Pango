"""Clone a reviewed MAP for one physical-policy trial without replacing its PLC."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
from constraint_report import require_native_constraints
from implementation_readiness import require_mapped_lut_budget


def sha(path):
    """Verify checkpoint and source identity across directory relocation."""
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    """Read preserved review evidence without changing its claims."""
    return json.loads(path.read_text(encoding='utf-8-sig'))


def main():
    """Copy exact native inputs; only project metadata output paths relocate."""
    ap=argparse.ArgumentParser(description=__doc__)
    ap.add_argument('--audit',required=True,type=Path)
    a=ap.parse_args();fpga=Path(__file__).resolve().parents[1]
    audit=read(a.audit);assert audit['passed'] and all(audit['checks'].values())
    source=Path(audit['mapping']);manifest=read(source/'sources.json')
    assert all(sha(source/'source'/n)==h for n,h in manifest.items())
    assert all(sha(source/n)==h for n,h in audit['artifacts'].items())
    for item in audit['evidence'].values():assert sha(Path(item['path']))==item['sha256']
    target=fpga/'build/full_integration_20261013'/datetime.now().strftime('control_policy_%Y%m%d_%H%M%S_%f')
    target.mkdir()
    # Exclude all prior physical outputs, reports and locks. The old PLC and
    # its incomplete routing evidence remain available for comparison.
    for name in ['source','synthesize','device_map','constraint_check']:
        assert not list((source/name).rglob('*.lock'))
        shutil.copytree(source/name,target/name)
    # Native constraint review also consumes the exact MAP console evidence.
    for name in ['sources.json','result.json','console.log']:
        shutil.copyfile(source/name,target/name)
    for name in ['flow.tcl','flow.pds']:
        text=(source/name).read_text(encoding='utf-8')
        text=text.replace(source.as_posix(),target.as_posix()).replace(str(source),str(target))
        (target/name).write_text(text,encoding='utf-8')
    shutil.copyfile(__file__,target/'prepare_study.py')
    shutil.copyfile(a.audit,target/'parent_review.json')
    assert all(sha(target/'source'/n)==h for n,h in manifest.items())
    unchanged=[n for n in audit['artifacts'] if n!='flow.tcl']
    assert all(sha(source/n)==sha(target/n) for n in unchanged)
    require_native_constraints(target);require_mapped_lut_budget(target)
    # Preserve the original functional proofs and attach the relocation proof.
    # No copied physical status is presented as a newly executed result.
    audit.update(mapping=str(target),parent_mapping=str(source),physical=None,
        physical_feedback_path=None,routed=False,production_selected=False)
    audit['checks']['relocated_native_inputs_identical']=True
    audit['artifacts']={n:sha(target/n) for n in audit['artifacts']}
    audit['evidence']['mapping']=dict(path=str(target/'result.json'),sha256=sha(target/'result.json'))
    audit['evidence']['parent_review']=dict(path=str(a.audit.resolve()),sha256=sha(a.audit))
    (target/'review.json').write_text(json.dumps(audit,indent=2),encoding='utf-8')
    print('PLACEMENT_STUDY',target,flush=True)


if __name__=='__main__':main()

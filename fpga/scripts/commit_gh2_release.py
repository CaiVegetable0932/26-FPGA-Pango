"""Create an isolated GH2 release commit without touching the user's index/live tree.

The reviewed portable payload supplies exact bytes. Git plumbing uses a separate
index and a new branch, so unrelated working changes never enter this delivery.
No network or native FPGA tool is invoked by this script.
"""
from pathlib import Path
import hashlib
import json
import os
import subprocess

ROOT = Path(__file__).resolve().parents[2]
PREP = ROOT / 'fpga/build/gh2_release_preparation_20261101'
BRANCH = 'codex/gray-gh2-portable-20261101'
PARENT = '00f3e23f996206d18a0bcebe614e83cf3dff8c51'


def git(*args, data=None, env=None):
    """Pass paths and text as structured argv/bytes, never through shell quoting."""
    return subprocess.run(['git', '-c', 'core.fsmonitor=false', *args], cwd=ROOT,
                          input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                          check=True, env=env).stdout


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def main():
    """Bind the inspected package and hardware overlay to one immutable commit."""
    if (PREP/'commit_review.json').exists():
        raise ValueError('Commit already recorded; inspect rather than repeat')
    review=json.loads((PREP/'release_review.json').read_text(encoding='utf-8'))
    if not review['passed'] or digest(Path(review['zip'])) != review['zip_sha256']:
        raise ValueError('Reviewed release ZIP missing or changed')
    independent=json.loads((PREP/'independent_review/package_review.json').read_text(encoding='utf-8'))
    if independent.get('passed') is not True:
        raise ValueError('Independent package audit required')
    stage=Path(review['package_root'])
    manifest=json.loads((stage/'fpga/release/gray_GH2_20261101/manifest.json').read_text(encoding='utf-8'))
    for name, value in manifest['files'].items():
        if digest(stage/name) != value:
            raise ValueError('Payload changed: '+name)
    if git('rev-parse','HEAD').decode().strip()!=PARENT:
        raise ValueError('Parent changed; review required')
    branch_before=git('symbolic-ref','HEAD').decode().strip()
    real_index=ROOT/'.git/index'; index_before=digest(real_index)
    files={p.relative_to(stage).as_posix():p for p in stage.rglob('*') if p.is_file()}
    inputs=stage/manifest['inputs']
    sources=json.loads((inputs/'sources.json').read_text(encoding='utf-8'))
    hardware={n:h for n,h in sources.items() if n.startswith(('rtl/','ip/','constraints/'))}
    if len(hardware)!=310:
        raise ValueError('Unexpected hardware closure')
    files.update({'fpga/'+n:inputs/'source'/n for n in hardware})
    for name in ('.gitattributes','AGENTS.md'):
        files[name]=PREP/'cloud_metadata'/name
    files['fpga/config/implementation_readiness.json']=PREP/'cloud_metadata/implementation_readiness.json'
    for name in ('package_gh2_portable.py','commit_gh2_release.py','test_portable_gh2_offline.py'):
        path=ROOT/'fpga/scripts'/name
        if path.is_file(): files[path.relative_to(ROOT).as_posix()]=path
    for path in (Path(review['zip']),Path(review['zip']).with_suffix('.zip.sha256')):
        files[path.relative_to(ROOT).as_posix()]=path
    for path in (PREP/'release_review.json', PREP/'independent_review/source_evidence_review.json',
                 PREP/'independent_review/package_review.json',
                 PREP/'offline_130357_590671/review.json'):
        if path.is_file(): files[path.relative_to(ROOT).as_posix()]=path
    if any(p.stat().st_size>=100*1024*1024 for p in files.values()):
        raise ValueError('GitHub per-file limit exceeded')
    isolated=PREP/'release.gitindex'
    if isolated.exists(): raise ValueError('Isolated index already exists')
    env=os.environ.copy(); env['GIT_INDEX_FILE']=str(isolated)
    git('read-tree',PARENT,env=env)
    rows=[]
    for name,path in sorted(files.items()):
        oid=git('hash-object','-w','--no-filters','--',str(path)).decode().strip()
        rows.append(('100644 '+oid+'\t'+name+'\0').encode('utf-8'))
    git('update-index','-z','--index-info',data=b''.join(rows),env=env)
    tree=git('write-tree',env=env).decode().strip()
    message=('Release verified GH2 design and portable PDS 2022 routing handoff\n\n'
             'Publish exact GH2 source/MAP/proof bytes and a one-use external fresh-placement '
             'PnR plus min/max STA runner. Functional, SYN/MAP and netlist checks passed; '
             'physical routing and hardware validation remain pending.\n')
    commit=git('commit-tree',tree,'-p',PARENT,data=message.encode(),env=env).decode().strip()
    git('update-ref','refs/heads/'+BRANCH,commit,'0'*40)
    if git('symbolic-ref','HEAD').decode().strip()!=branch_before or digest(real_index)!=index_before:
        raise ValueError('Primary branch/index changed unexpectedly')
    output=dict(passed=True,branch=BRANCH,commit=commit,tree=tree,parent=PARENT,
                source_count=327,hardware_count=310,files_supplied=len(files),
                primary_branch_unchanged=True,primary_index_unchanged=True,
                zip_sha256=review['zip_sha256'],pushed=False)
    (PREP/'commit_review.json').write_text(json.dumps(output,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(output,indent=2))


if __name__=='__main__':
    main()

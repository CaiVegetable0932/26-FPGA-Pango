"""Publish only the reviewed FPGA delivery tree, excluding local build history.

The staging commit remains recorded as provenance. This new root commit is a
portable snapshot, matching the earlier portable-release branch convention.
No remote reference, primary branch/index or working design is changed here.
"""
import json
import os
from pathlib import Path
from commit_gh2_release import ROOT, PREP, BRANCH, git, digest


def main():
    old=json.loads((PREP/'commit_review.json').read_text())
    if (PREP/'staging_commit_review.json').exists(): raise ValueError('Already snapshotted')
    stage=PREP/'package'
    manifest=json.loads((stage/'fpga/release/gray_GH2_20261101/manifest.json').read_text())
    sources=json.loads((stage/manifest['inputs']/'sources.json').read_text())
    wanted={p.relative_to(stage).as_posix() for p in stage.rglob('*') if p.is_file()}
    wanted.update('fpga/'+n for n in sources if n.startswith(('rtl/','ip/','constraints/')))
    wanted.update(['AGENTS.md','.gitattributes','fpga/config/implementation_readiness.json',
      'fpga/scripts/package_gh2_portable.py','fpga/scripts/commit_gh2_release.py',
      'fpga/scripts/test_portable_gh2_offline.py',
      'fpga/release/packages/gray_GH2_portable_20261101.zip',
      'fpga/release/packages/gray_GH2_portable_20261101.zip.sha256'])
    wanted.update('fpga/build/gh2_release_preparation_20261101/'+n for n in
       ['release_review.json','independent_review/source_evidence_review.json',
        'independent_review/package_review.json','offline_130357_590671/review.json'])
    entries={}
    for row in git('ls-tree','-r','-z',old['commit']).split(b'\0'):
        if not row: continue
        meta,name=row.split(b'\t',1); path=name.decode()
        if path in wanted:
            mode,kind,oid=meta.split(); entries[path]=mode+b' '+oid+b'\t'+name+b'\0'
    if set(entries)!=wanted: raise ValueError('Missing selected release paths')
    additions={'README.md':PREP/'cloud_metadata/README.md',
               'fpga/scripts/snapshot_gh2_release.py':Path(__file__).resolve(),
               'fpga/scripts/audit_gh2_git_delivery.py':ROOT/'fpga/scripts/audit_gh2_git_delivery.py'}
    additions.update({'fpga/'+n:stage/manifest['inputs']/'source'/n for n in sources
                      if n.startswith('config/') and n!='config/implementation_readiness.json'})
    for name,path in additions.items():
        oid=git('hash-object','-w','--no-filters','--',str(path)).strip()
        entries[name]=b'100644 '+oid+b'\t'+name.encode()+b'\0'
    env=os.environ.copy(); index=PREP/'snapshot.gitindex'
    if index.exists(): raise ValueError('Snapshot index already exists')
    env['GIT_INDEX_FILE']=str(index)
    real_index=ROOT/'.git/index'; before=digest(real_index)
    git('read-tree','--empty',env=env)
    git('update-index','-z','--index-info',data=b''.join(entries[n] for n in sorted(entries)),env=env)
    tree=git('write-tree',env=env).decode().strip()
    commit=git('commit-tree',tree,data=b'Release verified GH2 PG2L100H design and portable PDS 2022 PnR handoff\n\nStandalone delivery of the exact functional/SYN/MAP/netlist-reviewed inputs. Fresh external placement/routing and min/max STA remain pending; no bitstream or programming.\n').decode().strip()
    git('update-ref','refs/heads/'+BRANCH,commit,old['commit'])
    if digest(real_index)!=before: raise ValueError('Primary index drift')
    (PREP/'staging_commit_review.json').write_text(json.dumps(old,indent=2)+'\n')
    result=dict(old,commit=commit,tree=tree,parent=None,design_base=old['parent'],
                staging_commit=old['commit'],standalone_release=True,files_supplied=len(entries))
    (PREP/'commit_review.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()

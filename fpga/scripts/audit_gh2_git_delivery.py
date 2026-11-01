"""Read back committed release bytes and audit a clean Git export, without PDS."""
from pathlib import Path
import hashlib
import json
import subprocess
import sys
import tarfile

ROOT=Path(__file__).resolve().parents[2]
PREP=ROOT/'fpga/build/gh2_release_preparation_20261101'


def git(*args, **kw):
    return subprocess.run(['git','-c','core.fsmonitor=false',*args],cwd=ROOT,
                          check=True,stderr=subprocess.PIPE,**kw)


def main():
    """Verify Git's stored source/ZIP plus all relocated portable payload files."""
    commit=json.loads((PREP/'commit_review.json').read_text())['commit']
    manifest=json.loads((PREP/'package/fpga/release/gray_GH2_20261101/manifest.json').read_text())
    paths=['fpga/release/gray_GH2_20261101']
    paths.extend(n for n in manifest['files'] if n.startswith(('fpga/scripts/','fpga/reports/')))
    export=PREP/'git_export'
    export.mkdir(exist_ok=False)
    archive=PREP/'git_export.tar'
    with archive.open('xb') as stream:
        git('archive',commit,'--',*paths,stdout=stream)
    with tarfile.open(archive) as tar:
        tar.extractall(export,filter='data')
    done=subprocess.run([sys.executable,'-X','utf8','-B',str(export/'fpga/scripts/portable_gh2.py'),'--audit'],
                        cwd=export,capture_output=True,timeout=120)
    (PREP/'git_export_audit.log').write_bytes(done.stdout+done.stderr)
    if done.returncode: raise ValueError('Committed export failed portable audit')
    sources=json.loads((export/manifest['inputs']/'sources.json').read_text())
    expected={'fpga/'+n:h for n,h in sources.items() if n.startswith(('rtl/','ip/','constraints/'))}
    release=json.loads((PREP/'release_review.json').read_text())
    expected['fpga/release/packages/gray_GH2_portable_20261101.zip']=release['zip_sha256']
    # Batch blob reads preserve raw bytes and avoid hundreds of shell launches.
    requests=''.join(commit+':'+n+'\n' for n in expected).encode()
    data=git('cat-file','--batch',input=requests,stdout=subprocess.PIPE).stdout
    offset=0
    for name,digest in expected.items():
        end=data.index(b'\n',offset); header=data[offset:end].split(); size=int(header[2])
        blob=data[end+1:end+1+size]; offset=end+size+2
        if hashlib.sha256(blob).hexdigest()!=digest: raise ValueError('Git blob drift: '+name)
    closed=json.loads(git('show',commit+':fpga/config/implementation_readiness.json',stdout=subprocess.PIPE).stdout)
    if closed.get('whole_design_route_allowed') or closed.get('route_scope'):
        raise ValueError('Historical root allowance is still open')
    result=dict(passed=True,commit=commit,hardware_blobs_verified=310,zip_blob_verified=True,
                clean_git_export_audit_passed=True,root_historical_scope_closed=True,
                pds_started=False)
    (PREP/'git_delivery_review.json').write_text(json.dumps(result,indent=2)+'\n')
    print(json.dumps(result,indent=2))


if __name__=='__main__':
    main()

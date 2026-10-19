"""Freeze explicit terminal proofs and physical cases, without broad Git staging."""
from pathlib import Path
import argparse,hashlib,json,zipfile

def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--label',required=True)
    parser.add_argument('--session',type=Path,required=True)
    parser.add_argument('--proof',type=Path,nargs='*',default=[])
    parser.add_argument('--native-case',type=Path,nargs='*',default=[])
    parser.add_argument('--input-tree',type=Path,nargs='*',default=[])
    parser.add_argument('--file',type=Path,nargs='*',default=[])
    args=parser.parse_args();root=Path(__file__).resolve().parents[2]
    if not args.label.isalnum():raise ValueError('Alphanumeric immutable checkpoint label required')
    session=args.session.resolve()
    files={Path(__file__).resolve(),*(p.resolve() for p in args.file)}
    suffixes={'.json','.jsonl','.log','.py','.tcl','.v','.sv','.vh','.fdc','.pds','.csv','.hex','.md','.idf','.rgb'}
    def small(folder):
        for p in folder.rglob('*'):
            if p.is_file() and p.suffix.lower() in suffixes:files.add(p)
    for folder in args.proof:
        folder=folder.resolve();d=json.loads((folder/'result.json').read_text())
        if not isinstance(d.get('passed'),bool):raise ValueError('Proof must have a terminal pass/fail record')
        small(folder)
    for folder in args.input_tree:small(folder.resolve())
    for case in args.native_case:
        case=case.resolve();d=json.loads((case/'result.json').read_text())
        if not d.get('completed'):raise ValueError('Physical case must be terminal and complete')
        small(case);target=case/('native_checkpoints_'+args.label+'.zip');members={}
        if target.exists():raise ValueError('Never overwrite frozen archives')
        with zipfile.ZipFile(target,'w',zipfile.ZIP_DEFLATED,compresslevel=6) as z:
            for j in d['jobs']:
                for p in sorted((case/j['label']).rglob('*')):
                    if p.is_file() and (p.suffix.lower() in {'.adf','.vm','.snr','.dmr','.prr','.rtr','.prt','.netlist','.pcf'} or 'CongestionNetInfo' in p.name):
                        name=p.relative_to(case).as_posix();z.write(p,name);members[name]=dict(bytes=p.stat().st_size,sha256=sha(p))
        with zipfile.ZipFile(target) as z:
            assert z.testzip() is None
            assert all(hashlib.sha256(z.read(n)).hexdigest()==v['sha256'] for n,v in members.items())
        manifest=case/('native_checkpoints_'+args.label+'_manifest.json')
        manifest.write_text(json.dumps(dict(archive_sha256=sha(target),members=members),indent=2));files.update([target,manifest])
    if not all(p.is_relative_to(root) for p in files):raise ValueError('Checkpoint must stay in this project')
    manifest=session/('checkpoint_'+args.label+'_manifest.json')
    if manifest.exists():raise ValueError('Checkpoint already frozen')
    entries={p.relative_to(root).as_posix():dict(bytes=p.stat().st_size,sha256=sha(p)) for p in sorted(files)}
    manifest.write_text(json.dumps(dict(files=entries),indent=2))
    scope=session/('checkpoint_'+args.label+'_scope.txt')
    scope.write_text('\n'.join(entries)+'\n'+manifest.relative_to(root).as_posix()+'\n')
    print('FROZEN',len(entries),'bytes',sum(v['bytes'] for v in entries.values()),'scope',scope)

if __name__=='__main__':main()

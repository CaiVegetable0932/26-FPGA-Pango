"""Verify every checkpoint member has identical working-tree and staged bytes."""
from pathlib import Path
import argparse,hashlib,io,json,subprocess

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('manifest',type=Path)
    args=parser.parse_args()
    root=Path(__file__).resolve().parents[2]
    files=json.loads(args.manifest.read_text())['files']
    # One binary batch avoids shell escaping and hundreds of Git processes.
    result=subprocess.run(['git','-c','core.fsmonitor=false','cat-file','--batch'],
        input=''.join(':'+name+'\n' for name in files).encode(),cwd=root,capture_output=True,check=True)
    stream=io.BytesIO(result.stdout);bad=[]
    for name,entry in files.items():
        header=stream.readline().split()
        assert len(header)==3 and header[1]==b'blob',header
        data=stream.read(int(header[2]));assert stream.read(1)==b'\n'
        if (hashlib.sha256(data).hexdigest()!=entry['sha256'] or
            hashlib.sha256((root/name).read_bytes()).hexdigest()!=entry['sha256']):bad.append(name)
    print('STAGED_BYTE_AUDIT',len(files),'mismatches',bad)
    if bad:raise SystemExit(1)

if __name__=='__main__':main()

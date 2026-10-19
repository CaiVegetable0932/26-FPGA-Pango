"""Preserve frozen companion bytes through Git and create a new final manifest."""
from pathlib import Path
import hashlib,json
S=Path(__file__).parent;R=S.parents[3];a=R/'host/reports/.gitattributes'
t=a.read_text(encoding='utf-8').replace('\r\n','\n')+'\nfpga_rgb_vectors_20261020_050710_104188_companions/** -text\n'
a.write_bytes(t.encode())
old=S/'checkpoint_0515_manifest.json';names=list(json.loads(old.read_text())['files'])
names += [old.relative_to(R).as_posix(),Path(__file__).relative_to(R).as_posix(),(S/'git_lock_audit_0513.json').relative_to(R).as_posix()]
entries={n:dict(bytes=(R/n).stat().st_size,sha256=hashlib.sha256((R/n).read_bytes()).hexdigest()) for n in names}
m=S/'checkpoint_0515final_manifest.json';assert not m.exists();m.write_text(json.dumps(dict(files=entries),indent=2))
(S/'checkpoint_0515final_scope.txt').write_text('\n'.join(entries)+'\n'+m.relative_to(R).as_posix()+'\n')

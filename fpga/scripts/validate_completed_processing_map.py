"""Verify actual SYN/MAP artifacts after the old host output-path assertion."""
from pathlib import Path
import argparse,hashlib,json,re
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--mapping',type=Path,required=True);a=p.parse_args();r=a.mapping.resolve()
    d=json.loads((r/'result.json').read_text());assert len(d['phases'])==2
    assert not d['passed'] and all(x['status']=='COMPLETED' and x['returncode']==0 for x in d['phases'])
    assert 'r/action/' in (r/'continuation_script.py').read_text(),'This review only covers the recorded old directory assertion'
    b=Path(d['source_build']);assert all(sha(b/'source'/n)==v for n,v in d['source_hashes'].items())
    artifacts={}
    for action,folder,suffix in [('synthesize','synthesize','syn'),('dev_map','device_map','map')]:
        log=(r/(action+'.log')).read_text(errors='replace')
        assert not re.search(r'^E:',log,re.M) and re.search(r'Executing : '+action+r'.* successfully\.',log)
        db=r/folder/('pango_video_system_'+suffix+'.adf')
        assert db.is_file() and db.stat().st_size>1000000 and not db.with_suffix('.adf.lock').exists()
        artifacts[db.relative_to(r).as_posix()]=sha(db)
        artifacts[action+'.log']=sha(r/(action+'.log'))
    assert (r/'device_map/pango_video_system.dmr').is_file()
    d.update(passed=True,inputs_intact=True,native_stages_completed=True,
        original_host_result_preserved=True,original_host_failure='wrong output folder dev_map instead of device_map',
        original_result_sha256=sha(r/'result.json'),validated_artifacts=artifacts,routed=False,bitstream_generated=False)
    target=r/'mapping_validation.json';assert not target.exists();target.write_text(json.dumps(d,indent=2))
    print('VERIFIED_NATIVE_SYN_MAP',r)
if __name__=='__main__':main()

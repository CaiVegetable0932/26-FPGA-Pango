"""Guard optional snapshot hierarchy without changing the snapshot oracle."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json
def sha(p):return hashlib.sha256(p.read_bytes()).hexdigest()
def adapt(text):
    old='wait(dut.network.snapshot_output.snapshot.complete_frames==2);'
    assert text.count(old)==1
    # Constant generate removes a reference to a deliberately absent optional
    # instance; when enabled it observes precisely the original counter/net.
    declaration=''' wire [31:0] snapshot_complete_frames_for_test;
 generate if(SNAPSHOT_TEST)begin: snapshot_counter_probe
  assign snapshot_complete_frames_for_test=dut.network.snapshot_output.snapshot.complete_frames;
 end else begin: no_snapshot_counter_probe
  assign snapshot_complete_frames_for_test=0;
 end endgenerate
'''
    anchor=' initial begin\n  if(SNAPSHOT_TEST)snapshot_file='
    assert text.count(anchor)==1
    text=text.replace(anchor,declaration+anchor,1)
    return text.replace(old,'wait(snapshot_complete_frames_for_test==2);',1)
def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--input',type=Path,required=True);a=p.parse_args()
    f=Path(__file__).resolve().parents[1];b=a.input.resolve();hashes=json.loads((b/'sources.json').read_text())
    assert all(sha(b/'source'/n)==v for n,v in hashes.items())
    r=f/'build/route_optimization'/datetime.now().strftime('proc150_fixture_%Y%m%d_%H%M%S_%f');s=r/'source/sim';s.mkdir(parents=True)
    src=b/'source/sim/tb_video_memory_core.sv';dst=s/src.name;dst.write_text(adapt(src.read_text()),encoding='utf-8',newline='\n')
    # The Verilator fixture override is a complete two-file fixture bundle.
    display=s/'video_core_display_fixture.sv';display.write_bytes((b/'source/sim'/display.name).read_bytes())
    (r/'sources.json').write_text(json.dumps({'sim/'+q.name:sha(q) for q in [dst,display]},indent=2))
    (r/'fixture_adaptation.json').write_text(json.dumps(dict(before_sha256=sha(src),after_sha256=sha(dst),
        input=str(b),snapshot_enabled_observation_unchanged=True,no_rtl_change=True,independent_assertions_removed=0),indent=2))
    print('PROCESSING_FIXTURE',r)
if __name__=='__main__':main()

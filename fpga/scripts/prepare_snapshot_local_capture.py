"""Prepare same-edge slot/generation capture with six local idle flags."""
from datetime import datetime
import hashlib,json,shutil
from pathlib import Path


def localize(text):
    declaration = ' reg [1:0] ss,rs;reg [31:0] sg,rg,dsg,drg;reg [255:0] buffer;'
    capture = 'if(start && ready)begin ss<=source_slot;rs<=result_slot;sg<=source_gen;rg<=result_gen;dsg<=s1_gen;drg<=dst_gen;'
    reset = '   ss<=0;rs<=0;sg<=0;rg<=0;dsg<=0;drg<=0;buffer<=0;done<=0;failed<=0;end'
    anchor = ' always @(posedge clk or negedge rst_n)begin'
    for marker in [declaration,capture,reset,anchor]:
        if text.count(marker)!=1:
            raise ValueError('Unexpected snapshot control: '+marker)
    logic = '''
 // Mirror the actual post-edge IDLE predicate, including error/cancel and
 // last-image completion. These are control copies, not a pipeline stage.
 // Public ready and the state machine retain their original decode.
 reg [5:0] local_idle /* synthesis syn_preserve=1 */;
 wire completion_error=cancel || aborting || dma_error || dma_cancelled || done_tag!=req_tag ||
   (!writing && !received && !(r_valid && r_ready)) ||
   (writing && !sent && !(w_valid && w_ready));
 wire completion_last=writing && !(column+32<WIDTH*3) && !(row<HEIGHT-1) && image;
 wire idle_after=(state==IDLE) ? !start :
   ((state==READ_REQ || state==WRITE_REQ) ? (cancel || aborting) :
   ((state==READ_WAIT || state==WRITE_WAIT) && dma_done && (completion_error || completion_last)));
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)local_idle<=6'b111111;
  else local_idle<={6{idle_after}};
 end
'''
    for i,(name,source) in enumerate([('ss','source_slot'),('rs','result_slot'),
                                      ('sg','source_gen'),('rg','result_gen'),('dsg','s1_gen'),('drg','dst_gen')]):
        logic += f''' // Local metadata CE keeps the original accepted START edge and reset.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n){name}<=0;
  else if(start && local_idle[{i}]){name}<={source};
 end
'''
    return text.replace(capture,'if(start && ready)begin').replace(reset,
        '   buffer<=0;done<=0;failed<=0;end').replace(anchor,logic+anchor)


def main():
    fpga=Path(__file__).resolve().parents[1]
    names=json.loads((fpga/'build/route_optimization/session_20261019/unpack_finalist/sources.json').read_text())
    run=fpga/'build/route_optimization'/datetime.now().strftime('snapshot_local_capture_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    for name,expected in names.items():
        p=fpga/name
        if hashlib.sha256(p.read_bytes()).hexdigest()!=expected:raise ValueError('Main drift: '+name)
        target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
    target=source/'rtl/memory/snapshot_copy_dma.sv'
    shutil.copyfile(target,run/'original_snapshot_copy_dma.sv')
    target.write_text(localize(target.read_text(encoding='utf-8')),encoding='utf-8',newline='\n')
    (run/'sources.json').write_text(json.dumps({n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names},indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/snapshot_copy_dma.sv'],extra_flags=6,extra_latency_cycles=0,
        reset_retained=True,payload_memory_unchanged=True),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print(run)


if __name__=='__main__':main()

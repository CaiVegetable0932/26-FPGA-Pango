"""Add exactly two frame-start cycles to register full span legality arithmetic."""
import argparse
from datetime import datetime
import hashlib,json,shutil
from pathlib import Path


def pipeline(text):
    before=' localparam IDLE=0,START_PACK=1,COLLECT=2,REQUEST=3,FEED=4,DRAIN=5,FINISH=6;\n reg [2:0] state;'
    after=' localparam IDLE=0,START_PACK=1,COLLECT=2,REQUEST=3,FEED=4,DRAIN=5,FINISH=6,CHECK_SUM=7,CHECK_RANGE=8;\n reg [3:0] state;'
    if text.count(before)!=1:raise ValueError('Unexpected writer states')
    text=text.replace(before,after)
    before=""" wire [63:0] span_end={32'd0,frame_base}+{{14{row_span[49]}},row_span}+
  {48'd0,frame_width}*(frame_rgb888 ? 64'd3 : 64'd1);"""
    after=""" wire [63:0] width_span={48'd0,frame_width}*(frame_rgb888 ? 64'd3 : 64'd1);
 // Only frame admission gains two cycles. Segment collection and DMA
 // prefetch retain their old cadence. Elastic producers must hold pixels
 // until in_ready; no request or pixel can be accepted before legality.
 // Payload registers are written before their state becomes observable;
 // cold reset invalidates the states without a new wide data-reset tree.
 reg signed [49:0] row_span_q;
 reg [63:0] width_span_q,rounded_span_q;
 reg shape_bad_q;
 always @(posedge clk)begin
  if(rst_n && state==IDLE && frame_valid)begin
   row_span_q<=row_span;width_span_q<=width_span;
   shape_bad_q<=frame_width==0 || frame_height==0 || frame_width>4096 || frame_height>4096 ||
    frame_base[4:0]!=0 || frame_stride[4:0]!=0 || frame_stride<frame_width*(frame_rgb888 ? 3:1);
  end
  if(rst_n && state==CHECK_SUM)
   rounded_span_q<={32'd0,row_base}+{{14{row_span_q[49]}},row_span_q}+width_span_q+64'd31;
 end"""
    if text.count(before)!=1:raise ValueError('Full signed-product prerequisite missing')
    text=text.replace(before,after)
    validation="""     if(frame_width==0 || frame_height==0 || frame_width>4096 || frame_height>4096 ||
        frame_base[4:0]!=0 || frame_stride[4:0]!=0 ||
        frame_stride<frame_width*(frame_rgb888 ? 3:1) ||
        ((span_end+31)&64'hffffffffffffffe0)>64'h100000000)begin frame_failed<=1;state<=FINISH;end"""
    if text.count(validation)!=1:raise ValueError('Unexpected admission checks')
    text=text.replace(validation,'')
    before='aborting<=0;frame_failed<=0;accepted_pixels<=0;last_segment<=0;state<=START_PACK;'
    if text.count(before)!=1:raise ValueError('Unexpected admission transition')
    text=text.replace(before,before.replace('START_PACK','CHECK_SUM'))
    anchor='    START_PACK:begin'
    if text.count(anchor)!=1:raise ValueError('Unexpected packer state')
    return text.replace(anchor,"""    CHECK_SUM:begin
     if(aborting || frame_abort)state<=FINISH;
     else state<=CHECK_RANGE;
    end
    CHECK_RANGE:begin
     if(aborting || frame_abort || shape_bad_q ||
        (rounded_span_q&64'hffffffffffffffe0)>64'h100000000)begin
      frame_failed<=1;state<=FINISH;
     end else state<=START_PACK;
    end
"""+anchor)


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):raise ValueError('Frozen baseline required')
    names=json.loads((base/'sources.json').read_text())
    if len(names)!=290 or not all(hashlib.sha256((base/'source'/n).read_bytes()).hexdigest()==h for n,h in names.items()):
        raise ValueError('Baseline closure drift')
    run=fpga/'build/route_optimization'/datetime.now().strftime('writer_span_pipeline_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    target=run/'source/rtl/memory/frame_pixel_writer.sv'
    shutil.copyfile(target,run/'original_frame_pixel_writer.sv')
    shutil.copyfile(base/'original_frame_pixel_writer.sv',run/'before_root_frame_pixel_writer.sv')
    target.write_text(pipeline(target.read_text(encoding='utf-8')),encoding='utf-8',newline='\n')
    (run/'sources.json').write_text(json.dumps({n:hashlib.sha256((run/'source'/n).read_bytes()).hexdigest() for n in names},indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(status='SEMANTIC_AND_LATENCY_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/frame_pixel_writer.sv'],baseline=str(base),extra_frame_startup_cycles=2,
        per_segment_added_cycles=0,cycle_equivalent=False,full_span_bits=64,pixel_precision_unchanged=True),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print(run)


if __name__=='__main__':main()

`timescale 1ns/1ps
// Whole-entity source-boundary commit, version retention and validation tests.
module tb_motion_config;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,submit=0,boundary=0;
 reg [15:0] kind=4,read_kind=4;reg [1023:0] body=0;reg [31:0] version=1;wire [7:0] code;
 wire [255:0] current,capture;wire [127:0] capture_versions;wire [2303:0] status;
 wire [1023:0] pose_current,pose_capture;reg [1023:0] source_snapshot,valid_pose;
 wire [127:0] completion_current,completion_capture;
 reg [63:0] epoch=8,frame_id=19;
 motion_config_bank dut(.clk(clk),.rst_n(rst_n),.submit_valid(submit),.kind(kind),.entity(body),.version(version),.entity_id(32'd3),
  .submit_code(code),.capture_boundary(boundary),.epoch(epoch),.frame_id(frame_id),.capture_stabilization(capture),
  .capture_viewport(),.capture_completion(completion_capture),.capture_pose(pose_capture),.stabilization(current),.viewport(),.completion(completion_current),.pose(pose_current),
  .stabilization_version(),.viewport_version(),.completion_version(),.pose_version(),.capture_versions(capture_versions),.read_kind(read_kind),.status(status));
 // C4/C5 enabled and dynamic C6 requests cannot occupy the commit slot.
 initial begin
  #21;rst_n=1;body[0]=1;
  #1;if(code!=6 || status[127:120]!=6 || status[112])$fatal(1,"C4 not disabled");
  @(negedge clk);submit=1;@(negedge clk);submit=0;boundary=1;
  @(negedge clk);boundary=0;if(current!=0 || capture_versions[31:0]!=0)$fatal(1,"C4 applied");
  kind=6;body=0;body[0]=1;#1;if(code!=6)$fatal(1,"unregistered C5 accepted");
  kind=5;read_kind=5;body=0;body[7:0]=1;body[63:32]=65536;body[95:64]=131072;body[127:96]=100;body[191:160]=65536;
  #1;if(code!=11)$fatal(1,"minimum retained area violated");
  body[191:160]=16384;#1;if(code!=0)$fatal(1,"fixed viewport rejected");
  @(negedge clk);submit=1;@(negedge clk);submit=0;
  if(code!=4 || !status[113] || status[112] || capture_versions[63:32]!=1)$fatal(1,"queued atomicity");
  boundary=1;@(negedge clk);boundary=0;
  if(status[63:32]!=1 || status[128+:64]!=8 || status[192+:64]!=19 || status[113])$fatal(1,"source identity");
  if(code!=11)$fatal(1,"stale version accepted");
  version=2;body[7:0]=2;#1;if(code!=6)$fatal(1,"dynamic viewport accepted");
  body[7:0]=1;body[31:8]=1;#1;if(code!=11)$fatal(1,"reserved data accepted");
  // Kind8 is still atomically uploadable, independently of removed C4.
  kind=8;read_kind=8;version=1;body=0;#1;if(code!=0)$fatal(1,"pose calibration rejected");
  @(negedge clk);submit=1;@(negedge clk);submit=0;boundary=1;
  @(negedge clk);boundary=0;if(status[63:32]!=1 || !status[112] || capture_versions[127:96]!=1)$fatal(1,"pose commit broken");
  // Distinct pose generations and source identities must stay independent of
  // the viewport slot and of an already captured immutable source snapshot.
  version=2;body=0;body[0]=1;#1;if(code!=11)$fatal(1,"missing pose layout evidence accepted");
  body[63:32]=9;body[128+:32]=-90000;body[160+:32]=90000;
  body[192+:32]=-90000;body[224+:32]=90000;body[256+:32]=65536;
  body[288+:32]=1000;body[320+:32]=7;body[352+:32]=17;
  body[384+:192]=192'h0123456789abcdef;valid_pose=body;
  #1;if(code!=0)$fatal(1,"valid enabled pose rejected");
  body[128+:32]=90001;#1;if(code!=11)$fatal(1,"reversed pose domain accepted");
  body=valid_pose;body[288+:32]=0;#1;if(code!=11)$fatal(1,"zero time bound accepted");
  body=valid_pose;body[288+:32]=1001;#1;if(code!=11)$fatal(1,"excess time bound accepted");
  body=valid_pose;body[1000]=1;#1;if(code!=11)$fatal(1,"pose reserved tail accepted");
  body=valid_pose;body[1]=1;#1;if(code!=11)$fatal(1,"pose enable layout accepted");
  body=valid_pose;
  @(negedge clk);submit=1;@(negedge clk);submit=0;
  if(pose_current!=0 || pose_capture!=body || status[63:32]!=1)$fatal(1,"pose changed before capture");
  source_snapshot=pose_capture;frame_id=20;boundary=1;
  @(negedge clk);boundary=0;
  if(pose_current!=source_snapshot || status[192+:64]!=20)$fatal(1,"pose publication identity");
  version=3;body[384+:192]=192'hfedcba9876543210;
  @(negedge clk);submit=1;@(negedge clk);submit=0;
  if(pose_current!=source_snapshot || pose_capture==source_snapshot)$fatal(1,"queued pose damaged old source");
  frame_id=21;boundary=1;@(negedge clk);boundary=0;
  if(pose_current!=body || source_snapshot[384+:192]!=192'h0123456789abcdef)$fatal(1,"pose generation isolation");
  read_kind=5;#1;
  if(status[63:32]!=1 || status[128+:64]!=8 || status[192+:64]!=19)$fatal(1,"pose update aliased viewport identity");
  // Disabled C5 retains every legal diagnostic field while its enable byte
  // remains a literal zero before queueing, while pending and after commit.
  kind=6;read_kind=6;version=1;body=0;body[15:8]=2;
  body[47:32]=255;body[95:64]=7;#1;if(code!=0)$fatal(1,"disabled completion rejected");
  @(negedge clk);submit=1;@(negedge clk);submit=0;
  if(completion_current!=128'h100 || completion_capture!=body[127:0] || completion_capture[7:0]!=0)
   $fatal(1,"disabled completion queue semantics");
  body[0]=1;#1;if(code!=6 || completion_capture[7:0]!=0)$fatal(1,"enabled completion leaked into pending slot");
  body[0]=0;frame_id=22;boundary=1;@(negedge clk);boundary=0;
  if(completion_current!=body[127:0] || status[256+:128]!=body[127:0] || status[127:120]!=6 || status[192+:64]!=22)
   $fatal(1,"disabled completion publication/readback");
  $display("PASS C4/C5/dynamic unsupported + fixed/pose atomic source commit/version/busy/area/reserved + pose generation isolation");$finish;
 end
 initial begin #10000;$fatal(1,"timeout");end
endmodule

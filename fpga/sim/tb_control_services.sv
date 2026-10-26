`timescale 1ns/1ps
// Atomic parameter application and immutable source-frame pose association.
// Uses real firmware STATE bytes, exercises last-good parameters, full queue,
// age/error limits, validity loss, unmapped time and session revocation.
module tb_control_services;
 reg clk=0;always #4 clk=~clk;reg rst_n=0;
 reg submit_valid=0,entity_validated=0,capture_boundary=0,applied_ready=0;
 reg [511:0] entity=0;reg [31:0] version=0,entity_id=0;
 wire submit_ready,received,validated,rejected,applied,pending;
 wire [511:0] active_entity;wire [31:0] active_version,active_entity_id;
 wire [511:0] capture_entity;wire [31:0] capture_version,capture_entity_id;
 reg [31:0] frame_version=0;
 always @(posedge clk) if(capture_boundary) frame_version<=capture_version;
 wire [63:0] applied_epoch,applied_frame;
 reg clear=0,state_valid=0,mapping_valid=1,frame_valid=0,result_ready=0;
 reg [767:0] state_payload=0;reg [63:0] receive_us=1000100,exposure_us=1000000;
 reg [63:0] epoch=9,frame_id=10;reg signed [63:0] clock_offset_us=0;
 reg [31:0] clock_error_us=100;
 reg [63:0] sync_received_us=1000000;
 wire frame_ready,result_valid;wire [63:0] result_epoch,result_frame,result_receive_us;
 wire [767:0] result_state;wire [31:0] age_us,error_us,invalid_states,overwrites,degraded_frames;
 wire [2:0] status;reg [7:0] vector [0:105];integer i;
 frame_parameter_bank bank(.*);
 pose_frame_selector selector(.*);
 task submit(input bit valid,input [31:0] ver,input [511:0] data);
  begin
   @(negedge clk);submit_valid=1;entity_validated=valid;version=ver;entity_id=ver;entity=data;
   @(negedge clk);submit_valid=0;
  end
 endtask
 task push;
  begin @(negedge clk);state_valid=1;@(negedge clk);state_valid=0;end
 endtask
 task select_frame(input [2:0] expected);
  begin
   @(negedge clk);frame_valid=1;@(negedge clk);frame_valid=0;
   wait(result_valid);@(negedge clk);
   if(status!=expected || result_epoch!=epoch || result_frame!=frame_id) $fatal(1,"pose status %0d != %0d",status,expected);
   repeat(4) @(negedge clk);
   if(!result_valid || result_epoch!=epoch || result_frame!=frame_id) $fatal(1,"result not frozen");
   result_ready=1;@(negedge clk);result_ready=0;frame_id=frame_id+1;
  end
 endtask
 initial begin
  $readmemh("state.hex",vector);
  for(i=0;i<96;i=i+1) state_payload[i*8+:8]=vector[i+8];
  repeat(5) @(negedge clk);rst_n=1;
  submit(0,1,512'h55);if(!rejected || active_version!=0) $fatal(1,"invalid parameter accepted");
  submit(1,1,512'h1234);if(!validated || !pending || active_version!=0 || submit_ready) $fatal(1,"shadow commit");
  repeat(10) @(negedge clk);if(active_version!=0) $fatal(1,"mid-frame apply");
  capture_boundary=1;@(negedge clk);capture_boundary=0;
  if(!applied || active_version!=1 || frame_version!=1 || active_entity!=512'h1234 || applied_frame!=10 || applied_epoch!=9) $fatal(1,"apply identity");
  applied_ready=1;@(negedge clk);applied_ready=0;
  submit(1,1,512'h999);if(!rejected || active_entity!=512'h1234) $fatal(1,"stale version accepted");
  select_frame(1);push();select_frame(0);if(age_us!=1000 || error_us!=100) $fatal(1,"pose age");
  exposure_us=1030000;select_frame(3);exposure_us=1000000;
  mapping_valid=0;select_frame(2);mapping_valid=1;
  // Snapshot losing angle validity must prevent reuse of an older valid pose.
  state_payload[163+:2]=0;receive_us=1000200;push();exposure_us=1000300;select_frame(4);
  state_payload[163+:2]=3;
  state_payload[728+:2]=3;push();if(invalid_states!=1) $fatal(1,"source enum accepted");
  state_payload[728+:2]=2;
  for(i=0;i<35;i=i+1) begin state_payload[480+:64]=1000400+i;push();end
  if(overwrites!=5) $fatal(1,"bounded queue count %0d",overwrites);
  clear=1;@(negedge clk);clear=0;select_frame(1);
  $display("CONTROL_SERVICES_PASS invalid=%0d overwritten=%0d degraded=%0d",invalid_states,overwrites,degraded_frames);$finish;
 end
 initial begin #100000;$fatal(1,"control timeout");end
endmodule

`timescale 1ns/1ps
// Exercise real source-boundary selection, immutable queued jobs, retry
// idempotence and stale/invalid controls without substituting a PC transform.
module tb_affine_frame_control;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg submit_valid=0,other_pending=0,capture_boundary=0;
 reg [15:0] submit_sequence=0;reg [95:0] submit_payload=0;
 wire [7:0] submit_code;reg [31:0] geometry_version=7;
 reg [447:0] capture_geometry=0;reg [191:0] reference_coefficients=0;
 reg [63:0] capture_epoch=99,capture_frame=0;
 wire [447:0] capture_coefficients;wire capture_enable,pending,applied_enable,requested_enable;
 wire [31:0] capture_control_version,control_version,requested_version;
 wire [63:0] applied_epoch,applied_frame;wire [191:0] applied_coefficients;
 reg [447:0] queued_old,queued_on,queued_off;integer checks=0;
 affine_frame_control dut(.*);
 task check(input condition,input [511:0] message);
  begin if(condition!==1'b1)$fatal(1,"AFFINE_CONTROL_FAIL %0s",message);checks=checks+1;end
 endtask
 task tick;begin @(posedge clk);#1;@(negedge clk);end endtask
 task request(input [15:0] seq,input [95:0] payload,input [7:0] code);
  begin submit_sequence=seq;submit_payload=payload;#1;
   check(submit_code==code,"request validation");submit_valid=1;tick;submit_valid=0;
  end
 endtask
 task capture(input [63:0] id);
  begin capture_frame=id;capture_boundary=1;tick;capture_boundary=0;end
 endtask
 initial begin
  reference_coefficients={-32'sd1000000,32'd65536,32'd0,-32'sd2000000,32'd0,32'd65536};
  capture_geometry[191:0]={32'd30,32'd40,32'd50,32'd60,32'd70,32'd80};
  capture_geometry[447:192]=256'h123456789abcdef123456789abcdef123456789abcdef;
  repeat(3)tick;rst_n=1;tick;
  check(!applied_enable && !pending && control_version==0,"boot is OFF");
  queued_old=capture_coefficients;capture(1);
  check(queued_old[191:0]==reference_coefficients,"OFF uses normalized reference");
  check(queued_old[447:192]==capture_geometry[447:192],"OFF retains lens");
  request(10,{32'd7,32'd1,32'd1},0);
  check(pending && !applied_enable,"ACK is not applied");
  request(10,{32'd7,32'd1,32'd1},0);
  check(pending && requested_version==1,"queued retry is idempotent");
  request(10,{32'd7,32'd1,32'd0},11);
  request(11,{32'd7,32'd2,32'd0},4);
  queued_on=capture_coefficients;capture(2);
  check(applied_enable && !pending && control_version==1 && applied_frame==2,"ON boundary");
  check(queued_on==capture_geometry,"ON uses configured view");
  request(10,{32'd7,32'd1,32'd1},0);
  check(!pending,"applied retry does not requeue");
  request(11,{32'd6,32'd2,32'd0},11);
  request(11,{32'd7,32'd2,32'd2},11);
  request(11,{32'd7,32'd2,32'h00000100},11);
  request(11,{32'd7,32'h80000000,32'd0},11);
  other_pending=1;request(11,{32'd7,32'd2,32'd0},4);other_pending=0;
  request(11,{32'd7,32'd2,32'd0},0);
  queued_off=capture_coefficients;capture(3);
  check(!applied_enable && control_version==2 && applied_epoch==99,"OFF boundary");
  check(queued_off==queued_old,"OFF restores identical reference and lens");
  check(queued_on==capture_geometry,"queued ON frame unchanged by OFF");
  request(12,{32'd7,32'd3,32'd1},0);capture(4);
  check(capture_coefficients==queued_on,"reenable preserves manual ON matrix");
  rst_n=0;tick;rst_n=1;tick;
  check(!applied_enable && control_version==0 && !pending,"reset clears control state");
  $display("TB_AFFINE_FRAME_CONTROL_PASS checks=%0d",checks);$finish;
 end
 initial begin #100000;$fatal(1,"AFFINE_CONTROL_TIMEOUT");end
endmodule

`timescale 1ns/1ps
// Independent original-shape/range oracle. No pixels are supplied, so any
// request/data acceptance during preflight, abort or reset is a protocol bug.
module tb_writer_admission_pipeline #(parameter EXTRA_STARTUP=2);
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg frame_valid=0,frame_rgb888=0,frame_abort=0,in_valid=0;
 reg [31:0] frame_base=0,frame_stride=0,frame_generation=7;
 reg [15:0] frame_width=0,frame_height=0,in_x=0,in_y=0;
 reg [23:0] in_pixel=0;
 wire frame_ready,in_ready,frame_done,frame_failed,req_valid,req_write,w_valid,dma_cancel,done_ready;
 wire [31:0] accepted_pixels,req_addr,req_tag,w_strb;wire [4:0] req_beats;
 wire [255:0] w_data;
 reg req_ready=1,w_ready=1,done=0,dma_error=0,dma_cancelled=0;
 reg [31:0] done_tag=0;
 frame_pixel_writer dut(.*);
 integer checks=0,cases=0,seed=177;
 reg seen_done=0,seen_failed=0;
 always @(posedge clk)begin #1;
  if(rst_n)begin
   if(frame_done)begin seen_done=1;seen_failed=frame_failed;end
   if(req_valid || w_valid || accepted_pixels!=0)
    $fatal(1,"ADMISSION_PIPELINE accepted data without input pixels");
  end
 end
 task tick;begin @(posedge clk);#2;end endtask
 task check(input logic ok,input string label_text);
  begin checks++;if(ok!==1'b1)$fatal(1,"ADMISSION_PIPELINE_FAIL %s",label_text);end
 endtask
 task test_case(input [31:0] base_value,stride_value,input [15:0] width_value,height_value,
                input logic rgb_value,input integer abort_at,reset_at);
  reg [63:0] original_span;reg expected_bad;
  integer j,first_ready,first_done;
  begin
   @(negedge clk);rst_n=0;frame_valid=0;frame_abort=0;
   repeat(3)tick;@(negedge clk);rst_n=1;seen_done=0;seen_failed=0;
   tick;check(frame_ready,"reset returns admission ready");
   original_span={32'd0,base_value}+({48'd0,height_value}-1)*{32'd0,stride_value}+
    {48'd0,width_value}*(rgb_value?64'd3:64'd1);
   expected_bad=width_value==0 || height_value==0 || width_value>4096 || height_value>4096 ||
    base_value[4:0]!=0 || stride_value[4:0]!=0 || stride_value<width_value*(rgb_value?3:1) ||
    ((original_span+31)&64'hffffffffffffffe0)>64'h100000000;
   @(negedge clk);frame_base=base_value;frame_stride=stride_value;frame_width=width_value;
   frame_height=height_value;frame_rgb888=rgb_value;frame_generation=7;frame_valid=1;
   tick;first_ready=-1;first_done=-1;
   @(negedge clk);frame_valid=0;
   // Metadata must be frozen at acceptance, including the preflight operands.
   frame_base='x;frame_stride='x;frame_width='x;frame_height='x;frame_rgb888='x;frame_generation='x;
   for(j=1;j<=5;j=j+1)begin
    frame_abort=(j==abort_at);
    if(j==reset_at)rst_n=0;
    tick;
    if(in_ready && first_ready<0)first_ready=j;
    if(frame_done && first_done<0)first_done=j;
    @(negedge clk);
   end
   frame_abort=0;
   if(reset_at>0)begin
    rst_n=1;repeat(4)tick;
    check(frame_ready && !frame_done && !frame_failed && !req_valid && !w_valid,
          "cold reset invalidates unfinished admission");
   end else if(abort_at>0)begin
    check(seen_done && seen_failed,"abort drains before any pixel/request");
   end else if(expected_bad)begin
    check(seen_done && seen_failed && first_done==1+EXTRA_STARTUP,"bad frame exact preflight budget");
   end else begin
    check(!seen_done && !frame_failed && first_ready==1+EXTRA_STARTUP,"legal frame exact startup budget");
    check(dut.width===width_value && dut.height===height_value && dut.generation===32'd7 &&
          dut.row_base===base_value,"accepted metadata retained despite idle X poison");
    frame_abort=1;repeat(3)tick;
    check(seen_done && seen_failed,"idle pixel source can cancel a legal admission");frame_abort=0;
   end
   cases++;
  end
 endtask
 initial begin
  test_case(0,6144,1920,1080,1,-1,-1);
  test_case(0,32,0,1,0,-1,-1);test_case(0,32,1,0,0,-1,-1);
  test_case(0,16384,4097,1,0,-1,-1);test_case(0,32,1,4097,0,-1,-1);
  test_case(1,32,1,1,0,-1,-1);test_case(0,33,1,1,0,-1,-1);
  test_case(0,32,33,1,0,-1,-1);
  test_case(32'hffffffe0,32,32,1,0,-1,-1);
  test_case(32'hffffffe0,64,33,1,0,-1,-1);
  test_case(32'hffffffe0,32,10,1,1,-1,-1);
  test_case(32'hffffffe0,64,11,1,1,-1,-1);
  test_case(0,32'hffffffe0,1,2,0,-1,-1);
  test_case(0,32'hffffffe0,1,3,0,-1,-1);
  test_case(0,6144,35,9,1,1,-1);test_case(0,6144,35,9,1,2,-1);
  test_case(0,6144,35,9,1,-1,1);test_case(0,6144,35,9,1,-1,2);
  for(integer n=0;n<200;n++)
   test_case(32'($random(seed))&32'hffffffe0,32'($random(seed))&32'hffffffe0,
             16'($unsigned($random(seed))%4100),16'($unsigned($random(seed))%4100),1'($random(seed)),-1,-1);
  $display("WRITER_ADMISSION_PASS cases=%0d checks=%0d extra_cycles=%0d",cases,checks,EXTRA_STARTUP);$finish;
 end
 initial begin #1000000;$fatal(1,"Admission fixture timeout");end
endmodule

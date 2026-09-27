`timescale 1ns/1ps
// Purpose: byte-exact RAW8 packing and fail-closed geometry tests. This source
// is a simulation stimulus, never a synthesizable camera fallback.
module tb_raw8_capture;
 parameter W=64,H=4,EXTRA=0;
 reg clk=0,reset_n=0,cfg=1,arm=1,vs=1,href=0,ready=1,result_ready=0;
 reg [7:0] data=0;
 wire started,valid,result,good;
 wire [63:0] fid;wire [255:0] word_data;wire [16:0] offset;
 wire [31:0] rejected,overflows;
 integer x,y,k,words=0,expected_x=0,expected_y=0,seed=0,tests=0;
 // Purpose: regress strict-height and board-specific extra-row source frames.
 raw8_capture #(.WIDTH(W),.HEIGHT(H),.STRIDE(2048),.WARMUP_FRAMES(0),
  .SENSOR_EXTRA_ROWS(EXTRA)) dut(
  .clk(clk),.reset_n(reset_n),.configured(cfg),.arm(arm),.vsync(vs),.href(href),.data(data),
  .frame_start(started),.frame_id(fid),.word_valid(valid),.word_ready(ready),
  .word_data(word_data),.word_offset(offset),.result_valid(result),.result_ready(result_ready),
  .result_good(good),.rejected_frames(rejected),.overflow_frames(overflows));
 always #6 clk=~clk;
 // Purpose: compare every accepted word to the DVP stimulus using independent
 // row/column addressing. Padding locations must never receive writes.
 always @(posedge clk)if(valid && ready)begin
  if(offset%64>=W/32 || offset/64>=H)$fatal(1,"RAW8_FAIL padding/out-of-bounds write");
  for(k=0;k<32;k=k+1)
   if(word_data[k*8+:8]!==8'((offset/64)*7+(offset%64)*32+k+seed))
    $fatal(1,"RAW8_FAIL byte offset=%0d lane=%0d",offset,k);
  words=words+1;
 end
 task send(input integer fault_kind);
  integer count,total_rows;
  begin
   // Keep completion pending while the stimulus finishes its blanking delay.
   words=0;seed=seed+13;result_ready=0;
   // Purpose: first valid pixel coincides with VSYNC falling, a historically
   // fragile boundary in the RGB565 implementation.
   // Purpose: with optional sensor-tail tolerance, regress both legal physical
   // heights independently and still reject a seventh/otherwise excess row.
   total_rows=H+EXTRA+(fault_kind==3)-(fault_kind==5 ? EXTRA : 0);
   for(y=0;y<total_rows;y=y+1)begin
    count=W;
    if(y==1 && fault_kind==1)count=W-1;
    if(y==1 && fault_kind==2)count=W+1;
    for(x=0;x<count;x=x+1)begin
     @(negedge clk);vs=0;href=1;data=x+y*7+seed;
     if(fault_kind==4)ready=0;
    end
    @(negedge clk);href=0;
    if(y==total_rows-1 && fault_kind!=3)vs=1;
    repeat(4)@(negedge clk);
   end
   vs=1;href=0;ready=1;
   wait(result);
   if(good!==(fault_kind==0 || fault_kind==5))$fatal(1,"RAW8_FAIL geometry fault=%0d good=%0b",fault_kind,good);
   if((fault_kind==0 || fault_kind==5) && words!=W*H/32)$fatal(1,"RAW8_FAIL word count %0d",words);
   tests=tests+1;result_ready=1;repeat(8)@(negedge clk);
  end
 endtask
 initial begin
  repeat(5)@(negedge clk);reset_n=1;
  send(0);
  if(EXTRA>0)send(5);
  if(W==64)begin send(1);send(2);send(3);send(4);send(0);end
  $display("RAW8_CAPTURE_PASS width=%0d height=%0d tests=%0d overflow=%0d",W,H,tests,overflows);$finish;
 end
 initial begin #100000000;$fatal(1,"RAW8_TIMEOUT capture");end
endmodule

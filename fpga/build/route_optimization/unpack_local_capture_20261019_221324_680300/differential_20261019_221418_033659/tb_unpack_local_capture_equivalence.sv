`timescale 1ns/1ps
// Strict public-output equality includes invalid payload bits. Random traffic,
// simultaneous consume/refill, long output stalls and asynchronous restarts
// exercise the local-control copies without relaxing ready/valid timing.
module tb_unpack_local_capture_equivalence;
 parameter ALIGNED_ROWS=1;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,start_valid=0,beat_valid=0,chunk_ready=0;
 reg [4:0] start_offset=0;reg [31:0] row_bytes=0;reg [255:0] beat_data=0;
 wire a_start_ready,a_beat_ready,a_chunk_valid,a_chunk_last;
 wire b_start_ready,b_beat_ready,b_chunk_valid,b_chunk_last;
 wire [255:0] a_chunk_data,b_chunk_data;wire [5:0] a_valid_bytes,b_valid_bytes;
 dma_byte_unpack_reference #(.ALIGNED_ROWS(ALIGNED_ROWS)) reference_dut(
  .clk(clk),.rst_n(rst_n),.start_valid(start_valid),.start_ready(a_start_ready),
  .start_offset(start_offset),.row_bytes(row_bytes),.beat_valid(beat_valid),
  .beat_ready(a_beat_ready),.beat_data(beat_data),.chunk_valid(a_chunk_valid),
  .chunk_ready(chunk_ready),.chunk_data(a_chunk_data),.valid_bytes(a_valid_bytes),.chunk_last(a_chunk_last));
 dma_byte_unpack #(.ALIGNED_ROWS(ALIGNED_ROWS)) candidate_dut(
  .clk(clk),.rst_n(rst_n),.start_valid(start_valid),.start_ready(b_start_ready),
  .start_offset(start_offset),.row_bytes(row_bytes),.beat_valid(beat_valid),
  .beat_ready(b_beat_ready),.beat_data(beat_data),.chunk_valid(b_chunk_valid),
  .chunk_ready(chunk_ready),.chunk_data(b_chunk_data),.valid_bytes(b_valid_bytes),.chunk_last(b_chunk_last));
 integer cycle,lane,seed,random_word,starts=0,beats=0,chunks=0,stalls=0,simultaneous=0,partials=0,restarts=0;
 task check_equal;
 begin
  if({a_start_ready,a_beat_ready,a_chunk_valid,a_chunk_data,a_valid_bytes,a_chunk_last} !==
     {b_start_ready,b_beat_ready,b_chunk_valid,b_chunk_data,b_valid_bytes,b_chunk_last})
   $fatal(1,"unpack mismatch aligned=%0d cycle=%0d",ALIGNED_ROWS,cycle);
 end endtask
 initial begin
  if(!$value$plusargs("seed=%d",seed))seed=42;
  random_word=$urandom(seed);
  for(cycle=0;cycle<25000;cycle=cycle+1)begin
   @(negedge clk);
   rst_n=(cycle%997)>=2;
   start_valid=($urandom%4)==0;start_offset=$urandom;
   case($urandom%10)
    0:row_bytes=0;1:row_bytes=1;2:row_bytes=31;3:row_bytes=32;
    4:row_bytes=33;5:row_bytes=63;6:row_bytes=64;7:row_bytes=65;
    8:row_bytes=5760;default:row_bytes=$urandom%4098;
   endcase
   beat_valid=($urandom%4)!=0;
   chunk_ready=(cycle%257<48) ? 0 : (($urandom%4)!=0);
   for(lane=0;lane<8;lane=lane+1)beat_data[lane*32+:32]=$urandom;
   #1;check_equal();
   if(rst_n)begin
    if(start_valid && a_start_ready)starts=starts+1;
    if(beat_valid && a_beat_ready)beats=beats+1;
    if(a_chunk_valid && chunk_ready)begin
     chunks=chunks+1;if(a_valid_bytes<32)partials=partials+1;
    end
    if(a_chunk_valid && !chunk_ready)stalls=stalls+1;
    if(a_chunk_valid && chunk_ready && beat_valid && a_beat_ready)simultaneous=simultaneous+1;
   end else restarts=restarts+1;
   @(posedge clk);#1;check_equal();
  end
  if(starts<50 || beats<1000 || chunks<1000 || stalls<1000 || simultaneous<500 || partials<30 || restarts<40)
   $fatal(1,"insufficient unpack coverage %0d %0d %0d %0d %0d %0d %0d",starts,beats,chunks,stalls,simultaneous,partials,restarts);
  $display("UNPACK_LOCAL_CAPTURE_PASS aligned=%0d checks=50000 starts=%0d beats=%0d chunks=%0d stalls=%0d simultaneous=%0d partials=%0d reset_cycles=%0d",
   ALIGNED_ROWS,starts,beats,chunks,stalls,simultaneous,partials,restarts);
  $finish;
 end
endmodule

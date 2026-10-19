`timescale 1ns/1ps
// Purpose: exact original/candidate packer comparison, including invalid bus
// values, all offsets, RGB crossing, simultaneous drain/append and cold reset.
module tb_dma_pixel_pack_differential;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,start_valid=0,rgb888=0,pixel_valid=0,pixel_last=0,beat_ready=0;
 reg [4:0] start_offset=0;reg [23:0] pixel=0;
 wire start_ready,pixel_ready,beat_valid,beat_last;
 wire ref_start_ready,ref_pixel_ready,ref_beat_valid,ref_beat_last;
 wire [255:0] beat_data,ref_beat_data;wire [31:0] beat_strb,ref_beat_strb;
 dma_pixel_pack candidate(.*);
 baseline_pack reference_impl(.clk(clk),.rst_n(rst_n),.start_valid(start_valid),.start_ready(ref_start_ready),
  .start_offset(start_offset),.rgb888(rgb888),.pixel_valid(pixel_valid),.pixel_ready(ref_pixel_ready),.pixel(pixel),.pixel_last(pixel_last),
  .beat_valid(ref_beat_valid),.beat_ready(beat_ready),.beat_data(ref_beat_data),.beat_strb(ref_beat_strb),.beat_last(ref_beat_last));
 integer seed=42,random_value,mode,offset,length_index,trial;
 integer compared=0,finished=0,simultaneous=0,resets=0;
 reg accepted_pixel,accepted_last;
 // All outputs are compared after NBA updates. Independent state/storage
 // prevents the reference from borrowing any candidate cursor or masks.
 always @(posedge clk)begin
  accepted_pixel=pixel_valid && pixel_ready;
  accepted_last=beat_valid && beat_ready && beat_last;
  if(beat_valid && beat_ready && pixel_valid && pixel_ready)simultaneous=simultaneous+1;
  #1;compared=compared+1;
  if({start_ready,pixel_ready,beat_valid,beat_data,beat_strb,beat_last} !==
     {ref_start_ready,ref_pixel_ready,ref_beat_valid,ref_beat_data,ref_beat_strb,ref_beat_last})
   $fatal(1,"PIXEL_PACK differential cycle=%0d mode=%0d offset=%0d",compared,rgb888,start_offset);
 end
 task cold_reset;
  begin
   @(negedge clk);rst_n=0;start_valid=0;pixel_valid=0;pixel_last=0;beat_ready=0;
   repeat(3)@(negedge clk);rst_n=1;resets=resets+1;
  end
 endtask
 task packet(input integer bytes_mode,input integer begin_offset,input integer length,input integer reset_after);
  integer sent,cycles;reg complete;
  begin
   @(negedge clk);while(!start_ready)@(negedge clk);
   rgb888=bytes_mode;start_offset=begin_offset;start_valid=1;
   @(negedge clk);start_valid=0;sent=0;cycles=0;complete=0;
   while(!complete && cycles<20000)begin
    // Hold a presented pixel unchanged until acceptance. Every beat stall
    // leaves the original/candidate ready/valid behavior under comparison.
    random_value=$random(seed);beat_ready=(random_value&7)!=0;
    if(!pixel_valid && sent<length)begin
     random_value=$random(seed);pixel_valid=(random_value&3)!=0;
     if(pixel_valid)begin pixel=$random(seed);pixel_last=sent==length-1;end
    end
    @(posedge clk);#2;
    if(accepted_pixel)sent=sent+1;
    if(accepted_last)begin complete=1;finished=finished+1;end
    @(negedge clk);if(accepted_pixel)begin pixel_valid=0;pixel_last=0;end
    cycles=cycles+1;
    if(reset_after>0 && sent>=reset_after && !complete)begin cold_reset();complete=1;end
   end
   if(!complete)$fatal(1,"PIXEL_PACK packet stalled");
   pixel_valid=0;pixel_last=0;beat_ready=0;
  end
 endtask
 initial begin
  random_value=$value$plusargs("SEED=%d",seed);cold_reset();
  // Every alignment and both formats cross short tails, exact beat lengths,
  // and multiple boundaries. Longer randomized packets stress cursor reuse.
  for(mode=0;mode<2;mode=mode+1)for(offset=0;offset<32;offset=offset+1)begin
   for(length_index=1;length_index<=35;length_index=length_index+1)packet(mode,offset,length_index,0);
   packet(mode,offset,129,0);packet(mode,offset,96,13);
  end
  for(trial=0;trial<100;trial=trial+1)begin
   random_value=$random(seed);packet(trial%2,trial%32,64+(random_value&255),0);
  end
  repeat(4)@(negedge clk);
  if(finished!=2404 || simultaneous==0 || resets!=65)$fatal(1,"PIXEL_PACK coverage incomplete finished=%0d resets=%0d",finished,resets);
  $display("PIXEL_PACK_DIFFERENTIAL_PASS cycles=%0d packets=%0d simultaneous=%0d resets=%0d",compared,finished,simultaneous,resets);$finish;
 end
 initial begin #20000000;$fatal(1,"PIXEL_PACK timeout");end
endmodule

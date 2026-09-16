`timescale 1ns/1ps
// Purpose: full 720p raster + one-cycle FIFO-read model + TMDS encode/decode test.
// Checks every active pixel and blanking control symbol for two complete frames.
// This model does not substitute for native DDR payload/PHY or hardware testing.
module tb_mini_video;
 reg clk=0,rstn=0;always #6.734 clk=~clk;
 wire ih,iv,id,oh,ov,od,req,ren;wire [15:0] out_data;
 reg ack=0;reg [15:0] read_data=0;integer read_counter=0;
 wire [9:0] encoded;
 reg [7:0] history0=0,history1=0,history2=0;
 reg [2:0] dh=0;reg [1:0] ctrl0=0,ctrl1=0,ctrl2=0;
 reg prev_vs=0,prev_de=0,prev_req=0;
 integer pixels=0,lines=0,line_pixels=0,frames=0,checks=0;
 reg started=0;integer guard=0;
 sync_vg gen(.clk(clk),.rstn(rstn),.hs_out(ih),.vs_out(iv),.de_out(id));
 video_rect_read_data rect(.video_clk(clk),.rst(!rstn),.video_left_offset(12'd0),
 .video_top_offset(12'd0),.video_width(12'd1280),.video_height(12'd720),
 .read_req(req),.read_req_ack(ack),.read_en(ren),.read_data(read_data),
 .timing_hs(ih),.timing_vs(iv),.timing_de(id),.timing_data(16'd0),
 .hs(oh),.vs(ov),.de(od),.vout_data(out_data));
 tmds_encoder enc(.pix_clk(clk),.rstn(rstn),.din(out_data[7:0]),
 .c0(oh),.c1(ov),.de(od),.dout(encoded));
 // Purpose: native FIFO contract supplies the requested word one clock later.
 always @(posedge clk) begin
  ack<=req;prev_req<=req;
  if(!rstn || (req&&!prev_req))read_counter<=0;
  else if(ren)begin read_data<=read_counter[15:0];read_counter<=read_counter+1;end
  history0<=out_data[7:0];history1<=history0;history2<=history1;
  dh<={dh[1:0],od};ctrl0<={ov,oh};ctrl1<=ctrl0;ctrl2<=ctrl1;
 end
 function [7:0] decode(input [9:0] word);
 reg [7:0] q;integer k;
 begin q=word[7:0]^{8{word[9]}};decode[0]=q[0];
  for(k=1;k<8;k=k+1)decode[k]=word[8]?(q[k]^q[k-1]):~(q[k]^q[k-1]);
 end endfunction
 function [9:0] control(input [1:0] c);
 begin case(c)0:control=10'b1101010100;1:control=10'b0010101011;
  2:control=10'b0101010100;3:control=10'b1010101011;endcase end endfunction
 task check(input reg ok,input [255:0] label_text);
 begin checks=checks+1;if(ok!==1'b1)begin
 $display("VIDEO_FAIL %s pixels=%0d lines=%0d data=%h",label_text,pixels,lines,out_data);$fatal(1);end end endtask
 always @(posedge clk) begin
  #2;
  if(rstn)begin
   guard=guard+1;
   if(guard>10)begin
    if(dh[2])check(decode(encoded)===history2,"TMDS pixel roundtrip");
    else check(encoded===control(ctrl2),"TMDS blanking token");
   end
   if(ov&&!prev_vs)begin
    if(started)begin
     check(pixels==1280*720,"active pixels per frame");
     check(lines==720,"active lines per frame");frames=frames+1;
     if(frames==2)begin $display("VIDEO_PASS frames=2 pixels=1843200 checks=%0d",checks);$finish;end
    end
    started=1;pixels=0;lines=0;line_pixels=0;
   end
   if(started&&od)begin
    check(out_data===pixels[15:0],"FIFO/display pixel alignment");
    pixels=pixels+1;line_pixels=line_pixels+1;
   end
   if(started&&prev_de&&!od)begin check(line_pixels==1280,"pixels per line");line_pixels=0;lines=lines+1;end
   prev_vs=ov;prev_de=od;
  end
 end
 initial begin repeat(8)@(negedge clk);rstn=1;end
 initial begin #60000000;$display("VIDEO_TIMEOUT");$fatal(1);end
endmodule

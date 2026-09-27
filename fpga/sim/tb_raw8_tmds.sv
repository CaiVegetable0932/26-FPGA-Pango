`timescale 1ns/1ps
// Purpose: decode production TMDS symbols for two complete 1080p RAW-gray
// rasters. This checks pixel/control alignment and dimensions, not the HDMI
// connector, PLL jitter, serializer eye, or UVC device JPEG decoder.
module hdmi_tx_oserdes(input pixel_clk,serial_clk,reset_n,input [9:0] symbol,
 output data_p,data_n);
 assign data_p=symbol[0],data_n=~symbol[0];
endmodule
module tb_raw8_tmds;
 reg clk=0,rst=0;always #6.734 clk=~clk;
 wire hs,vs,de,boundary,ready;wire [23:0] rgb;wire [31:0] underflows;
 reg [7:0] sample=0;
 raw8_hdmi_timing raster(.clk(clk),.reset_n(rst),.enable(1'b1),.sample(sample),
  .sample_valid(1'b1),.sample_ready(ready),.hsync(hs),.vsync(vs),.de(de),
  .frame_boundary(boundary),.rgb(rgb),.underflows(underflows));
 hdmi_tx_rgb tx(.pixel_clk(clk),.serial_clk(clk),.reset_n(rst),.rgb(rgb),
  .data_enable(de),.hsync(hs),.vsync(vs));
 // Independent inverse transition coding, not a second copy of the encoder.
 function automatic [7:0] decode(input [9:0] s);
  reg [7:0] q;integer k;
  begin q=s[9]?~s[7:0]:s[7:0];decode[0]=q[0];
   for(k=1;k<8;k=k+1)decode[k]=s[8]?q[k]^q[k-1]:~(q[k]^q[k-1]);end
 endfunction
 function automatic [9:0] control(input [1:0] b);
  case(b)0:control=10'b1101010100;1:control=10'b0010101011;
   2:control=10'b0101010100;3:control=10'b1010101011;endcase
 endfunction
 reg [26:0] p0=0,p1=0,expected=0;
 integer x=0,y=0,frames=0,pixels=0,checks=0,age=0;
 always @(negedge clk)if(rst && ready)sample<=sample+8'd17;
 always @(posedge clk)if(rst)begin
  // Check raster geometry independently of the DUT's internal counters.
  if(hs!==(x<44)||vs!==(y<5)||de!== (x>=192&&x<2112&&y>=41&&y<1121))
   $fatal(1,"RAW8_TMDS_FAIL raster x=%0d y=%0d",x,y);
  if(de)begin pixels=pixels+1;if(rgb!=={3{sample}})$fatal(1,"RAW8_TMDS_FAIL gray");end
  expected=p1;p1=p0;p0={de,vs,hs,rgb};age=age+1;
  if(x==2199)begin x=0;if(y==1124)begin
   if(pixels!=2073600)$fatal(1,"RAW8_TMDS_FAIL frame size");
   y=0;pixels=0;frames=frames+1;
  end else y=y+1;end else x=x+1;
  #2;
  if(age>2)begin
   if(expected[26])begin
    if({decode(tx.encoded[2]),decode(tx.encoded[1]),decode(tx.encoded[0])}!==expected[23:0])
     $fatal(1,"RAW8_TMDS_FAIL decoded RGB/pipeline");
   end else if(tx.encoded[0]!==control(expected[25:24])||
    tx.encoded[1]!==control(0)||tx.encoded[2]!==control(0))
     $fatal(1,"RAW8_TMDS_FAIL blanking");
   checks=checks+1;
  end
  if(frames==2)begin
   if(underflows!=0)$fatal(1,"RAW8_TMDS_FAIL underflow");
   $display("RAW8_TMDS_PASS frames=%0d checks=%0d pixels_per_frame=2073600",frames,checks);$finish;
  end
 end
 initial begin repeat(8)@(negedge clk);rst=1;end
 initial begin #70000000;$fatal(1,"RAW8_TMDS_TIMEOUT");end
endmodule

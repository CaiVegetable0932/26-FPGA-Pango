`timescale 1ns/1ps
// Purpose: exhaustive raster comparison against the pre-optimization integer
// shape/glyph equations. Cover all twenty IDs, both digit counts, corners,
// fractional rounding and sizes 4/9/10/32 without changing two-cycle latency.
module tb_geometry_marker_overlay;
 reg clk=0,rst_n=0;always #7 clk=~clk;
 reg [1279:0] coords=0;reg [19:0] mask=0;reg enabled=0;
 reg [5:0] size=10;reg [23:0] in_rgb=0;reg ih=0,iv=0,id=0;
 wire [23:0] rgb;wire hs,vs,de;
 geometry_marker_overlay #(.WIDTH(64),.HEIGHT(48)) dut(clk,rst_n,coords,mask,enabled,size,in_rgb,ih,iv,id,rgb,hs,vs,de);
 reg [31:0] colors[0:119];reg [23:0] expected_now=0,expected_delayed=0;
 reg [2:0] strobes_delayed=0;integer checked=0,marker,sz,place,xx,yy,j,cx,cy;
 function [14:0] glyph(input integer digit);
  begin case(digit)
   0:glyph=15'b111101101101111;1:glyph=15'b010110010010111;
   2:glyph=15'b111001111100111;3:glyph=15'b111001111001111;
   4:glyph=15'b101101111001001;5:glyph=15'b111100111001111;
   6:glyph=15'b111100111101111;7:glyph=15'b111001001001001;
   8:glyph=15'b111101111101111;default:glyph=15'b111101111001111;
  endcase end
 endfunction
 // Deliberately retain integer indexing and the original arithmetic here;
 // production uses bounded bit selectors, so this is an independent oracle.
 function [23:0] reference_pixel(input integer x,y,input [23:0] source);
  integer g,mx,my,ax,ay,r,lx,ly,tx,ty,digits;reg body,inner_pixel,box,digit;
  reg [14:0] tens,ones;reg signed [31:0] xq,yq;
  begin reference_pixel=source;
   for(g=19;g>=0;g=g-1)if(enabled && mask[g])begin
    xq=$signed(coords[g*64+:32])+2048;yq=$signed(coords[g*64+32+:32])+2048;
    mx=xq>>>12;my=yq>>>12;ax=x-mx;if(ax<0)ax=-ax;ay=y-my;if(ay<0)ay=-ay;r=size/2;
    body=ax<=r && ay<=r && ax+ay<=r+r/2;
    inner_pixel=ax+1<r && ay+1<r && ax+ay+2<r+r/2;
    digits=g+1>=10?2:1;lx=mx>32?mx-r-(digits*4+2):mx+r+3;ly=my<10?my+7:my-8;
    tx=x-lx;ty=y-ly;box=tx>=-1 && tx<=digits*4-1 && ty>=-1 && ty<=5;
    tens=glyph((g+1)/10);ones=glyph((g+1)%10);digit=0;
    if(ty>=0 && ty<5 && tx>=0)begin
     if(digits==1 && tx<3)digit=ones[14-(ty*3+tx)];
     if(digits==2 && tx<3)digit=tens[14-(ty*3+tx)];
     if(digits==2 && tx>=4 && tx<7)digit=ones[14-(ty*3+tx-4)];
    end
    if(body || box)reference_pixel=(body && inner_pixel)||(box && digit)?colors[g*6+2]:24'b0;
   end
  end
 endfunction
 always @(posedge clk)begin
  if(rst_n)begin
   #1;if({hs,vs,de}!==strobes_delayed || rgb!==expected_delayed)
    $fatal(1,"OVERLAY_FAIL marker=%0d size=%0d place=%0d x=%0d y=%0d got=%h expected=%h",marker,size,place,xx,yy,rgb,expected_delayed);
   checked=checked+1;strobes_delayed={ih,iv,id};expected_delayed=expected_now;
  end else begin strobes_delayed=0;expected_delayed=0;end
 end
 task raster;
  begin
   @(negedge clk);iv=1;id=0;in_rgb=24'h18395a;expected_now=in_rgb;
   repeat(3)@(negedge clk);iv=0;
   for(yy=0;yy<48;yy=yy+1)begin
    for(xx=0;xx<64;xx=xx+1)begin
     id=1;in_rgb=(xx*2137+yy*179+24'h18395a)&24'hffffff;expected_now=reference_pixel(xx,yy,in_rgb);
     @(negedge clk);
    end
    id=0;ih=1;expected_now=in_rgb;repeat(2)@(negedge clk);ih=0;
   end
   repeat(3)@(negedge clk);
  end
 endtask
 initial begin
  $readmemh("marker_golden.hex",colors);repeat(4)@(negedge clk);rst_n=1;
  for(marker=0;marker<20;marker=marker+1)for(sz=0;sz<4;sz=sz+1)for(place=0;place<3;place=place+1)begin
   case(sz)0:size=4;1:size=9;2:size=10;3:size=32;endcase
   case(place)0:begin cx=32;cy=24;end 1:begin cx=0;cy=0;end 2:begin cx=63;cy=47;end endcase
   coords=0;coords[marker*64+:32]=cx*4096+(sz==1?2048:2047);
   coords[marker*64+32+:32]=cy*4096+(sz==1?2048:2047);mask=20'b1<<marker;enabled=1;raster();
  end
  // Simultaneous overlaps check the unchanged lower-ID priority encoder.
  for(j=0;j<20;j=j+1)begin coords[j*64+:32]=(27+j%6)*4096;coords[j*64+32+:32]=(18+j%7)*4096;end
  mask=20'hfffff;size=10;raster();enabled=0;raster();
  $display("GEOMETRY_MARKER_OVERLAY_PASS frames=242 checked_clocks=%0d",checked);$finish;
 end
 initial begin #20000000;$fatal(1,"OVERLAY_TIMEOUT");end
endmodule

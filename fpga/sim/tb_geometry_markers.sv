`timescale 1ns/1ps
// Purpose: canonical JS catalog, true FPGA numeric mapping, visibility, bypass
// and explicit unsupported-model failures. Analytic comparisons allow 0.5 pixel
// for the existing radial LUT interpolation; original coordinates must be exact.
module tb_geometry_markers;
 reg clk=0,rst_n=0,start=0,original=0;always #4 clk=~clk;
 reg [1:0] model=0;reg [447:0] words=0;wire ready;wire [1279:0] coordinates;
 wire [19:0] mask;wire [31:0] status;
 reg [4:0] index=31;wire [15:0] sx,sy;wire [23:0] color;
 reg [31:0] golden[0:119],config_words[0:13];integer i,rounds;reg signed [31:0] dx,dy,ex,ey;
 geometry_marker_table dut(clk,rst_n,start,original,model,words,ready,coordinates,mask,status);
 geometry_marker_catalog cat(index,sx,sy,color);
 task check(input bit ok,input string label_text);begin if(!ok)$fatal(1,"MARKER_FAIL %s",label_text);end endtask
 task run_table;begin
  @(negedge clk);start=1;@(negedge clk);start=0;
  wait(!ready);wait(ready);@(negedge clk);
 end endtask
 initial begin
  $readmemh("marker_golden.hex",golden);$readmemh("marker_words.hex",config_words);
  repeat(4)@(negedge clk);rst_n=1;
  for(i=0;i<20;i=i+1)begin index=i;#1;
   check(sx==golden[i*6] && sy==golden[i*6+1] && color==golden[i*6+2],$sformatf("catalog %0d got=%0d,%0d,%h expected=%0d,%0d,%h",i+1,sx,sy,color,golden[i*6],golden[i*6+1],golden[i*6+2]));end
  run_table();check(mask==20'hfffff && status==1,"bypass visible status");
  for(i=0;i<20;i=i+1)begin
   check(coordinates[i*64+:32]==golden[i*6]*4096 && coordinates[i*64+32+:32]==golden[i*6+1]*4096,"exact bypass coordinates");end
  for(i=0;i<14;i=i+1)words[i*32+:32]=config_words[i];
  model=2;run_table();
  for(i=0;i<20;i=i+1)begin
   dx=coordinates[i*64+:32];dy=coordinates[i*64+32+:32];ex=golden[i*6+3];ey=golden[i*6+4];
   $display("MARKER_NUMERIC id=%0d dx=%0d dy=%0d visible=%0d expected=%0d,%0d,%0d",i+1,dx,dy,mask[i],ex,ey,golden[i*6+5]);
   check(mask[i]==golden[i*6+5],$sformatf("fisheye visibility %0d",i+1));
   if(mask[i])check(dx-ex<2048 && dx-ex> -2048 && dy-ey<2048 && dy-ey> -2048,$sformatf("analytic numeric %0d",i+1));
  end
  original=1;run_table();check(mask==20'hfffff && status==1,"original bypasses same active fisheye");
  for(i=0;i<20;i=i+1)check(coordinates[i*64+:32]==golden[i*6]*4096 && coordinates[i*64+32+:32]==golden[i*6+1]*4096,"original exact");
  original=0;model=1;words=0;words[31:0]=65536;words[159:128]=65536;
  words[351:320]=67108864;words[383:352]=67108864;
  run_table();check(status==1,"radial Brown succeeds");
  for(i=0;i<20;i=i+1)begin
   dx=coordinates[i*64+:32];dy=coordinates[i*64+32+:32];ex=golden[i*6]*4096;ey=golden[i*6+1]*4096;
   check(dx-ex<=2 && dx-ex>=-2 && dy-ey<=2 && dy-ey>=-2,"Brown identity precision");end
  // A negative determinant exercises signed inverse-affine division without
  // relying on the same arithmetic implementation for expected coordinates.
  words[31:0]=-65536;words[95:64]=1919*65536;run_table();
  check(status==1,"reflected affine succeeds");
  for(i=0;i<20;i=i+1)begin
   dx=coordinates[i*64+:32];dy=coordinates[i*64+32+:32];ex=(1919-golden[i*6])*4096;ey=golden[i*6+1]*4096;
   check(dx-ex<=2 && dx-ex>=-2 && dy-ey<=2 && dy-ey>=-2,"signed affine reflection precision");end
  words[31:0]=0;run_table();check(status==3 && mask==0,"singular affine is failed metadata");
  words[287:256]=1;run_table();check(status==9 && mask==0,"unsupported tangential Brown fails explicitly");
  for(i=0;i<20;i=i+1)check(coordinates[i*64+:64]==64'h8000000080000000,"invalid sentinel");
  $display("GEOMETRY_MARKERS_PASS");$finish;
 end
 initial begin #100000000;$fatal(1,"MARKER_TIMEOUT");end
endmodule

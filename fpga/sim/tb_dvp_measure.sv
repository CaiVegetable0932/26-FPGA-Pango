`timescale 1ns/1ps
// Purpose: distinguish post-config short/long rows, wrong height and valid frames;
// ensure first-fault capture is immutable and long rows are measured to their end.
module tb_dvp_measure;
 reg clk=0,rst=0,cfg=0,v=1,h=0;
 always #5 clk=~clk;
 wire [159:0] packet;
 mini_dvp_measure #(.WIDTH_BYTES(8),.HEIGHT(2)) dut(clk,rst,cfg,v,h,8'ha7,packet);
 task tick(input bit nv,input bit nh);
 begin @(negedge clk);v=nv;h=nh;@(posedge clk);#1;end endtask
 task frame(input integer first_len,input integer nrows,input bit vs_closes);
 begin repeat(3)tick(1,0);tick(0,0);
 repeat(first_len)tick(0,1);
 if(nrows>1)begin repeat(3)tick(0,0);repeat(8)tick(0,1);end
 if(vs_closes)tick(1,1);else tick(0,0);
 repeat(4)tick(1,0);end endtask
 task check(input bit c,input string why);
 begin if(!c)$fatal(1,"MEASURE_FAIL %s packet=%h",why,packet);end endtask
 initial begin
 repeat(4)tick(1,0);rst=1;frame(8,2,0);
 check(packet[79:48]==0,"ignore pre-config frames");
 cfg=1;frame(8,2,1);
 check(packet[95:80]==2 && packet[79:64]==1 && packet[63:48]==1,"good full frame");
 frame(6,2,0);
 check(packet[127:112]==6 && packet[111:96]==0 && packet[15:0]==16'h0101,"first short row");
 frame(12,2,1);
 check(packet[127:112]==6 && packet[31:16]==2,"first fault immutable");
 cfg=0;repeat(4)tick(1,0);cfg=1;frame(12,2,0);
 check(packet[127:112]==12 && packet[15:0]==16'h0201,"full long-row length");
 cfg=0;repeat(4)tick(1,0);cfg=1;frame(8,1,1);
 check(packet[111:96]==1 && packet[15:0]==16'h0301,"wrong height reason");
 $display("DVP_MEASURE_PASS");$finish;
 end
 initial begin #100000;$fatal(1,"MEASURE_TIMEOUT");end
endmodule

// Purpose: unequal-clock handshake stress; every published word must belong to
// one source generation, even during source/destination independent reset.
module tb_diag_snapshot;
 reg a=0,b=0,ar=0,br=0;reg [31:0] counter=0;wire [159:0] snapshot;
 always #7 a=~a;always #5 b=~b;
 always @(posedge a)if(ar)counter<=counter+1;
 mini_diag_snapshot dut(a,ar,b,br,{5{counter}},snapshot);
 integer checks=0;
 always @(negedge b)if(br)begin
  if(snapshot!={5{snapshot[31:0]}})$fatal(1,"SNAPSHOT_FAIL torn bus");
  checks=checks+1;
 end
 initial begin
 #100;ar=1;br=1;#5000;br=0;#60;br=1;#5000;ar=0;#70;ar=1;#5000;
 if(snapshot==0 || checks<1000)$fatal(1,"SNAPSHOT_FAIL no progress");
 $display("DIAG_SNAPSHOT_PASS checks=%0d",checks);$finish;
 end
endmodule

// Purpose: generate the REAL diagnostic raster to an RGB file for the PC decoder
// test; this validates bit order, coordinates and frame-latched packet semantics.
module tb_diag_raster;
 reg clk=0,rst=0,v=0,de=0;wire [23:0] rgb;
 always #5 clk=~clk;
 reg [159:0] packet=160'hd64101a70006000302d0000a000b0a0000010101;
 integer x,y,fd;
 mini_diag_raster dut(clk,rst,v,de,packet,rgb);
 initial begin
  fd=$fopen("diagnostic_fixture.rgb","wb");
  if(!fd)$fatal(1,"RASTER_FAIL output open");
  repeat(5)@(negedge clk);rst=1;v=1;repeat(5)@(negedge clk);v=0;
  for(y=0;y<720;y=y+1)begin
   for(x=0;x<1280;x=x+1)begin
    de=1;#1;$fwrite(fd,"%c%c%c",rgb[23:16],rgb[15:8],rgb[7:0]);
    @(negedge clk);
   end
   de=0;repeat(3)@(negedge clk);
  end
  $fclose(fd);$display("DIAG_RASTER_PASS");$finish;
 end
 initial begin #20000000;$fatal(1,"RASTER_TIMEOUT");end
endmodule

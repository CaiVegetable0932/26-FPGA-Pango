`timescale 1ns/1ps
// Purpose: verify Bayer-phase cancellation, edge replication, and line-buffer
// read-ahead without changing the source RAW8 bytes or HDMI pixel count.
module tb_raw8_hdmi_gray_antialias;
 reg clk=0,reset_n=0,line_preload=0,pixel_accept=0,first_row=0,first_col=0;
 reg [10:0] column=0;
 reg [7:0] luma=0;
 wire [7:0] gray;
 reg [7:0] source [0:2][0:7];
 integer frame,row,col,expected,left,top,top_left;
 always #5 clk=~clk;
 raw8_hdmi_gray_antialias dut(.clk(clk),.reset_n(reset_n),
  .line_preload(line_preload),.pixel_accept(pixel_accept),
  .first_row(first_row),.first_col(first_col),
  .column(column),.luma(luma),.gray(gray));
 // Purpose: vary both Bayer phases and frame contents; a stale line RAM must
 // not influence the first row of a new frame.
 initial begin
  repeat(2)@(negedge clk);reset_n=1;
  for(frame=0;frame<2;frame=frame+1)begin
   for(row=0;row<3;row=row+1)begin
    @(negedge clk);line_preload=1;pixel_accept=0;
    @(posedge clk);#1;
    for(col=0;col<8;col=col+1)begin
     @(negedge clk);
     line_preload=0;pixel_accept=1;
     first_row=(row==0);first_col=(col==0);column=col;
     luma=(frame==0 ? 0 : 20)+(row[0] ? (col[0] ? 10 : 60) : (col[0] ? 40 : 200));
     source[row][col]=luma;
     left=col==0 ? luma : source[row][col-1];
     top=row==0 ? luma : source[row-1][col];
     top_left=row==0 ? left : col==0 ? top : source[row-1][col-1];
     expected=(luma+left+top+top_left+2)>>2;
     #1;if(gray!==expected[7:0])
      $fatal(1,"HDMI_BAYER_FILTER_FAIL frame=%0d row=%0d col=%0d got=%0d want=%0d",
       frame,row,col,gray,expected);
     @(posedge clk);#1;
    end
    @(negedge clk);pixel_accept=0;
   end
  end
  $display("RAW8_HDMI_GRAY_ANTIALIAS_PASS");$finish;
 end
endmodule

`timescale 1ns/1ps
// Independent full-width operator golden model: extrema/random products,
// exact pipeline latency and CE stalls, without copying partial decomposition.
module tb_wide_multipliers;
 reg clk=0,advance=1;always #4 clk=~clk;
 reg [31:0] a=0,b=0;reg signed [39:0] wa=0;reg [39:0] wb=0;
 wire [63:0] product;wire signed [79:0] wide_product;
 unsigned_mult32_pipe u32(clk,advance,a,b,product);
 signed_mult40_unsigned40_pipe w40(clk,advance,wa,wb,wide_product);
 reg [63:0] expected[0:2],held;reg signed [79:0] wide_expected[0:3],wide_held;
 reg signed [80:0] full_product;
 integer cycles=0,samples=0,j;reg [31:0] seed=32'h1289abcd;
 always @(negedge clk)begin
  advance=cycles%7!=3 && cycles%7!=4;
  a=$random(seed);b=$random(seed);wa={$random(seed),$random(seed)};wb={$random(seed),$random(seed)};
  case(cycles)
   0:begin a=0;b=32'hffffffff;wa=40'h8000000000;wb=40'hffffffffff;end
   1:begin a=32'hffffffff;b=32'hffffffff;wa=40'h7fffffffff;wb=40'hffffffffff;end
   2:begin a=32'h80000000;b=32'h80000000;wa=-40'sd1;wb=40'h8000000000;end
   5:begin a=32'h00010001;b=32'hffff0001;wa=40'h8000000001;wb=1;end
  endcase
 end
 always @(posedge clk)begin
  cycles=cycles+1;
  if(advance)begin
   for(j=2;j>0;j=j-1)expected[j]=expected[j-1];expected[0]={32'd0,a}*{32'd0,b};
   for(j=3;j>0;j=j-1)wide_expected[j]=wide_expected[j-1];
   full_product=$signed(wa)*$signed({1'b0,wb});wide_expected[0]=full_product[79:0];samples=samples+1;
   #1;
   if(samples>=3 && product!==expected[2])$fatal(1,"Unsigned product mismatch");
   if(samples>=4 && wide_product!==wide_expected[3])$fatal(1,"Signed/unsigned wide product mismatch");
  end else begin
   #1;if(samples>=4 && (product!==held || wide_product!==wide_held))$fatal(1,"Product changed on CE stall");
  end
  held=product;wide_held=wide_product;
  if(cycles==10000)begin $display("TB_WIDE_MULTIPLIERS_PASS samples=%0d",samples);$finish;end
 end
endmodule

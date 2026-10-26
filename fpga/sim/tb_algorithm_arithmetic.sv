`timescale 1ns/1ps
// Purpose: independent full-width multiplication and optional colour-matrix golden.
module tb_signed_mult32_pipe;
 reg clk=0;always #3.333 clk=~clk;
 reg advance=0;reg signed [31:0] a=0,b=0;wire signed [63:0] product;
 reg [2:0] valid=0;reg signed [63:0] expected[0:2];
 reg signed [63:0] held;integer checked=0,stalls=0;
 signed_mult32_pipe dut(clk,advance,a,b,product);
 always @(posedge clk) begin
  held=product;
  if(advance)begin valid<={valid[1:0],1'b1};expected[0]<=$signed(a)*$signed(b);expected[1]<=expected[0];expected[2]<=expected[1];end
  #0.001;
  if(!advance)begin if(product!==held)$fatal(1,"MULT_FAIL stalled arithmetic changed");stalls=stalls+1;end
  if(valid[2])begin if(product!==expected[2])$fatal(1,"MULT_FAIL signed full product");if(advance)checked=checked+1;end
 end
 initial begin
  for(integer n=0;n<10000;n=n+1)begin
   @(negedge clk);advance=n<12 ? 1 : $urandom_range(0,4)!=0;
   case(n)
    0:begin a=-2147483648;b=-2147483648;end
    1:begin a=2147483647;b=-2147483648;end
    2:begin a=-1;b=-1;end
    3:begin a=65535;b=-65536;end
    default:begin a=$urandom;b=$urandom;end
   endcase
  end
  repeat(3)@(negedge clk);if(checked<7000 || stalls<1000)$fatal(1,"MULT_FAIL coverage");
  $display("MULT_PASS checked=%0d stalled=%0d full_signed_extremes",checked,stalls);$finish;
 end
endmodule

module tb_rgb_colour_matrix;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,iv=0,ready=1;wire ir,ov,mask;reg [35:0] rgb;reg [161:0] coeff;
 reg [63:0] tag;wire [63:0] out_tag;wire [23:0] result;
 reg [23:0] expected[0:2999];integer n=0,received=0,case_no;
 rgb_colour_matrix #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(ir),.in_rgb(rgb),
  .coefficients(coeff),.in_tag(tag),.in_mask(1'b1),.out_valid(ov),.out_ready(ready),.out_rgb(result),.out_mask(mask),.out_tag(out_tag));
 always @(negedge clk)ready=$urandom_range(0,4)!=0;
 always @(posedge clk)if(rst_n && ov && ready)begin
  if(!mask || out_tag!==received || result!==expected[received])$fatal(1,"CCM_FAIL n=%0d got=%h expected=%h",received,result,expected[received]);
  received=received+1;
 end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;
  for(case_no=0;case_no<3;case_no=case_no+1)begin
   @(negedge clk);
   for(integer row=0;row<3;row=row+1)for(integer col=0;col<3;col=col+1)
    coeff[(row*3+col)*18+:18]=row==col ? (case_no==0 ? 16384 : case_no==1 ? 65536 : -16384) : (case_no==1 ? -8192 : 0);
   for(integer pixel_index=0;pixel_index<800;pixel_index=pixel_index+1)begin
    @(negedge clk);iv=1;tag=n;
    for(integer channel=0;channel<3;channel=channel+1)rgb[channel*12+:12]=$urandom_range(0,4095);
    for(integer row=0;row<3;row=row+1)begin
     reg signed [63:0] sum,q;
     sum=0;
     for(integer col=0;col<3;col=col+1)sum=sum+$signed(coeff[(row*3+col)*18+:18])*$signed({1'b0,rgb[(2-col)*12+:12]});
     q=(sum+131072)>>>18;expected[n][(2-row)*8+:8]=q<0 ? 0 : q>255 ? 255 : q;
    end
    do @(posedge clk);while(!ir);n=n+1;
   end
   @(negedge clk);iv=0;wait(received==n);repeat(4)@(negedge clk);
  end
  $display("CCM_PASS pixels=%0d identity_negative_saturation",received);$finish;
 end
 initial begin #2000000;$fatal(1,"CCM_TIMEOUT");end
endmodule

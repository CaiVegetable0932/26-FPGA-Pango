// Purpose: bounded configuration-time signed 96/64 division. A held result
// and done pulse replace a combinational divider; divide-by-zero is explicit.
module geometry_marker_divide(input wire clk,rst_n,start,
 input wire signed [95:0] numerator,input wire signed [63:0] denominator,
 output reg done,failed,output reg signed [95:0] result);
 reg busy,negative;reg [6:0] step;reg [95:0] bits,q;
 reg [63:0] divisor,remnant;
 wire [64:0] trial={remnant,bits[95]};
 wire take_bit=trial>={1'b0,divisor};
 wire [95:0] next_q={q[94:0],take_bit};
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin busy<=0;done<=0;failed<=0;result<=0;step<=0;bits<=0;q<=0;divisor<=0;remnant<=0;negative<=0;end
 else begin
  done<=0;
  if(start && !busy)begin
   bits<=numerator[95]?-numerator:numerator;
   divisor<=denominator[63]?-denominator:denominator;
   negative<=numerator[95]^denominator[63];q<=0;remnant<=0;step<=0;
   failed<=denominator==0;busy<=denominator!=0;
   if(denominator==0)begin done<=1;result<=0;end
  end else if(busy)begin
   bits<=bits<<1;q<=next_q;
   remnant<=take_bit?trial-{1'b0,divisor}:trial;
   if(step==95)begin busy<=0;done<=1;result<=negative?-$signed(next_q):$signed(next_q);end
   else step<=step+1'b1;
  end
 end
endmodule

// Purpose: bounded configuration-time signed 96/64 division. A held result
// and done pulse replace a combinational divider; divide-by-zero is explicit.
module geometry_marker_divide(input wire clk,rst_n,start,
 input wire signed [95:0] numerator,input wire signed [63:0] denominator,
 output reg done,failed,output reg signed [95:0] result)
 // Purpose: preserve held results without the mapped 24-CLM CE cascade.
 // ADS 2022.2-SP6.4 section 5.17 moves these bounded control sets to D-input
 // feedback muxes. This affects hardware packing only, not division latency,
 // zero-divide behavior, reset, or the public done/failed/result contract.
 /* synthesis syn_reduce_controlset_size = 1024 syn_useioff = 0 */;
 reg busy,negative;reg [6:0] step;reg [95:0] bits,q;
 reg [63:0] divisor,remnant;
 wire [64:0] trial={remnant,bits[95]};
 wire take_bit=trial>={1'b0,divisor};
 wire [95:0] next_q={q[94:0],take_bit};
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin busy<=0;done<=0;failed<=0;result<=0;step<=0;bits<=0;q<=0;divisor<=0;remnant<=0;negative<=0;end
 else begin
  done<=0;
  // Purpose: bits is scratch state, not a held output. Shift on EVERY idle
  // or busy cycle to remove the shared 96-bit busy/start clock-enable chain.
  // An accepted start below still overrides this assignment with the exact
  // original absolute numerator. Busy-start ignores the new input as before;
  // all 96 useful division steps, result holds and done/failed timing remain.
  bits<=bits<<1;
  if(start && !busy)begin
   bits<=numerator[95]?-numerator:numerator;
   divisor<=denominator[63]?-denominator:denominator;
   negative<=numerator[95]^denominator[63];q<=0;remnant<=0;step<=0;
   failed<=denominator==0;busy<=denominator!=0;
   if(denominator==0)begin done<=1;result<=0;end
  end else if(busy)begin
   q<=next_q;
   remnant<=take_bit?trial-{1'b0,divisor}:trial;
   if(step==95)begin busy<=0;done<=1;result<=negative?-$signed(next_q):$signed(next_q);end
   else step<=step+1'b1;
  end
 end
endmodule

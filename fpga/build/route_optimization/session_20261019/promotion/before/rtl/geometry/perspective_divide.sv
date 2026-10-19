`timescale 1ns/1ps
// Purpose: projective q0/q2,q1/q2 -> normalized S(24,20) rays, II=1.
// Positive S(40,26) depth only, q2>=2^-12; reject the behind-camera plane.
// U(31,30) normalized mantissa, 256 midpoint seeds, two Newton refinements.
// Exact accepted range/error are scanned by the golden regression. The
// 26 stages split native APM partial products and carry sums; every stage
// shares advance, preserving all tags/data under arbitrary backpressure.
module perspective_divide #(parameter TAG_BITS=192)(
 input clk,rst_n,input in_valid,output in_ready,
 input signed [39:0] q0,q1,q2,input in_ok,input [TAG_BITS-1:0] in_tag,
 output out_valid,input out_ready,output reg signed [23:0] out_x,out_y,
 output out_ok,output [TAG_BITS-1:0] out_tag
);
 reg [25:0] valid,ok;
 // PDS 2022.2-SP6.4 ADS section 5.16: preserve all CE steps and bits,
 // but request distributed storage for pure payload shift chains.
 wire [TAG_BITS-1:0] delayed_tag;
 wire signed [39:0] delayed_n0,delayed_n1;
 reg signed [6:0] exponent[0:20];
 reg [39:0] denominator;reg [40:0] rounded_denominator;
 reg [5:0] normalize_shift;reg normalize_right;reg [7:0] normalize_bias;
 wire [31:0] normalized=normalize_right?(rounded_denominator>>normalize_shift):(rounded_denominator<<normalize_shift);
 reg [30:0] mantissa[0:8];
 reg [30:0] seed,r1,r2;
 reg [30:0] seed_delay[0:3],r1_delay[0:3];
 wire [63:0] mr0_full,mr1_full,next0_full,next1_full;
 wire [61:0] mr0=mr0_full[61:0],mr1=mr1_full[61:0];
 reg [31:0] correction0,correction1;
 wire [62:0] next0=next0_full[62:0],next1=next1_full[62:0];
 // Q34 reciprocal retains eight more fractional bits after exponent scaling.
 // At the full accepted signed40 depth range its final quantization contributes
 // at most 0.25 output LSB; Q26 had up to tens of LSB at large depths.
 reg [47:0] reciprocal;
 wire signed [87:0] x_product,y_product;
 reg [30:0] seed_rom[0:255] /* synthesis syn_ramstyle="block_ram" */;
 wire advance=!valid[25] || out_ready;

 // Purpose: retain exact 21/26-advance payload alignment in circular LUT RAM.
 // Reads use addresses distinct from the simultaneous write, with an explicit
 // output register. Stall/reset holds payload; validity flushes old RAM data.
 reg [4:0] payload_write;
 wire [4:0] numerator_read=payload_write-5'd20;
 wire [4:0] tag_read=payload_write-5'd25;
 reg [79:0] numerator_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [TAG_BITS-1:0] tag_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [79:0] numerator_output;
 reg [TAG_BITS-1:0] tag_output;
 assign {delayed_n0,delayed_n1}=numerator_output;
 assign delayed_tag=tag_output;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) payload_write<=0;
  else if(advance) payload_write<=payload_write+1'b1;
 end
 always @(posedge clk) if(rst_n && advance) begin
  numerator_memory[payload_write]<={q0,q1};
  tag_memory[payload_write]<=in_tag;
  numerator_output<=numerator_memory[numerator_read];
  tag_output<=tag_memory[tag_read];
 end
 integer i,leading,k;
 reg signed [6:0] e;
reg [31:0] rounded_reciprocal;reg [5:0] reciprocal_shift;reg reciprocal_right;reg [8:0] reciprocal_bias;
 wire [47:0] scaled=reciprocal_right?({16'd0,rounded_reciprocal}>>reciprocal_shift):({16'd0,rounded_reciprocal}<<reciprocal_shift);
 wire signed [87:0] xr=(x_product+88'sd549755813888)>>>40;
 wire signed [87:0] yr=(y_product+88'sd549755813888)>>>40;
 // Exact partial products use the documented Logos2 APM input widths.
 unsigned_mult32_pipe mul_mr0(clk,advance,{1'b0,mantissa[0]},{1'b0,seed},mr0_full);
 unsigned_mult32_pipe mul_next0(clk,advance,{1'b0,seed_delay[3]},correction0,next0_full);
 unsigned_mult32_pipe mul_mr1(clk,advance,{1'b0,mantissa[8]},{1'b0,r1},mr1_full);
 unsigned_mult32_pipe mul_next1(clk,advance,{1'b0,r1_delay[3]},correction1,next1_full);
 signed_mult40_unsigned40_pipe #(.B_BITS(48)) mul_x(clk,advance,delayed_n0,reciprocal,x_product);
 signed_mult40_unsigned40_pipe #(.B_BITS(48)) mul_y(clk,advance,delayed_n1,reciprocal,y_product);
 // Seeds are elaboration-time constants, equivalent to the model's midpoint LUT;
 // division here initializes ROM, never a per-pixel divider or runtime operation.
 initial for(i=0;i<256;i=i+1)
  seed_rom[i]=(64'd549755813888+(513+2*i)/2)/(513+2*i);
 // Installed ADS requires loop indices declared at module scope. This only
 // changes parser compatibility; the leading-bit priority scan is unchanged.
 always @* begin
  leading=0;
  for(k=0;k<39;k=k+1) if(q2[k]) leading=k;
  e=leading-26;
  // A positive signed40 depth has e<=12. Register its rounding and shift
  // control before the mantissa barrel; no exponent arithmetic feeds APM
  // operand setup through the whole normalizer on the same edge.
  normalize_bias=0;
  case(exponent[0])
   5:normalize_bias=1;6:normalize_bias=2;7:normalize_bias=4;8:normalize_bias=8;
   9:normalize_bias=16;10:normalize_bias=32;11:normalize_bias=64;12:normalize_bias=128;
  endcase
  // Split exponent/bias preparation from the final reciprocal barrel.
  // Accepted normalization may carry e=12 into e=13, hence the 9-bit bias.
  reciprocal_bias=0;
  case(exponent[18])
   5:reciprocal_bias=1;6:reciprocal_bias=2;7:reciprocal_bias=4;8:reciprocal_bias=8;
   9:reciprocal_bias=16;10:reciprocal_bias=32;11:reciprocal_bias=64;12:reciprocal_bias=128;13:reciprocal_bias=256;
  endcase
 end
 assign in_ready=advance,out_valid=valid[25],out_ok=ok[25],out_tag=delayed_tag;
 // Reset only lane validity and the public coordinate outputs. These flags
 // mask stale arithmetic/tag payload until a newly accepted lane reaches it.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin valid<=0;ok<=0;out_x<=0;out_y<=0;end
  else if(advance) begin
   valid<={valid[24:0],in_valid};ok<={ok[24:0],in_ok && q2>=40'sd16384};
   ok[20]<=ok[19] && !scaled[47];
   out_x<=xr[23:0];out_y<=yr[23:0];
   ok[25]<=ok[24] && xr>=-88'sd8388608 && xr<88'sd8388608 && yr>=-88'sd8388608 && yr<88'sd8388608;
  end
 end
 // Keep unreset payload in a clock-only bank so ADS can infer native clock
 // enables without an asynchronous-reset hold feedback mux per payload bit.
 // The rst_n guard preserves the old payload hold during reset; every bank
 // still advances on exactly the same accepted edge as valid/ok above.
 always @(posedge clk) begin
  if(rst_n && advance) begin
   denominator<=q2;exponent[0]<=e;
   for(i=1;i<21;i=i+1) begin exponent[i]<=exponent[i-1];end
   rounded_denominator<={1'b0,denominator}+normalize_bias;
   normalize_right<=exponent[0]>4;normalize_shift<=exponent[0]>4?(exponent[0]-4):(4-exponent[0]);
   // For every accepted positive depth, the normalized value is 31 bits or
   // exactly 2^31 after rounding. Preserve that carry bit; invalid depth's
   // arbitrary coordinate payload is masked by ok, never used for memory.
   mantissa[0]<=normalized[31] ? 31'd1073741824 : normalized[30:0];
   seed<=seed_rom[normalized[31] ? 8'd0 : normalized[29:22]];
   if(normalized[31]) exponent[2]<=exponent[1]+1'b1;
   for(i=1;i<9;i=i+1) mantissa[i]<=mantissa[i-1];
   // Two Newton steps retain their original rounding; 3-stage multiplies
   // align seed/mantissa and a 4-stage final numerator multiply feeds output.
   seed_delay[0]<=seed;
   for(i=1;i<4;i=i+1)seed_delay[i]<=seed_delay[i-1];
   correction0<=32'd2147483648-((mr0+62'd536870912)>>30);
   r1<=(next0+63'd536870912)>>30;
   r1_delay[0]<=r1;
   for(i=1;i<4;i=i+1)r1_delay[i]<=r1_delay[i-1];
   correction1<=32'd2147483648-((mr1+62'd536870912)>>30);
   r2<=(next1+63'd536870912)>>30;
   rounded_reciprocal<={1'b0,r2}+reciprocal_bias;
   reciprocal_right<=exponent[18]>4;reciprocal_shift<=exponent[18]>4?(exponent[18]-4):(4-exponent[18]);
   reciprocal<=scaled;
  end
 end
endmodule

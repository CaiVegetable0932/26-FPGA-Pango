// Purpose: exact signed wide multiplication with registered operands, 16-bit partial
// products and a registered balanced adder tree. No combinational DSP cascade
// may span an entire 32/36/40-bit product. One request may arrive each clock.
// PDS 2022.2-SP6.4 ADS pp.70-71 documents syn_dspstyle=block_mult;
// Logos2 DS04001 v1.5 p.11 specifies signed 25x18 APMs. Leaves are 17x17.
// A_WIDTH/B_WIDTH >=17 is the contract of the geometry instances.
module geometry_mul_pipe #(parameter A_WIDTH=32,B_WIDTH=36)(
 input wire clk,rst_n,request_valid,
 input wire signed [A_WIDTH-1:0] a,input wire signed [B_WIDTH-1:0] b,
 output wire result_valid,output wire signed [A_WIDTH+B_WIDTH-1:0] product
);
 localparam AC=(A_WIDTH+15)/16,BC=(B_WIDTH+15)/16;
 localparam LEVELS=$clog2(AC*BC),PAD=1<<LEVELS,P=A_WIDTH+B_WIDTH;
 reg [LEVELS:0] valid_pipe;
 // Purpose: isolate caller arithmetic/multiplexers (especially LUT delta)
 // from leaf multiplication. This input stage is part of the valid pipeline.
 reg input_valid;
 reg signed [A_WIDTH-1:0] operand_a /* synthesis syn_preserve=1 */;
 reg signed [B_WIDTH-1:0] operand_b /* synthesis syn_preserve=1 */;
 always @(posedge clk)if(request_valid)begin operand_a<=a;operand_b<=b;end
 wire signed [P-1:0] node[0:(LEVELS+1)*PAD-1];
 genvar n,l;
 generate for(n=0;n<PAD;n=n+1)begin:g_leaf
  if(n<AC*BC)begin:g_used
   localparam AI=n/BC,BI=n%BC;
   localparam AW=(A_WIDTH-AI*16>=16)?16:A_WIDTH-AI*16;
   localparam BW=(B_WIDTH-BI*16>=16)?16:B_WIDTH-BI*16;
   // Only the highest chunk carries a sign; lower chunks are nonnegative.
   wire signed [16:0] av=AI==AC-1?
       {{(17-AW){operand_a[A_WIDTH-1]}},operand_a[AI*16+:AW]}:{1'b0,operand_a[AI*16+:AW]};
   wire signed [16:0] bv=BI==BC-1?
       {{(17-BW){operand_b[B_WIDTH-1]}},operand_b[BI*16+:BW]}:{1'b0,operand_b[BI*16+:BW]};
   wire signed [33:0] leaf_product /* synthesis syn_dspstyle="block_mult" */;
   reg signed [33:0] partial /* synthesis syn_preserve=1 */;
   assign leaf_product=av*bv;
   // Payload need not reset: downstream may consume it only with valid.
   always @(posedge clk)if(input_valid)partial<=leaf_product;
   wire signed [P-1:0] extended={{(P-34){partial[33]}},partial};
   assign node[n]=extended<<<(16*(AI+BI));
  end else begin:g_pad
   assign node[n]=0;
  end
 end
 for(l=1;l<=LEVELS;l=l+1)begin:g_level
  for(n=0;n<(PAD>>l);n=n+1)begin:g_sum
   reg signed [P-1:0] sum /* synthesis syn_preserve=1 */;
   always @(posedge clk)if(valid_pipe[l-1])
    sum<=node[(l-1)*PAD+2*n]+node[(l-1)*PAD+2*n+1];
   assign node[l*PAD+n]=sum;
  end
 end endgenerate
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin valid_pipe<=0;input_valid<=0;end
  else begin
   input_valid<=request_valid;
   valid_pipe<={valid_pipe[LEVELS-1:0],input_valid};
  end
 assign product=node[LEVELS*PAD],result_valid=valid_pipe[LEVELS];
endmodule

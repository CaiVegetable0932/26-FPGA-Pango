`timescale 1ns/1ps
// Purpose: validate a normalized, axis-aligned reference against its declared
// output intrinsics. Products use signed 64 bits; half-denominator residuals
// implement round-to-nearest validation without synthesis of a divider.
// This is geometric format validation, not an optical calibration certificate.
module affine_reference_guard #(parameter WIDTH=1920,HEIGHT=1080,PIPELINED=0)(
 input [511:0] entity,output legal,
 input clk,rst_n,output result_valid
);
 generate if(!PIPELINED)begin:combinational
 assign result_valid=1'b1;
 wire signed [31:0] fx=entity[0+:32],fy=entity[32+:32];
 wire signed [31:0] cx=entity[64+:32],cy=entity[96+:32];
 wire signed [31:0] a00=entity[128+:32],a02=entity[192+:32];
 wire signed [31:0] a11=entity[256+:32],a12=entity[288+:32];
 wire signed [63:0] sx=a00*fx,sy=a11*fy;
 wire signed [63:0] ox=a02*fx,oy=a12*fy;
 wire signed [63:0] ex=sx-64'sh40000000000,ey=sy-64'sh40000000000;
 wire signed [63:0] tx=ox+($signed({{32{cx[31]}},cx})<<<26);
 wire signed [63:0] ty=oy+($signed({{32{cy[31]}},cy})<<<26);
 wire signed [63:0] hx=$signed(fx)>>>1,hy=$signed(fy)>>>1;
 assign legal=fx>0 && fy>0 && fx<=32'sh20000000 && fy<=32'sh20000000 &&
  cx>=-32'sh20000000 && cx<=32'sh20000000 && cy>=-32'sh20000000 && cy<=32'sh20000000 &&
  a00>0 && a00<=32'sh00800000 && a11>0 && a11<=32'sh00800000 &&
  a02>=-32'sh20000000 && a02<=32'sh20000000 && a12>=-32'sh20000000 && a12<=32'sh20000000 &&
  entity[160+:32]==0 && entity[224+:32]==0 &&
  entity[320+:16]==WIDTH && entity[336+:16]==HEIGHT && entity[352+:32]!=0 &&
  entity[384+:16]==1 && entity[511:400]==0 &&
  ex>=-hx && ex<=hx && ey>=-hy && ey<=hy && tx>=-hx && tx<=hx && ty>=-hy && ty<=hy;
 end else begin:sequential
 // The board checks a frozen entity with one signed 17x17 multiplier. Four
 // partial products replace each cascaded 32x32 APM path; intermediate sums
 // and residuals have separate registers. Residual/range hardware is shared
 // across all four products. A stable input completes within 73 clocks even
 // if an older entity was already being evaluated (36 clocks per evaluation).
 localparam LL=1,LH=2,HL=3,HH=4,CROSS=5,HALVES=6,PACK=7,RESIDUAL=8,CHECK=9;
 reg [511:0] frozen;
 reg busy,cached,format_ok,accepted,all_products_ok;
 reg [3:0] phase;reg [1:0] product_index;
 reg [31:0] low_low;reg signed [32:0] low_high,high_low;
 reg signed [31:0] high_high;
 reg signed [33:0] cross_sum,high_sum;
 reg [32:0] low_sum;
 reg signed [63:0] current_product,current_residual;
 reg signed [31:0] operand_a,operand_b;
 wire signed [16:0] ma=(phase==LL || phase==LH)?$signed({1'b0,operand_a[15:0]}):$signed({operand_a[31],operand_a[31:16]});
 wire signed [16:0] mb=(phase==LL || phase==HL)?$signed({1'b0,operand_b[15:0]}):$signed({operand_b[31],operand_b[31:16]});
 wire signed [33:0] partial=ma*mb;
 wire signed [33:0] final_high=high_sum+$signed({33'd0,low_sum[32]});
 wire signed [63:0] product={final_high[31:0],low_sum[31:0]};
 wire signed [31:0] half_focal=$signed(product_index[0]?frozen[32+:32]:frozen[0+:32])>>>1;
 wire signed [31:0] centre=product_index[0]?frozen[96+:32]:frozen[64+:32];
 wire signed [63:0] residual_offset=product_index[1]?($signed({{32{centre[31]}},centre})<<<26):-64'sh40000000000;
 // Legal focal <=2^29 bounds the residual tolerance to 2^28. A signed32
 // representability check plus signed32 comparisons is exactly the original
 // signed64 interval test in this domain; the raw layout gate remains intact.
 wire residual_fits32=current_residual[63:31]=={33{current_residual[31]}};
 wire residual_ok=residual_fits32 && $signed(current_residual[31:0])>=-half_focal &&
                  $signed(current_residual[31:0])<=half_focal;
 // A cached answer is usable only for its exact input bytes. This immediate
 // invalidation prevents old legal results authorizing a newly staged body;
 // no UART inter-packet timing assumption is used. Keep a balanced LUT-sized
 // comparison tree instead of allowing ADS to concatenate 512 equality bits
 // into one long carry chain. Installed ADS Guide PDF84-85 defines syn_keep
 // on connected nets as preserving these combinational boundaries. All
 // comparison/reduction stages remain combinational: every changed bit invalidates in this cycle,
 // and an exact ABA return can reuse only the matching frozen body as before.
 wire [512:0] match_left={1'b0,frozen},match_right={1'b0,entity};
 wire [170:0] match_triplets;
 wire [28:0] match_groups;
 wire [4:0] match_branches;
 wire [173:0] padded_triplets={3'b111,match_triplets};
 wire [29:0] padded_groups={1'b1,match_groups};
 for(genvar match_leaf=0;match_leaf<171;match_leaf=match_leaf+1)begin:exact_triplet
  (* syn_keep=1 *) wire equal;
  assign equal=match_left[match_leaf*3+:3]==match_right[match_leaf*3+:3];
  assign match_triplets[match_leaf]=equal;
 end
 for(genvar match_group=0;match_group<29;match_group=match_group+1)begin:exact_group
  (* syn_keep=1 *) wire equal;
  assign equal=&padded_triplets[match_group*6+:6];
  assign match_groups[match_group]=equal;
 end
 for(genvar match_branch=0;match_branch<5;match_branch=match_branch+1)begin:exact_branch
  (* syn_keep=1 *) wire equal;
  assign equal=&padded_groups[match_branch*6+:6];
  assign match_branches[match_branch]=equal;
 end
 wire entity_matches=&match_branches;
 assign result_valid=cached && entity_matches;
 assign legal=result_valid && accepted;
 always @*begin
  case(product_index)
   0:begin operand_a=frozen[128+:32];operand_b=frozen[0+:32];end
   1:begin operand_a=frozen[256+:32];operand_b=frozen[32+:32];end
   2:begin operand_a=frozen[192+:32];operand_b=frozen[0+:32];end
   default:begin operand_a=frozen[288+:32];operand_b=frozen[32+:32];end
  endcase
 end
 function layout_legal(input [511:0] e);
  reg signed [31:0] fx,fy,cx,cy,a00,a11,a02,a12;
  begin
   fx=e[0+:32];fy=e[32+:32];cx=e[64+:32];cy=e[96+:32];
   a00=e[128+:32];a11=e[256+:32];a02=e[192+:32];a12=e[288+:32];
   layout_legal=fx>0 && fy>0 && fx<=32'sh20000000 && fy<=32'sh20000000 &&
    cx>=-32'sh20000000 && cx<=32'sh20000000 && cy>=-32'sh20000000 && cy<=32'sh20000000 &&
    a00>0 && a00<=32'sh00800000 && a11>0 && a11<=32'sh00800000 &&
    a02>=-32'sh20000000 && a02<=32'sh20000000 && a12>=-32'sh20000000 && a12<=32'sh20000000 &&
    e[160+:32]==0 && e[224+:32]==0 && e[320+:16]==WIDTH && e[336+:16]==HEIGHT &&
    e[352+:32]!=0 && e[384+:16]==1 && e[511:400]==0;
  end
 endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   frozen<=0;busy<=0;cached<=0;format_ok<=0;accepted<=0;all_products_ok<=1;phase<=0;product_index<=0;
   low_low<=0;low_high<=0;high_low<=0;high_high<=0;cross_sum<=0;high_sum<=0;low_sum<=0;
   current_product<=0;current_residual<=0;
  end else if(!busy)begin
   if(!cached || !entity_matches)begin
    frozen<=entity;format_ok<=layout_legal(entity);cached<=0;busy<=1;phase<=LL;product_index<=0;all_products_ok<=1;
   end
  end else begin
   case(phase)
    LL:begin low_low<=partial[31:0];phase<=LH;end
    LH:begin low_high<=partial[32:0];phase<=HL;end
    HL:begin high_low<=partial[32:0];phase<=HH;end
    HH:begin high_high<=partial[31:0];phase<=CROSS;end
    CROSS:begin cross_sum<=$signed({low_high[32],low_high})+$signed({high_low[32],high_low});phase<=HALVES;end
    HALVES:begin
     low_sum<={1'b0,low_low}+{1'b0,cross_sum[15:0],16'd0};
     high_sum<=$signed({{2{high_high[31]}},high_high})+(cross_sum>>>16);phase<=PACK;
    end
    PACK:begin
     current_product<=product;phase<=RESIDUAL;
    end
    RESIDUAL:begin
     current_residual<=current_product+residual_offset;phase<=CHECK;
    end
    CHECK:begin
     if(product_index==3)begin
      accepted<=format_ok && all_products_ok && residual_ok;cached<=1;busy<=0;
     end else begin
      all_products_ok<=all_products_ok && residual_ok;product_index<=product_index+1'b1;phase<=LL;
     end
    end
   endcase
  end
 end
 end endgenerate
endmodule

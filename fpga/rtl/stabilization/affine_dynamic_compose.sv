`timescale 1ns/1ps
// One frame-level sequential M*V composition. M is ray Q26; V is a
// pixel-domain centred crop in Q16 (pixel translations do not fit Q26/i32).
// Restoring division computes reciprocal zoom in 33 bounded clocks. No pixel
// divider or second resampling pass is introduced. Overflow returns original M.
module affine_dynamic_compose # (parameter WIDTH=1920,HEIGHT=1080)(
 input clk,rst_n,input request_valid,output request_ready,input enabled,
 input [191:0] manual_matrix,input [31:0] zoom_q16,
 input [63:0] epoch,frame_id,
 output reg result_valid,input result_ready,output reg [191:0] matrix,
 output reg [63:0] result_epoch,result_frame,output reg overflow
);
 reg busy;reg [2:0] phase,index;reg [5:0] bit_index;
 reg [191:0] m,work;
 // Accepted zoom is [65536,131072]: divisor fits 18 bits, restoring
 // remainder is strictly smaller (17 bits), and floor(2^32/zoom) fits
 // 17 bits. Invalid zoom still takes the unchanged immediate fallback.
 reg [16:0] quotient,remainder;reg [17:0] divisor;
 reg signed [31:0] inv_zoom,tx,ty;
 reg signed [63:0] first_product;reg signed [65:0] sum;
 reg signed [31:0] left0,left1,right0,right1,offset;
 // A single explicit multiplication node is shared across both matrix terms
 // in the fixed viewport pass even when ADS resource_sharing is disabled.
 wire second_term=phase==6;
 wire signed [31:0] multiply_left=second_term?left1:left0,multiply_right=second_term?right1:right0;
 wire signed [63:0] product=multiply_left*multiply_right;
 wire [17:0] trial={remainder,1'b0}+(bit_index==32?18'd1:18'd0);
 wire signed [65:0] rounded=(sum+32768)>>>16;
 assign request_ready=!busy && !result_valid;
 // Each three-word row is consumed in order. A single two-row selection
 // replaces repeated six-word dynamic slices and index subtraction.
 wire [95:0] selected_row=index>=3 ? m[191:96] : m[95:0];
 // Two shared products generate one coefficient at a time. Translation terms
 // are added at the product scale, preserving an explicit rounding convention.
 always @*begin
  left0=0;left1=0;right0=0;right1=0;offset=0;
  if(phase==2 || phase==6)begin
   if(index==0 || index==3)begin left0=$signed(selected_row[31:0]);right0=inv_zoom;end
   if(index==1 || index==4)begin left0=$signed(selected_row[63:32]);right0=inv_zoom;end
   if(index==2 || index==5)begin
    left0=$signed(selected_row[31:0]);left1=$signed(selected_row[63:32]);right0=tx;right1=ty;offset=$signed(selected_row[95:64]);
   end
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;phase<=0;index<=0;bit_index<=0;m<=0;work<=0;
   quotient<=0;remainder<=0;divisor<=65536;inv_zoom<=65536;tx<=0;ty<=0;first_product<=0;sum<=0;
   result_valid<=0;matrix<=0;result_epoch<=0;result_frame<=0;overflow<=0;
  end else begin
   if(result_valid && result_ready)result_valid<=0;
   if(request_valid && request_ready)begin
    m<=manual_matrix;matrix<=manual_matrix;result_epoch<=epoch;result_frame<=frame_id;overflow<=0;
    if(!enabled)result_valid<=1;
    else if(zoom_q16<65536 || zoom_q16>131072)begin result_valid<=1;overflow<=1;end
    else begin busy<=1;phase<=0;divisor<=zoom_q16[17:0];quotient<=0;remainder<=0;bit_index<=32;end
   end else if(busy)case(phase)
    0:begin
     // Shift in one quotient bit on every original division cycle. The first
     // sixteen quotient bits are zero for every accepted zoom, so retaining
     // only the low seventeen bits preserves the final 33-step division.
     if(trial>=divisor)begin remainder<=trial-divisor;quotient<={quotient[15:0],1'b1};end
     else begin remainder<=trial;quotient<={quotient[15:0],1'b0};end
     if(bit_index==0)phase<=1;else bit_index<=bit_index-1;
    end
    1:begin inv_zoom<={15'd0,quotient};tx<=((65536-$signed({15'd0,quotient}))*(WIDTH-1))/2;
     ty<=((65536-$signed({15'd0,quotient}))*(HEIGHT-1))/2;index<=0;phase<=2;end
    2:begin first_product<=product;phase<=6;end
    6:begin sum<=$signed({{2{first_product[63]}},first_product})+$signed({{2{product[63]}},product})+($signed({{34{offset[31]}},offset})<<<16);phase<=3;end
    3:begin
     if(rounded>2147483647 || rounded< -66'sd2147483648)begin busy<=0;result_valid<=1;overflow<=1;matrix<=m;end
     // The sixth shift leaves exactly the original six little-endian words.
     // Keep m intact independently so any overflow still returns its original.
     else begin work<={rounded[31:0],work[191:32]};if(index==5)begin matrix<={rounded[31:0],work[191:32]};busy<=0;result_valid<=1;end
      else begin index<=index+1;phase<=2;end end
    end
   endcase
  end
 end
endmodule

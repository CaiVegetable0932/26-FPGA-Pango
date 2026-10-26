`timescale 1ns/1ps
// Causal trajectory error uses r_t=(r_(t-1)+delta)-((r_(t-1)+delta)>>shift).
// This is exactly the old path-minus-smoothed-path recurrence, without an
// unbounded absolute path. Four dimensions share one adder/shifter and one
// 32x32 multiplier. Results keep the captured source identity through latency.
module motion_trajectory(
 input clk,rst_n,clear,input observation_valid,enabled,domain_valid,
 input [63:0] epoch,frame_id,input [3:0] observation_status,input [255:0] config_entity,
 input signed [31:0] dx_q16,dy_q16,rotation_q26,scale_delta_q26,inv_focal_q26,
 output reg result_valid,output reg [63:0] result_epoch,result_frame,
 output reg [191:0] compensation,output reg [3:0] status,
 output reg [31:0] requested_zoom_q16
);
 localparam [191:0] IDENTITY={32'd0,32'd67108864,32'd0,32'd0,32'd0,32'd67108864};
 reg [63:0] last_epoch,last_frame;reg have_last,busy;reg [2:0] phase;reg [1:0] index;reg [3:0] shift;
 // With signed i32 input and shift<=8, residual magnitude is <2^39. Forty-one
 // bits cover both signs and the next addition with no long-duration drift.
 reg signed [40:0] residual[0:3],sum;
 reg signed [31:0] delta[0:3],limit[0:3],correction[0:3],focal,ray_x,ray_y;
 reg signed [31:0] multiply_a,multiply_b;wire signed [63:0] product=multiply_a*multiply_b;
 wire signed [63:0] ray_rounded=(product+32768)>>>16;
 wire signed [40:0] filtered=sum-(sum>>>shift);
 wire signed [31:0] clipped=filtered>$signed(limit[index])?limit[index]:filtered<-$signed(limit[index])?-limit[index]:filtered[31:0];
 wire [31:0] abs_x=correction[0][31]?-correction[0]:correction[0];
 wire [31:0] abs_y=correction[1][31]?-correction[1]:correction[1];
 wire [31:0] abs_rotation=correction[2][31]?-correction[2]:correction[2];
 wire [31:0] abs_scale=correction[3][31]?-correction[3]:correction[3];
 reg [31:0] zoom_x;
 // ceil(2^32/480) and ceil(2^32/270). Inputs are bounded by 256px Q16;
 // ceil(product/2^32) is conservative and at most one Q16 unit above ceil(x/d).
 // No signed division primitive is inferred by the installed ADS version.
 wire [63:0] rounded_magnitude=$unsigned(product)+64'hffffffff;
 wire [33:0] demand=34'd65536+zoom_x+rounded_magnitude[63:32]+(abs_rotation>>8)+(abs_scale>>9);
 integer i;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   result_valid<=0;result_epoch<=0;result_frame<=0;last_epoch<=0;last_frame<=0;have_last<=0;busy<=0;phase<=0;index<=0;shift<=1;sum<=0;
   compensation<=IDENTITY;status<=1;requested_zoom_q16<=65536;focal<=0;ray_x<=0;ray_y<=0;multiply_a<=0;multiply_b<=0;zoom_x<=0;
   for(i=0;i<4;i=i+1)begin residual[i]<=0;delta[i]<=0;limit[i]<=0;correction[i]<=0;end
  end else begin
   result_valid<=0;
   if(clear)begin
    have_last<=0;busy<=0;compensation<=IDENTITY;status<=1;
    for(i=0;i<4;i=i+1)residual[i]<=0;
   end else if(observation_valid && !busy)begin
    result_epoch<=epoch;result_frame<=frame_id;last_epoch<=epoch;last_frame<=frame_id;
    compensation<=IDENTITY;requested_zoom_q16<=65536;
    if(!enabled || !domain_valid || observation_status!=0 || !have_last || last_epoch!=epoch || frame_id!=last_frame+1)begin
     result_valid<=1;have_last<=enabled && domain_valid;
     status<=!enabled?1:!domain_valid?4:observation_status!=0?observation_status:1;
     for(i=0;i<4;i=i+1)residual[i]<=0;
    end else begin
     busy<=1;phase<=0;index<=0;status<=0;shift<=config_entity[11:8];focal<=inv_focal_q26;
     delta[0]<=dx_q16;delta[1]<=dy_q16;delta[2]<=rotation_q26;delta[3]<=scale_delta_q26;
     limit[0]<=config_entity[95:64];limit[1]<=config_entity[95:64];limit[2]<=config_entity[127:96];limit[3]<=config_entity[159:128];
    end
   end else if(busy)case(phase)
    0:begin sum<=residual[index]+delta[index];phase<=1;end
    1:begin
     residual[index]<=filtered;correction[index]<=clipped;
     if(index==3)phase<=2;else begin index<=index+1;phase<=0;end
    end
    2:begin multiply_a<=correction[0];multiply_b<=focal;phase<=3;end
    3:begin
     if(ray_rounded>2147483647 || ray_rounded< -64'sd2147483648)begin busy<=0;result_valid<=1;status<=5;have_last<=0;end
     else begin ray_x<=ray_rounded[31:0];multiply_a<=correction[1];multiply_b<=focal;phase<=4;end
    end
    4:begin
     if(ray_rounded>2147483647 || ray_rounded< -64'sd2147483648)begin busy<=0;result_valid<=1;status<=5;have_last<=0;end
     else begin ray_y<=ray_rounded[31:0];multiply_a<=abs_x;multiply_b<=32'd8947849;phase<=5;end
    end
    5:begin zoom_x<=rounded_magnitude[63:32];multiply_a<=abs_y;multiply_b<=32'd15907287;phase<=6;end
    6:begin
     busy<=0;result_valid<=1;requested_zoom_q16<=demand>131072?131072:demand[31:0];
     compensation<={ray_y,32'd67108864+correction[3],correction[2],ray_x,-correction[2],32'd67108864+correction[3]};
    end
   endcase
  end
 end
endmodule

`timescale 1ns/1ps
// Low-rate iterative CORDIC. Input is the original mechanical millidegree
// domain; Q16 millidegree residual avoids a host or hardware radians divider.
// Q30 XY work registers round to Q26. Valid holds through output backpressure.
module pose_sincos(input clk,rst_n,input request_valid,output request_ready,
 input signed [31:0] angle_mdeg,output reg result_valid,input result_ready,
 output reg signed [31:0] sine,cosine);
 reg busy;reg [4:0] iteration;reg signed [34:0] z;
 reg signed [31:0] x,y;reg signed [34:0] angle_step;
 assign request_ready=!busy && !result_valid;
 always @*begin
  case(iteration)
   5'd0: angle_step=35'sd2949120000;
   5'd1: angle_step=35'sd1740967194;
   5'd2: angle_step=35'sd919879252;
   5'd3: angle_step=35'sd466945071;
   5'd4: angle_step=35'sd234378650;
   5'd5: angle_step=35'sd117303582;
   5'd6: angle_step=35'sd58666104;
   5'd7: angle_step=35'sd29334842;
   5'd8: angle_step=35'sd14667645;
   5'd9: angle_step=35'sd7333850;
   5'd10: angle_step=35'sd3666929;
   5'd11: angle_step=35'sd1833465;
   5'd12: angle_step=35'sd916732;
   5'd13: angle_step=35'sd458366;
   5'd14: angle_step=35'sd229183;
   5'd15: angle_step=35'sd114592;
   5'd16: angle_step=35'sd57296;
   5'd17: angle_step=35'sd28648;
   5'd18: angle_step=35'sd14324;
   5'd19: angle_step=35'sd7162;
   5'd20: angle_step=35'sd3581;
   5'd21: angle_step=35'sd1790;
   5'd22: angle_step=35'sd895;
   5'd23: angle_step=35'sd448;
   5'd24: angle_step=35'sd224;
   5'd25: angle_step=35'sd112;
   5'd26: angle_step=35'sd56;
   5'd27: angle_step=35'sd28;
   default:angle_step=0;
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin busy<=0;result_valid<=0;iteration<=0;x<=0;y<=0;z<=0;sine<=0;cosine<=0;end
  else begin
   if(result_valid && result_ready)result_valid<=0;
   if(request_valid && request_ready)begin
    busy<=1;iteration<=0;y<=0;
    if(angle_mdeg>90000)begin x<=-32'sd652032874;z<=($signed({{3{angle_mdeg[31]}},angle_mdeg})-35'sd180000)<<<16;end
    else if(angle_mdeg< -90000)begin x<=-32'sd652032874;z<=($signed({{3{angle_mdeg[31]}},angle_mdeg})+35'sd180000)<<<16;end
    else begin x<=32'sd652032874;z<=$signed({{3{angle_mdeg[31]}},angle_mdeg})<<<16;end
   end else if(busy)begin
    if(iteration==28)begin sine<=($signed(y)+32'sd8)>>>4;cosine<=($signed(x)+32'sd8)>>>4;busy<=0;result_valid<=1;end
    else begin
     if(z>=0)begin x<=x-(y>>>iteration);y<=y+(x>>>iteration);z<=z-angle_step;end
     else begin x<=x+(y>>>iteration);y<=y-(x>>>iteration);z<=z+angle_step;end
     iteration<=iteration+1'b1;
    end
   end
  end
 end
endmodule

`timescale 1ns/1ps
// Convert a validated MCU_POSE_V2 mechanical pitch/yaw sample into the local
// calibrated ray model. XYZ is intentionally absent: normalized travel has no
// physical translation calibration. Inputs, calibration and identity freeze on
// request. An error returns the supplied manual matrix, never a stale pose.
module pose_affine_model #(parameter CALIBRATION_PREVALIDATED=0)(
 input clk,rst_n,clear,input request_valid,output request_ready,
 input affine_enable,input [1023:0] calibration,input [191:0] manual_matrix,
 input [63:0] epoch,frame_id,input [767:0] pose,input [2:0] pose_status,
 input [31:0] time_error_us,
 output reg result_valid,input result_ready,output reg [63:0] result_epoch,result_frame,
 output reg [191:0] matrix,output reg [3:0] status,
 output reg [31:0] calibration_id
);
 // Radian conversion uses round(pi / 180000 * 2^46), then rounds to Q30.
 // Legal local angle deltas are limited to +/-90 degrees before multiplication.
 localparam signed [31:0] RAD_PER_MDEG_Q46=32'sd1228166276;
 reg busy;reg [2:0] index;reg [1:0] phase;
 // Coefficients are consumed in order, so three shift banks replace wide
 // variable-index read muxes. The request still freezes every coefficient.
 reg [191:0] base_coefficients,pitch_coefficients,yaw_coefficients;
 reg [191:0] fallback,working;
 // The full signed33 subtraction/domain gate remains below. Only admitted
 // deltas in [-90000,90000] enter a busy calculation, so signed18 is exact.
 reg signed [17:0] dp,dy;reg signed [63:0] ap,ay;
 reg signed [31:0] pitch_q30,yaw_q30;
 reg signed [63:0] pitch_product,yaw_product;
 wire signed [31:0] pitch=$signed(pose[416+:32]),yaw=$signed(pose[448+:32]);
 wire signed [32:0] delta_p={pitch[31],pitch}-$signed({calibration[95],calibration[64+:32]});
 wire signed [32:0] delta_y={yaw[31],yaw}-$signed({calibration[127],calibration[96+:32]});
 wire layout_ok=calibration[7:0]<=1 && calibration[31:8]==0 && calibration[1023:960]==0 &&
  calibration[63:32]!=0 && calibration[351:320]!=0 && calibration[383:352]!=0 &&
  calibration[287:256]!=0 && calibration[319:288]!=0 && calibration[319:288]<=1000 &&
  $signed(calibration[128+:32])<=$signed(calibration[160+:32]) &&
  $signed(calibration[192+:32])<=$signed(calibration[224+:32]);
 wire in_domain=pitch>=$signed(calibration[128+:32]) && pitch<=$signed(calibration[160+:32]) &&
  yaw>=$signed(calibration[192+:32]) && yaw<=$signed(calibration[224+:32]) &&
  delta_p>=-90000 && delta_p<=90000 && delta_y>=-90000 && delta_y<=90000;
 wire signed [65:0] sum=($signed({{2{pitch_product[63]}},pitch_product})+$signed({{2{yaw_product[63]}},yaw_product})+66'sd536870912)>>>30;
 wire signed [65:0] coefficient=sum+$signed(base_coefficients[31:0]);
 assign request_ready=!busy && !result_valid;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   busy<=0;result_valid<=0;matrix<=0;
   index<=0;phase<=0;

   result_epoch<=0;result_frame<=0;status<=1;calibration_id<=0;
  end else if(clear)begin busy<=0;result_valid<=0;status<=1;end
  else begin
   if(result_valid && result_ready)result_valid<=0;
   if(request_valid && request_ready)begin
    result_epoch<=epoch;result_frame<=frame_id;matrix<=manual_matrix;
    calibration_id<=calibration[63:32];

    index<=0;phase<=0;
    if(!affine_enable || !calibration[0])begin status<=1;result_valid<=1;end
    // A source-owned config bank may prove the exact same entity layout at
    // atomic enqueue. Standalone users still perform every layout check here.
    // Pose freshness, MCU configuration version and domain checks remain live.
    else if(!CALIBRATION_PREVALIDATED && !layout_ok)begin status<=2;result_valid<=1;end
    // STATE byte 12 is config_version; byte 24 is the legacy IMU timestamp
    // and is zero in the encoder-only firmware. Never gate on that timestamp.
    else if(pose_status!=0 || time_error_us>calibration[319:288] || pose[96+:32]!=calibration[383:352])begin status<=3;result_valid<=1;end
    else if(!in_domain)begin status<=4;result_valid<=1;end
    else begin busy<=1;status<=0;end
   end else if(busy)begin
    case(phase)
     0:begin phase<=1;end
     1:begin phase<=2;end
     2:begin phase<=3;end
     3:begin
      if(coefficient>2147483647 || coefficient< -66'sd2147483648)begin
       matrix<=fallback;status<=5;busy<=0;result_valid<=1;
      end else begin
       // Six right shifts retain the original little-endian coefficient order
       // without a variable part-select write decoder and merge network.

       if(index==5)begin matrix<={coefficient[31:0],working[191:32]};busy<=0;result_valid<=1;end
       else begin

        index<=index+1'b1;phase<=2;
       end
      end
     end
    endcase
   end
  end
 end
 // Private operands are installed by an accepted request, then consumed
 // only by its busy phase. Clear/reset revoke busy before any stale operand
 // can reach a result. Six successful shifts fully replace working before
 // publication; public matrix/identity/status retain their original reset.
 always @(posedge clk) if(rst_n && !clear)begin
  if(request_valid && request_ready)begin
   fallback<=manual_matrix;base_coefficients<=calibration[384+:192];
   pitch_coefficients<=calibration[576+:192];yaw_coefficients<=calibration[768+:192];
   dp<=delta_p;dy<=delta_y;
  end else if(busy)begin
   case(phase)
    0:begin ap<=dp*RAD_PER_MDEG_Q46;ay<=dy*RAD_PER_MDEG_Q46;end
    1:begin pitch_q30<=(ap+32768)>>>16;yaw_q30<=(ay+32768)>>>16;end
    2:begin pitch_product<=$signed(pitch_coefficients[31:0])*pitch_q30;
     yaw_product<=$signed(yaw_coefficients[31:0])*yaw_q30;end
    3:if(coefficient<=2147483647 && coefficient>=-66'sd2147483648)begin
     working<={coefficient[31:0],working[191:32]};
     if(index!=5)begin
      base_coefficients<={32'b0,base_coefficients[191:32]};
      pitch_coefficients<={32'b0,pitch_coefficients[191:32]};
      yaw_coefficients<={32'b0,yaw_coefficients[191:32]};
     end
    end
   endcase
  end
 end
endmodule

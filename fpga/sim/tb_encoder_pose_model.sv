`timescale 1ns/1ps
// Actual F4 C-builder STATE bytes exercise selector -> calibrated pose model.
// The approved variant is explicitly synthetic; deployed firmware remains
// unapproved. No IMU data or IMU-valid flag is manufactured for either case.
module tb_encoder_pose_model;
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,sv=0,fv=0;reg [767:0] payload=0;reg [63:0] receive_us=999100,frame_id=1,exposure=1000000;
 wire fr,valid,mready,mvalid;wire [767:0] chosen;wire [2:0] selected_status;wire [31:0] timing_error;
 wire [63:0] selected_epoch,selected_frame,model_epoch,model_frame;wire [191:0] matrix;wire [3:0] model_status;
 reg [1023:0] calibration=0;reg [191:0] manual=192'h12345678;
 reg [7:0] encoder[0:105],stale[0:105];integer i;
 pose_frame_selector selector(.clk(clk),.rst_n(rst_n),.clear(1'b0),.state_valid(sv),.state_payload(payload),
  .receive_us(receive_us),.mapping_valid(1'b1),.clock_offset_us(64'sd0),.clock_error_us(32'd100),
  .sync_received_us(64'd999000),.frame_valid(fv),.frame_ready(fr),.epoch(64'd7),.frame_id(frame_id),.exposure_us(exposure),
  .result_valid(valid),.result_ready(mready),.result_epoch(selected_epoch),.result_frame(selected_frame),
  .result_state(chosen),.result_receive_us(),.age_us(),.error_us(timing_error),.status(selected_status),
  .invalid_states(),.overwrites(),.degraded_frames());
 pose_affine_model model(.clk(clk),.rst_n(rst_n),.clear(1'b0),.request_valid(valid),.request_ready(mready),
  .affine_enable(1'b1),.calibration(calibration),.manual_matrix(manual),.epoch(selected_epoch),.frame_id(selected_frame),
  .pose(chosen),.pose_status(selected_status),.time_error_us(timing_error),.result_valid(mvalid),.result_ready(1'b1),
  .result_epoch(model_epoch),.result_frame(model_frame),.matrix(matrix),.status(model_status),.calibration_id());
 task submit_and_select;begin
  @(negedge clk);sv=1;@(negedge clk);sv=0;wait(fr);@(negedge clk);fv=1;
  @(negedge clk);fv=0;wait(mvalid);#1;
  if(model_epoch!=7 || model_frame!=frame_id)$fatal(1,"pose source identity changed");
 end endtask
 initial begin
  $readmemh("source/sim/data/state_encoder.hex",encoder);
  $readmemh("source/sim/data/state_stale.hex",stale);
  for(i=0;i<96;i=i+1)payload[i*8+:8]=encoder[i+8];
  if(payload[24*8+:64]!=0 || payload[165] || payload[91*8+:8]!=5 || payload[93*8+:8]!=3 || payload[12*8+:32]!=1)
   $fatal(1,"actual encoder-only source fixture changed");
  calibration[7:0]=1;calibration[32+:32]=9;calibration[128+:32]=-30000;calibration[160+:32]=30000;
  calibration[192+:32]=-30000;calibration[224+:32]=30000;calibration[256+:32]=65536;
  calibration[288+:32]=1000;calibration[320+:32]=1;calibration[352+:32]=1;
  calibration[576+2*32+:32]=67108864;calibration[768+5*32+:32]=67108864;
  #21;rst_n=1;submit_and_select();
  if(selected_status!=4 || model_status!=3 || matrix!=manual)$fatal(1,"unapproved actual STATE did not degrade");
  // Explicit approval fixture ONLY: all original angles/source/time stay exact.
  wait(mready);payload[167]=1;receive_us=999200;frame_id=2;submit_and_select();
  if(selected_status!=0 || model_status!=0 || $signed(matrix[64+:32])<11712704 || $signed(matrix[64+:32])>11712708 ||
      $signed(matrix[160+:32])< -23425415 || $signed(matrix[160+:32])> -23425411)
   $fatal(1,"approved encoder-only model failed status%0d px%0d yaw%0d",model_status,$signed(matrix[64+:32]),$signed(matrix[160+:32]));
  wait(mready);for(i=0;i<96;i=i+1)payload[i*8+:8]=stale[i+8];
  receive_us=1000100;frame_id=3;exposure=1000500;submit_and_select();
  if(selected_status!=4 || model_status!=3 || matrix!=manual)$fatal(1,"stale latest STATE reused prior good pose");
  $display("PASS actual encoder-only STATE -> selector -> pose: unapproved, explicit synthetic approval, stale rejection");$finish;
 end
 initial begin #100000;$fatal(1,"timeout");end
endmodule

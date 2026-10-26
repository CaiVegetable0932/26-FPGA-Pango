`timescale 1ns/1ps
// Cycle-for-cycle comparison against the frozen pre-optimization model.
// Random coefficients, fallback paths, changing live inputs and stalled result
// acceptance prove that ordered storage keeps arithmetic and identity intact.
module tb_pose_storage_equivalence #(parameter PREVALIDATED=0);
 reg clk=0;always #5 clk=~clk;
 reg rst_n=0,clear=0,request_valid=0,result_ready=1,enabled=1;
 reg [1023:0] calibration=0;reg [767:0] pose=0;reg [191:0] manual=0;
 reg [63:0] epoch=0,frame_id=0;reg [2:0] pose_status=0;reg [31:0] error_us=100;
 wire ready,new_ready,valid,new_valid;wire [191:0] matrix,new_matrix;
 wire [63:0] out_epoch,new_epoch,out_frame,new_frame;
 wire [31:0] cal_id,new_cal_id;wire [3:0] status,new_status;
 pose_affine_model_before reference_model(.clk(clk),.rst_n(rst_n),.clear(clear),
  .request_valid(request_valid),.request_ready(ready),.affine_enable(enabled),
  .calibration(calibration),.manual_matrix(manual),.epoch(epoch),.frame_id(frame_id),
  .pose(pose),.pose_status(pose_status),.time_error_us(error_us),
  .result_valid(valid),.result_ready(result_ready),.result_epoch(out_epoch),
  .result_frame(out_frame),.matrix(matrix),.status(status),.calibration_id(cal_id));
 pose_affine_model #(.CALIBRATION_PREVALIDATED(PREVALIDATED)) candidate(.clk(clk),.rst_n(rst_n),.clear(clear),
  .request_valid(request_valid),.request_ready(new_ready),.affine_enable(enabled),
  .calibration(calibration),.manual_matrix(manual),.epoch(epoch),.frame_id(frame_id),
  .pose(pose),.pose_status(pose_status),.time_error_us(error_us),
  .result_valid(new_valid),.result_ready(result_ready),.result_epoch(new_epoch),
  .result_frame(new_frame),.matrix(new_matrix),.status(new_status),.calibration_id(new_cal_id));
 integer trial,n,cycles=0;integer seed=32'h51a7beef;
 // Every public output, including request/result timing, must remain identical.
 always @(negedge clk)if(rst_n)begin
  cycles=cycles+1;
  if({ready,valid,matrix,out_epoch,out_frame,status,cal_id}!==
     {new_ready,new_valid,new_matrix,new_epoch,new_frame,new_status,new_cal_id})
   $fatal(1,"pose storage mismatch trial=%0d cycle=%0d",trial,cycles);
 end
 task configure;
  begin
   calibration=0;calibration[0]=1;calibration[63:32]=trial+1;
   calibration[128+:32]=-90000;calibration[160+:32]=90000;
   calibration[192+:32]=-90000;calibration[224+:32]=90000;
   calibration[256+:32]=65536;calibration[288+:32]=1000;
   calibration[320+:32]=1;calibration[352+:32]=17;
   for(n=0;n<6;n=n+1)begin
    calibration[384+n*32+:32]=$random(seed);
    calibration[576+n*32+:32]=$random(seed);
    calibration[768+n*32+:32]=$random(seed);
    manual[n*32+:32]=$random(seed);
   end
   pose=0;pose[96+:32]=17;
   pose[416+:32]=$signed($random(seed))%90001;
   pose[448+:32]=$signed($random(seed))%90001;
   epoch=trial/3+1;frame_id=trial+100;enabled=1;pose_status=0;error_us=100;
   case(trial%16)
    0:enabled=0;
    1:calibration[0]=0;
    2:if(!PREVALIDATED)calibration[1000]=1;
    3:pose_status=4;
    4:error_us=1001;
    5:pose[96+:32]=18;
    6:pose[416+:32]=90001;
    7:if(!PREVALIDATED)calibration[128+:32]=90001;
   endcase
  end
 endtask
 initial begin
  #21;rst_n=1;
  for(trial=0;trial<256;trial=trial+1)begin
   wait(ready);@(negedge clk);configure();request_valid=1;result_ready=0;
   @(negedge clk);request_valid=0;
   // A newly published config and another source frame must not alter an
   // accepted request. Busy requests are ignored equally by both versions.
   calibration=~calibration;pose=~pose;manual=~manual;epoch=~epoch;frame_id=~frame_id;
   if(trial%16==15)begin
    repeat(4)@(negedge clk);clear=1;@(negedge clk);clear=0;
   end else begin
    wait(valid);repeat(3)@(negedge clk);result_ready=1;
   end
   @(negedge clk);
  end
  $display("PASS pose storage equivalence: 256 requests, frozen inputs, overflow/fallback, clear and backpressure");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule

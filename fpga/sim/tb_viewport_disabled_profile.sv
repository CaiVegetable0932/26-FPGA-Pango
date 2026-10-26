`timescale 1ns/1ps
// C6-off profile keeps source-owned manual/pose matrices and the original job
// contract. Synthetic selector outputs isolate this test from UART transport;
// the real pose model still evaluates the uploaded calibration and time gate.
module tb_viewport_disabled_profile;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,submit_valid=0,capture_admit=0,capture_enable=0,source_start=0;
 reg mcu_enable=0,job_request=0,job_accept=0;
 reg [15:0] submit_kind=5,read_kind=5;reg [31:0] submit_version=1;
 reg [1023:0] entity=0;wire [7:0] submit_code;wire [2303:0] read_status;
 reg [1:0] source_slot=0,job_slot=0;reg [63:0] capture_frame=0,job_frame=0,job_epoch=7;
 reg [447:0] capture_geometry=0,job_original=0;wire prepared_valid;
 wire [447:0] prepared_geometry;wire [3:0] pose_status,motion_status;wire [31:0] missed;
 wire [127:0] versions;reg [191:0] manual_matrix,base_matrix,expected_matrix;
 reg [767:0] selected_pose=0;reg [2:0] selected_status=0;
 reg [63:0] selected_frame=0;integer checks=0;
 source_motion_controller #(.SUPPORT_VIEWPORT(0)) dut(
  .clk(clk),.rst_n(rst_n),.now_us(64'd0),.runtime_motion_reset(1'b0),.runtime_history_clear(1'b0),
  .submit_valid(submit_valid),.submit_kind(submit_kind),.submit_entity(entity),.submit_version(submit_version),
  .submit_id(32'd9),.submit_code(submit_code),.read_kind(read_kind),.read_status(read_status),
  .capture_admit(capture_admit),.capture_epoch(64'd7),.capture_frame(capture_frame),.capture_exposure(64'd1000),
  .capture_enable(capture_enable),.capture_geometry(capture_geometry),.source_start(source_start),.source_slot(source_slot),
  .mcu_enable(mcu_enable),.mcu_rx_valid(1'b0),.mcu_rx_data(8'd0),.mcu_rx_error(1'b0),.mcu_tx_ready(1'b1),
  .mcu_timing_valid(1'b0),.mcu_capture_error(32'd0),.mcu_config_approved(1'b0),.mcu_new_session(32'd0),
  .mcu_config_ready(1'b0),.mcu_event_ready(1'b0),.job_request(job_request),.job_slot(job_slot),
  .job_epoch(job_epoch),.job_frame(job_frame),.job_original(job_original),.job_accept(job_accept),
  .prepared_valid(prepared_valid),.prepared_geometry(prepared_geometry),.prepared_pose_status(pose_status),
  .prepared_motion_status(motion_status),.missed_results(missed),.job_entity_versions(versions));
 task check(input logic condition,input string text);
  begin checks=checks+1;if(condition!==1)$fatal(1,"VIEWPORT_OFF %s",text);end
 endtask
 task admit(input integer slot,input integer frame_no,input logic enable_affine,input logic enable_mcu);
  begin
   @(negedge clk);source_slot=slot;capture_frame=frame_no;capture_enable=enable_affine;mcu_enable=enable_mcu;
   capture_geometry={{8{32'hcafebabe}},manual_matrix};capture_admit=1;
   @(negedge clk);capture_admit=0;source_start=1;@(negedge clk);source_start=0;
  end
 endtask
 task run_job(input integer slot,input integer frame_no,input [191:0] expected,input [3:0] expected_status);
  reg [447:0] held;
  begin
   @(negedge clk);job_slot=slot;job_epoch=7;job_frame=frame_no;
   job_original={{8{32'h13579bdf}},192'h123456789abcdef};job_request=1;
   wait(prepared_valid);#1;
   check(prepared_geometry=={{8{32'h13579bdf}},expected},"manual/pose matrix or upper lens fields changed");
   check(pose_status==expected_status && motion_status==8,"fallback or C4 status changed");
   check(versions[63:32]==0,"withdrawn viewport version leaked");
   held=prepared_geometry;
   repeat(8)begin @(negedge clk);job_original=~job_original;capture_geometry=~capture_geometry;
    #1;check(prepared_valid && prepared_geometry==held,"prepared result changed under backpressure");end
   @(negedge clk);job_accept=1;@(negedge clk);job_accept=0;job_request=0;
   #1;check(!prepared_valid,"job_accept did not consume result");
  end
 endtask
 task inject_pose(input integer frame_no,input [2:0] selection_status);
  begin
   @(negedge clk);selected_frame=frame_no;selected_status=selection_status;
   force dut.selected_epoch=64'd7;force dut.selected_frame=selected_frame;
   force dut.selected_pose=selected_pose;force dut.selected_status=selected_status;
   force dut.selected_error=32'd100;force dut.selected_valid=1'b1;
   wait(dut.selected_ready);@(posedge clk);@(negedge clk);
   release dut.selected_valid;release dut.selected_epoch;release dut.selected_frame;
   release dut.selected_pose;release dut.selected_status;release dut.selected_error;
   wait(dut.pose_ready[source_slot]);
  end
 endtask
 initial begin
  manual_matrix={32'h87654321,32'h01234567,32'hffeeddcc,32'h12345678,32'hf0123456,32'h23456789};
  base_matrix=0;base_matrix[31:0]=67108864;base_matrix[159:128]=67108864;base_matrix[95:64]=12345;
  repeat(4)@(negedge clk);rst_n=1;
  // Both valid and invalid kind5 uploads are explicitly unsupported, rather
  // than accepted as unity. Readback is an absent entity with error 6.
  entity=0;entity[7:0]=1;entity[63:32]=131072;entity[95:64]=131072;
  entity[127:96]=1;entity[191:160]=16384;
  #1;check(submit_code==6 && read_status[127:120]==6 && read_status[119:112]==0 &&
           read_status[111:32]==0 && read_status[2303:128]==0,"kind5 capability withdrawal");
  submit_valid=1;@(negedge clk);submit_valid=0;entity='1;#1;check(submit_code==6,"invalid kind5 returned non-capability error");
  check(dut.cfg_v[63:32]==65536 && dut.cfg_v[95:64]==65536 && dut.cfg_v[7:0]==0,"capture crop not fixed unity");
  admit(0,1,0,0);run_job(0,1,manual_matrix,3);
  admit(1,2,1,0);run_job(1,2,manual_matrix,3);
  // C3 remains enabled and evaluates an actual accepted kind8 calibration.
  @(negedge clk);submit_kind=8;read_kind=8;entity=0;entity[0]=1;entity[63:32]=9;
  entity[128+:32]=-90000;entity[160+:32]=90000;entity[192+:32]=-90000;entity[224+:32]=90000;
  entity[256+:32]=65536;entity[288+:32]=1000;entity[320+:32]=1;entity[352+:32]=17;
  entity[384+:192]=base_matrix;entity[576+2*32+:32]=67108864;
  #1;check(submit_code==0,"C3 calibration unavailable in C6-off profile");
  submit_valid=1;@(negedge clk);submit_valid=0;admit(2,3,1,1);
  selected_pose=0;selected_pose[96+:32]=17;selected_pose[416+:32]=1000;inject_pose(3,0);
  expected_matrix=base_matrix;expected_matrix[95:64]=1183616;
  // Numerical result is exactly the existing rounded Q46 -> Q30 -> Q26 path.
  run_job(2,3,expected_matrix,0);
  admit(0,4,1,1);inject_pose(4,3);run_job(0,4,manual_matrix,3);
  // Wrong epoch/frame cannot consume a slot even when it has a ready pose.
  @(negedge clk);job_slot=0;job_epoch=8;job_frame=4;job_request=1;
  repeat(20)@(negedge clk);check(!prepared_valid,"cross-epoch job prepared");job_request=0;
  // The original 65535-cycle timeout still uses job_original, not another
  // slot's completed pose; no synthetic pose validity is manufactured.
  admit(1,5,1,1);run_job(1,5,192'h123456789abcdef,6);
  check(missed==1,"pose timeout accounting changed");
  $display("VIEWPORT_DISABLED_PROFILE_PASS checks=%0d",checks);$finish;
 end
 initial begin #2000000;$fatal(1,"VIEWPORT_OFF_TIMEOUT");end
endmodule

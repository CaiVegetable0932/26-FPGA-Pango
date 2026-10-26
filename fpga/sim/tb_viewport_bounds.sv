`timescale 1ns/1ps
// Real entity/capture/job interfaces prove changing hard viewport bounds wins
// without a visual trajectory. Legacy dynamic uploads must fail explicitly.
module tb_viewport_bounds;
 reg clk=0;always #5 clk=~clk;reg rst_n=0,submit=0,admit=0,start=0,job=0,accept=0;
 reg [1023:0] entity=0;reg [31:0] version=1;reg [63:0] frame=1;reg [447:0] geometry=0;
 wire [7:0] code;wire prepared;wire [447:0] result;
 source_motion_controller #(.WIDTH(64),.HEIGHT(36)) dut(.clk(clk),.rst_n(rst_n),.now_us(64'd100),
  .runtime_motion_reset(1'b0),.runtime_history_clear(1'b0),.submit_valid(submit),.submit_kind(16'd5),
  .submit_entity(entity),.submit_version(version),.submit_id(version),.submit_code(code),.read_kind(16'd5),.read_status(),
  .capture_admit(admit),.capture_epoch(64'd2),.capture_frame(frame),.capture_exposure(64'd100),.capture_enable(1'b1),.capture_geometry(geometry),
  .source_start(start),.source_slot(2'd0),
  .mcu_enable(1'b0),.mcu_rx_valid(1'b0),.mcu_rx_data(8'd0),.mcu_rx_error(1'b0),.mcu_tx_valid(),.mcu_tx_ready(1'b0),.mcu_tx_data(),
  .mcu_timing_valid(1'b0),.mcu_capture_error(32'd0),.mcu_config_approved(1'b0),.mcu_new_session(32'd0),
  .mcu_config_valid(),.mcu_config_entity(),.mcu_config_version(),.mcu_config_ready(1'b0),.mcu_reopen_required(),
  .mcu_event_valid(),.mcu_event_payload(),.mcu_event_ready(1'b0),
  .job_request(job),.job_slot(2'd0),.job_epoch(64'd2),.job_frame(frame),.job_original(geometry),.job_accept(accept),
  .prepared_valid(prepared),.prepared_geometry(result),.prepared_pose_status(),.prepared_motion_status(),.missed_results(),
  .job_completion_config(),.job_registration_version(),.job_motion_dx_q16(),.job_motion_dy_q16(),.job_motion_confidence(),
  .history_capture_enable(),.history_clear(),.job_history_registration_ok(),.job_entity_versions());
 task run_frame;begin
  @(negedge clk);#1;if(code!=0)$fatal(1,"viewport entity rejected");submit=1;
  @(negedge clk);submit=0;admit=1;@(negedge clk);admit=0;start=1;
  @(negedge clk);start=0;job=1;wait(prepared);#1;
  if(frame==1 && result[31:0]!=32'd1048576)$fatal(1,"fixed zoom reference not established");
  if(frame==2 && result[191:0]!=geometry[191:0])$fatal(1,"slew escaped newly narrowed max zoom: coefficient %0d",result[31:0]);
  if(frame==3 && result[31:0]!=32'd1048576)$fatal(1,"slew escaped newly increased min zoom");
  @(negedge clk);job=0;accept=1;@(negedge clk);accept=0;
 end endtask
 initial begin
  geometry[31:0]=2097152;geometry[159:128]=2097152;
  geometry[351:320]=2097152;geometry[383:352]=2097152;geometry[415:384]=63*32768;geometry[447:416]=35*32768;
  entity[7:0]=1;entity[63:32]=131072;entity[95:64]=131072;entity[127:96]=1024;entity[159:128]=1024;entity[191:160]=16384;
  #21;rst_n=1;run_frame();
  // A rejected dynamic request cannot replace the prior admitted fixed crop.
  entity[7:0]=2;#1;if(code!=6)$fatal(1,"dynamic crop not explicitly unsupported");
  @(negedge clk);submit=1;@(negedge clk);submit=0;
  frame=2;version=2;entity[7:0]=1;entity[63:32]=65536;entity[95:64]=65536;run_frame();
  frame=3;version=3;entity[63:32]=131072;entity[95:64]=131072;run_frame();
  $display("PASS fixed viewport bounds/source atomicity + dynamic unsupported after C4 withdrawal");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule

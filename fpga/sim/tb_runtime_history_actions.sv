`timescale 1ns/1ps
import frame_manager_pkg::*;
// Exercise real pool HISTORY references with independent writer/job fences.
// Native pixel DMA is intentionally outside this ownership-only fixture.
module tb_runtime_history_actions;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 wire [3*CMD_BITS-1:0] command;wire [3*RSP_BITS-1:0] response;
 reg capture_valid=0,capture_end=0,writer_done=0;
 wire capture_ready,capture_complete,geometry_valid;reg geometry_ready=0,geometry_done=0,geometry_failed=0;
 reg history_capture_enable=1;wire history_clear,motion_clear;
 reg action_valid=0;reg [15:0] action=4,action_seq=51;wire [7:0] action_code;wire [319:0] action_status;
 frame_runtime_actions actions(.clk(clk),.rst_n(rst_n),.submit_valid(action_valid),.action(action),.request_seq(action_seq),.submit_code(action_code),
  .capture_boundary(capture_valid && capture_ready),.epoch(meta.epoch),.frame_id(meta.frame_id),
  .clear_motion(motion_clear),.clear_history(history_clear),.status_extension(action_status));
 wire history_valid;wire [1:0] history_slot;wire [31:0] history_gen,history_base,history_skipped;
 wire [META_BITS-1:0] history_metadata;frame_meta_t meta,history_meta;assign history_meta=history_metadata;
 wire display_offer;wire [1:0] display_slot;wire [31:0] display_gen;
 frame_rsp_t source_response;assign source_response=response[0+:RSP_BITS];
 wire raw_offer;wire [31:0] captured,processed,failed;
 frame_manager pools(.clk(clk),.reset_n(rst_n),.fabric_ready(1'b1),.display_boundary(1'b1),.command(command),.response(response));
 video_frame_scheduler dut(.clk(clk),.rst_n(rst_n),.fabric_ready(1'b1),.command(command),.response(response),
  .capture_valid(capture_valid),.capture_ready(capture_ready),.capture_metadata(meta),
  .capture_end(capture_end),.capture_isp_legal(1'b1),.capture_raw_legal(1'b1),.capture_last(64'd100),.capture_errors(32'd0),
  .capture_queues_drained(1'b1),.capture_complete(capture_complete),.isp_done(writer_done),.isp_failed(1'b0),.raw_done(writer_done),.raw_failed(1'b0),
  .history_capture_enable(history_capture_enable),.history_clear(history_clear),.history_valid(history_valid),.history_slot(history_slot),
  .history_gen(history_gen),.history_base(history_base),.history_metadata(history_metadata),.history_skipped(history_skipped),
  .geometry_valid(geometry_valid),.geometry_ready(geometry_ready),.geometry_done(geometry_done),.geometry_failed(geometry_failed),
  .raw_export_ready(1'b1),.raw_export_valid(raw_offer),.raw_export_release(raw_offer),
  .display_request(1'b1),.display_offer_valid(display_offer),.display_offer_ready(1'b1),
  .display_slot(display_slot),.display_gen(display_gen),.display_release(display_offer),.display_release_slot(display_slot),.display_release_gen(display_gen),
  .captured_frames(captured),.processed_frames(processed),.failed_processing_frames(failed));
 task tick;begin @(posedge clk);#1;end endtask
 task capture(input integer id);
  begin @(negedge clk);meta.frame_id=id;capture_valid=1;wait(capture_ready);tick;@(negedge clk);capture_valid=0;
   capture_end=1;writer_done=1;wait(capture_complete);@(negedge clk);capture_end=0;writer_done=0;
   wait(geometry_valid);@(negedge clk);
  end
 endtask
 task start_job;begin geometry_ready=1;tick;@(negedge clk);geometry_ready=0;repeat(5)tick;end endtask
 task finish_job;
  begin @(negedge clk);geometry_done=1;tick;@(negedge clk);geometry_done=0;
   wait(dut.geometry_state==0);repeat(5)tick;
  end
 endtask
 // Capture three while job two is active. This produces a REAL admitted
 // source boundary for A5, and the old HISTORY DMA reference must stay pinned.
 task capture_during_job(input integer id);
  begin @(negedge clk);meta.frame_id=id;capture_valid=1;wait(capture_ready);tick;@(negedge clk);capture_valid=0;
   capture_end=1;writer_done=1;wait(capture_complete);@(negedge clk);capture_end=0;writer_done=0;
  end
 endtask
 initial begin
  meta='0;meta.epoch=64'h123456789;meta.width=4;meta.height=4;meta.isp_version=1;meta.enhancement_version=1;meta.calibration_entity=1;
  repeat(4)tick;rst_n=1;repeat(4)tick;
  capture(1);start_job;finish_job;
  if(!dut.history_held || history_meta.frame_id!=1)$fatal(1,"first source was not retained");
  capture(2);if(!history_valid || history_meta.frame_id!=1)$fatal(1,"consecutive history missing");start_job;
  @(negedge clk);action_valid=1;#1;if(action_code!=0)$fatal(1,"clear action rejected");
  @(negedge clk);action_valid=0;repeat(3)tick;
  if(!dut.history_held || action_status[7:0]!=2 || history_clear)$fatal(1,"queued action altered running job");
  capture_during_job(3);repeat(3)tick;
  if(action_status[15:8]!=4 || action_status[128+:64]!=3 || action_status[192+:16]!=51)$fatal(1,"action source apply boundary incorrect");
  if(!dut.history_held || !pools.banks[0].pool.refs[history_slot][HISTORY])$fatal(1,"action released in-flight history");
  finish_job;
  // The next descriptor may already be queued, but it must not reuse the
  // reference cleared at its acquisition boundary.
  wait(geometry_valid);@(negedge clk);if(history_valid)$fatal(1,"cleared history reached next job");start_job;finish_job;
  if(!dut.history_held || history_meta.frame_id!=3)$fatal(1,"history did not reestablish from new real S1");
  // Exact completed retry must not clear the re-established history again.
  @(negedge clk);action_valid=1;#1;if(action_code!=0)$fatal(1,"completed retry rejected");@(negedge clk);action_valid=0;
  capture(4);if(!history_valid || history_meta.frame_id!=3)$fatal(1,"completed retry ran twice");start_job;
  geometry_failed=1;finish_job;geometry_failed=0;
  repeat(10)tick;if(dut.history_held || source_response.occupied!=0)$fatal(1,"action/failed job leaked SRC");
  $display("PASS runtime clear real-source-boundary/in-flight HISTORY retention/drain/retry/no-leak");$finish;
 end
 initial begin #200000;$fatal(1,"history scheduler timeout state=%0d",dut.geometry_state);end
endmodule

`timescale 1ns/1ps
// Isolated 125MHz PDS fixture for MCU UART/client, full state queue, frame lock,
// parameter entity guard/bank. Serial fixture loading is not a new PC protocol.
// Full entities remain observable through reduction to prevent dead-data pruning.
module control_timing_top(
 input clk,input rst_n,input rx,enable,config_approved,timing_bound_valid,frame_boundary,
 input cfg_shift,input [7:0] cfg_byte,input submit,input format_supported,
 output tx,output [31:0] observe
);
 reg [511:0] cfg;
 reg [6:0] tick_div;reg [63:0] now_us,frame_id;reg [31:0] new_session;
 wire rx_valid,framing_error,tx_valid,tx_ready;wire [7:0] rx_data,tx_byte;
 wire session_valid,reopen_required,config_valid,state_valid,event_valid,mapping_valid;
 wire [63:0] boot_id,state_receive_us,sync_received_us;wire [31:0] session_id,config_version,clock_error_us;
 wire signed [63:0] clock_offset_us;wire [767:0] state_payload,result_state;
 wire [2111:0] config_entity;wire [319:0] event_payload;
 wire result_valid;wire [2:0] status;wire [31:0] age_us,error_us;
 wire [31:0] bad_crc,bad_header,timeouts,overflows,rejected_states,rejected_replies,reconnects,event_drops;
 wire guard_ready,guard_result,guard_validated,bank_ready,applied;
 wire [511:0] guard_entity,active_entity;wire [1:0] reject_reason;wire [31:0] active_version,active_id;
 always @(posedge clk) if(cfg_shift) cfg<={cfg[503:0],cfg_byte};
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin tick_div<=0;now_us<=0;frame_id<=0;new_session<=1;end
  else begin
   if(tick_div==124) begin tick_div<=0;now_us<=now_us+1'b1;end else tick_div<=tick_div+1'b1;
   if(frame_boundary) frame_id<=frame_id+1'b1;
   if(reopen_required) new_session<=new_session+1'b1;
  end
 end
 uart_8n1 uart(.clk(clk),.rst_n(rst_n),.rx(rx),.tx(tx),.rx_valid(rx_valid),.rx_data(rx_data),
  .framing_error(framing_error),.tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_byte));
 mcu_readonly_client client(.clk(clk),.rst_n(rst_n),.now_us(now_us),.enable(enable),.new_session(new_session),
  .rx_valid(rx_valid),.rx_data(rx_data),.rx_error(framing_error),.timing_bound_valid(timing_bound_valid),.capture_error_us(cfg[0+:32]),
  .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_byte),.session_valid(session_valid),.boot_id(boot_id),.session_id(session_id),
  .reopen_required(reopen_required),.config_valid(config_valid),.config_ready(1'b1),.config_approved(config_approved),
  .config_entity(config_entity),.config_version(config_version),.state_valid(state_valid),.state_payload(state_payload),.state_receive_us(state_receive_us),
  .event_valid(event_valid),.event_ready(1'b1),.event_payload(event_payload),.mapping_valid(mapping_valid),.clock_offset_us(clock_offset_us),
  .clock_error_us(clock_error_us),.sync_received_us(sync_received_us),.bad_crc(bad_crc),.bad_header(bad_header),.timeouts(timeouts),
  .overflows(overflows),.rejected_states(rejected_states),.rejected_replies(rejected_replies),.reconnects(reconnects),.event_drops(event_drops));
 pose_frame_selector selector(.clk(clk),.rst_n(rst_n),.clear(!session_valid),.state_valid(state_valid),.state_payload(state_payload),
  .receive_us(state_receive_us),.mapping_valid(mapping_valid),.clock_offset_us(clock_offset_us),.clock_error_us(clock_error_us),.sync_received_us(sync_received_us),
  .frame_valid(frame_boundary),.frame_ready(),.epoch(cfg[64+:64]),.frame_id(frame_id),.exposure_us(now_us),
  .result_valid(result_valid),.result_ready(1'b1),.result_epoch(),.result_frame(),.result_state(result_state),.result_receive_us(),
  .age_us(age_us),.error_us(error_us),.status(status),.invalid_states(),.overwrites(),.degraded_frames());
 parameter_entity_guard guard(.clk(clk),.rst_n(rst_n),.submit_valid(submit),.submit_ready(guard_ready),.entity(cfg),
  .lower_bounds({16{32'hc0000000}}),.upper_bounds({16{32'h3fffffff}}),.expected_crc(cfg[480+:32]),.format_supported(format_supported),
  .result_valid(guard_result),.result_ready(bank_ready),.validated(guard_validated),.result_entity(guard_entity),.reject_reason(reject_reason));
 frame_parameter_bank bank(.clk(clk),.rst_n(rst_n),.submit_valid(guard_result),.submit_ready(bank_ready),.entity_validated(guard_validated),
  .entity(guard_entity),.version(cfg[448+:32]),.entity_id(cfg[416+:32]),.received(),.validated(),.rejected(),
  .capture_boundary(frame_boundary),.epoch(cfg[64+:64]),.frame_id(frame_id),.active_entity(active_entity),.active_version(active_version),.active_entity_id(active_id),
  .applied(applied),.applied_ready(1'b1),.applied_epoch(),.applied_frame(),.pending());
 assign observe=bad_crc^bad_header^timeouts^overflows^rejected_states^rejected_replies^reconnects^event_drops^age_us^error_us^active_version^active_id^
  {20'd0,(^config_entity),(^event_payload),(^result_state),(^active_entity),session_valid,mapping_valid,result_valid,applied,status,config_valid};
endmodule

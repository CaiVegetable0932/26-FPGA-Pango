`timescale 1ns/1ps
// MCU_POSE_V2 independent FPGA link, byte ports connect ONLY to MCU UART.
// GET_INFO(profile) -> OPEN -> GET_CONFIG(entity) -> SET_STREAM -> SYNC.
// One request, seq 1..65535 without wrap, two exact retries, 200ms deadline.
// No opcode for movement/HOME/zero/heartbeat is emitted. STATE is dispatched
// independently of transactions. Full configuration is externally archived;
// the consumer approves either its retained bytes or the complete streamed
// digest before high-frequency state is admitted.
module mcu_readonly_client #(
 parameter BAUD=460800,REQUEST_TIMEOUT_US=200000,SYNC_INTERVAL_US=1000000,
 parameter CONFIG_DIGEST_ONLY=0
)(
 input clk,input rst_n,input [63:0] now_us,input enable,input [31:0] new_session,
 input rx_valid,input [7:0] rx_data,input rx_error,
 input timing_bound_valid,input [31:0] capture_error_us,
 output tx_valid,input tx_ready,output [7:0] tx_data,
 output reg session_valid,output reg [63:0] boot_id,output reg [31:0] session_id,
 output reg reopen_required,
 output reg config_valid,input config_ready,input config_approved,
 output reg [2111:0] config_entity,output reg [31:0] config_version,config_crc32,
 output reg state_valid,output reg [767:0] state_payload,output reg [63:0] state_receive_us,
 output reg event_valid,input event_ready,output reg [319:0] event_payload,
 output reg mapping_valid,output reg signed [63:0] clock_offset_us,
 output reg [31:0] clock_error_us,output reg [63:0] sync_received_us,
 output [31:0] bad_crc,bad_header,timeouts,overflows,
 output reg [31:0] rejected_states,rejected_replies,reconnects,event_drops
);
 // Exact modulo-width arithmetic is unchanged; ask installed ADS to use
 // available APM add/sub resources instead of LUT carry chains. This adds no
 // RTL stages. Native resource and timing results decide whether to retain it.
 wire [63:0] request_elapsed_apm /* synthesis syn_dspstyle="block_mult" */ = now_us-request_start;
 wire [63:0] sync_elapsed_apm /* synthesis syn_dspstyle="block_mult" */ = now_us-sync_received_us;
 wire [63:0] next_sync_apm /* synthesis syn_dspstyle="block_mult" */ = now_us+SYNC_INTERVAL_US;
 wire [63:0] sync_a_base_apm /* synthesis syn_dspstyle="block_mult" */ = sync_t1+REQUEST_LINE_US;
 wire [63:0] sync_b_base_apm /* synthesis syn_dspstyle="block_mult" */ = sync_t4-REPLY_LINE_US;
 wire [63:0] sync_a_apm /* synthesis syn_dspstyle="block_mult" */ = sync_a_base-$signed(sync_t2);
 wire [63:0] sync_b_apm /* synthesis syn_dspstyle="block_mult" */ = sync_b_base-$signed(sync_t3);
 wire [63:0] sync_rtt_apm /* synthesis syn_dspstyle="block_mult" */ = sync_b-sync_a;
 wire [63:0] sync_average_apm /* synthesis syn_dspstyle="block_mult" */ = (sync_a>>>1)+(sync_b>>>1)+(sync_a[0] && sync_b[0]);
 localparam INFO=0,OPEN=1,CONFIG=2,STREAM=3,RUN=4;
 localparam REQUEST_LINE_US=(34*10000000+BAUD-1)/BAUD;
 localparam REPLY_LINE_US=(50*10000000+BAUD-1)/BAUD;
 reg [2:0] phase;
 reg pending,tx_active,first_send,collecting,read_wait,process_packet;
 reg [7:0] request_cmd;
 reg [15:0] request_seq,next_seq;
 reg [5:0] request_length;
 reg [191:0] request_payload;
 reg [6:0] tx_pos;
 reg [15:0] tx_crc;
 reg [1:0] retries;
 reg [63:0] request_start,next_sync,t1;
 reg [31:0] sync_id,last_sample,last_event,ack_target;
 reg have_sample;
 reg [2:0] sync_step;
 reg [63:0] sync_t1,sync_t2,sync_t3,sync_t4;
 reg signed [63:0] sync_a_base,sync_b_base,sync_a,sync_b,sync_rtt,sync_offset;
 reg [31:0] sync_capture_error;reg sync_eligible;
 reg state_decision_pending,state_context_valid,state_new_config,state_had_sample;
 reg [63:0] state_time;
 reg [31:0] state_delta;
 wire [13:0] sync_abs_rtt=sync_rtt[63] ? -sync_rtt[13:0] : sync_rtt[13:0];
 // STATE is the largest decision payload (96B). GET_CONFIG's 264B entity
 // streams directly into its held consumer bank, avoiding a second 280B copy.
 wire [767:0] received;
 reg [9:0] read_index;
 wire packet_valid,packet_revoked,read_response;
 wire [7:0] packet_cmd,read_data;wire [15:0] packet_seq,packet_length;
 wire [63:0] receive_time;
 // A synchronous read response can outlive the parser's HOLD by one edge.
 // Also fence the very edge that loses a UART byte or overflows the ring;
 // neither a last-byte response nor process_packet may revive that borrow.
 wire borrow_live=packet_valid && !packet_revoked;
 wire read_valid=collecting && !read_wait && borrow_live;
 // Decode byte writes into fixed lanes. The packet-wide variable part-select
 // otherwise synthesizes a wide merge network for a single received byte.
 // Clear on borrow exactly as before, so short packets cannot retain old tails.
 genvar receive_byte;
 generate for(receive_byte=0;receive_byte<96;receive_byte=receive_byte+1)begin:receive_bytes
  reg [7:0] value;
  assign received[receive_byte*8+:8]=value;
  always @(posedge clk or negedge rst_n)
   if(!rst_n)value<=0;
   else if(borrow_live && !collecting && !process_packet && packet_length<=280)value<=0;
   else if(collecting && borrow_live && read_response && read_index==receive_byte)value<=read_data;
 end endgenerate
 // The parser has checked the whole wire CRC before lending the packet.
 // Read its 16B response header first, then write config bytes only for the
 // outstanding command/sequence/boot/session. Never touch an entity already
 // held valid for approval. Partial/aborted reads stay unpublished.
 wire collecting_config=collecting && borrow_live && read_response && enable &&
   new_session==session_id && !reopen_required && !config_valid &&
   packet_length==280 && response_ok && request_cmd==8'h42 && context_ok;
 // Board policy consumes the digest of every byte, not a parallel entity bus.
 // Full-entity mode remains available for offline/other consumers. Both modes
 // calculate the same digest before config_valid and keep it until approval.
 reg [31:0] collecting_crc;
 function [31:0] config_crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer j;begin v=c^b;for(j=0;j<8;j=j+1)v=(v>>1)^(v[0]?32'hedb88320:0);config_crc_byte=v;end
 endfunction
 wire [31:0] next_config_crc=config_crc_byte(collecting_crc,read_data);
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin collecting_crc<=32'hffffffff;config_crc32<=0;end
  else if(borrow_live && !collecting && !process_packet)collecting_crc<=32'hffffffff;
  else if(collecting_config && read_index>=16)begin
   collecting_crc<=next_config_crc;
   if(read_index==279)config_crc32<=~next_config_crc;
  end
 genvar config_byte;
 generate if(!CONFIG_DIGEST_ONLY)begin:full_config
 for(config_byte=0;config_byte<264;config_byte=config_byte+1)begin:config_bytes
  always @(posedge clk or negedge rst_n)
   if(!rst_n)config_entity[config_byte*8+:8]<=0;
   else if(collecting_config && read_index==config_byte+16)
    config_entity[config_byte*8+:8]<=read_data;
 end
 end else begin:digest_config
  // Retain the exact published entity version for the policy's cross-check;
  // upper bytes are deliberately absent and must not be advertised as a copy.
  always @*config_entity={2080'd0,config_version};
 end endgenerate
 wire packet_ack=process_packet || (packet_valid && !collecting && !process_packet && packet_length>280);
 wire [31:0] sample_delta=received[128+:32]-last_sample;
 wire context_ok=received[0+:64]==boot_id && received[64+:32]==session_id;
 wire response_ok=pending && packet_seq==request_seq && packet_cmd==8'h80 &&
   packet_length>=16 && received[96+:8]==request_cmd && received[104+:8]==0;
 // A packet completing exactly at the final timeout cannot revive the failed
 // session or republish an event after restart has revoked its mailbox.
 wire session_expiring=pending && !tx_active && retries==2 && request_elapsed_apm>=REQUEST_TIMEOUT_US;
 wire [63:0] t2=received[192+:64],t3=received[256+:64];
 wire signed [63:0] a_offset=$signed(t1+REQUEST_LINE_US)-$signed(t2);
 wire signed [63:0] b_offset=$signed(receive_time-REPLY_LINE_US)-$signed(t3);
 wire signed [63:0] corrected_rtt=b_offset-a_offset;
 uart_v2_parser parser(.clk(clk),.rst_n(rst_n),.now_us(now_us),.byte_valid(rx_valid),.byte_data(rx_data),
  .byte_error(rx_error),.packet_valid(packet_valid),.packet_revoked(packet_revoked),.packet_ready(packet_ack),.cmd(packet_cmd),
  .seq(packet_seq),.length(packet_length),.receive_us(receive_time),
  .read_valid(read_valid),.read_index(read_index),.read_response(read_response),.read_data(read_data),
  .bad_crc(bad_crc),.bad_header(bad_header),.timeouts(timeouts),.overflows(overflows),.peak_bytes());
 function automatic [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer i;
  begin v=c^{b,8'd0};for(i=0;i<8;i=i+1) v=(v<<1)^(v[15]?16'h1021:0);crc_byte=v;end
 endfunction
 // Request bytes remain stable while UART is busy; CRC covers version through
 // payload, little endian CRC trailer. t1 is captured at actual first-byte grant.
 assign tx_valid=tx_active && enable;
 reg [7:0] selected_byte;
 always @* begin
  selected_byte=0;
  case(tx_pos)
   0:selected_byte=8'h55;1:selected_byte=8'haa;2:selected_byte=2;3:selected_byte=request_cmd;
   4:selected_byte=request_seq[7:0];5:selected_byte=request_seq[15:8];
   6:selected_byte={2'b0,request_length};7:selected_byte=0;
   default: if(tx_pos<request_length+8) selected_byte=request_payload[(tx_pos-8)*8+:8];
    else if(tx_pos==request_length+8) selected_byte=tx_crc[7:0];else selected_byte=tx_crc[15:8];
  endcase
 end
 assign tx_data=selected_byte;
 // All requests pass this private dispatcher; the externally supplied session
 // is data only. Session exhaustion disables admission until a different ID.
 task automatic launch(input [7:0] command,input [5:0] size,input [191:0] payload);
  begin
   request_cmd<=command;request_length<=size;request_payload<=payload;
   request_seq<=next_seq;next_seq<=next_seq+1'b1;pending<=1;retries<=0;
   tx_active<=1;tx_pos<=0;tx_crc<=16'hffff;first_send<=1;request_start<=now_us;
  end
 endtask
 task automatic restart;
  begin
   session_valid<=0;mapping_valid<=0;config_valid<=0;phase<=INFO;
   pending<=0;tx_active<=0;have_sample<=0;next_seq<=1;
   reopen_required<=1;
   sync_step<=0;
   // Unconsumed events belong to this session and must never be ACKed after reopen.
   state_decision_pending<=0;state_valid<=0;event_valid<=0;
   reconnects<=reconnects+1;
  end
 endtask
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   phase<=INFO;pending<=0;tx_active<=0;first_send<=0;request_cmd<=0;request_seq<=0;
   next_seq<=1;request_length<=0;request_payload<=0;tx_pos<=0;tx_crc<=16'hffff;
   retries<=0;request_start<=0;next_sync<=0;t1<=0;sync_id<=0;last_sample<=0;
   last_event<=0;ack_target<=0;have_sample<=0;collecting<=0;read_wait<=0;process_packet<=0;
   read_index<=0;session_valid<=0;boot_id<=0;session_id<=0;
   config_valid<=0;config_version<=0;state_valid<=0;state_payload<=0;state_receive_us<=0;reopen_required<=0;
   event_valid<=0;event_payload<=0;mapping_valid<=0;clock_offset_us<=0;clock_error_us<=0;sync_received_us<=0;
   rejected_states<=0;rejected_replies<=0;reconnects<=0;event_drops<=0;
   sync_step<=0;sync_t1<=0;sync_t2<=0;sync_t3<=0;sync_t4<=0;
   sync_a_base<=0;sync_b_base<=0;sync_a<=0;sync_b<=0;sync_rtt<=0;sync_offset<=0;
   sync_capture_error<=0;sync_eligible<=0;
   state_decision_pending<=0;state_context_valid<=0;state_new_config<=0;state_had_sample<=0;
   state_time<=0;state_delta<=0;
  end else begin
   state_valid<=0;process_packet<=0;
   // Stage sample delta separately from acceptance/statistics enables.
   // received is already a complete client-owned copy, independent of parser
   // ACK/revocation. process_packet does not write it; on this next edge any
   // new borrow clears it only AFTER these reads (nonblocking assignments).
   // Thus a second 768-bit intermediate copy is unnecessary. Keep the public
   // state_payload register and its original publication/reset behavior.
   if(state_decision_pending) begin
    state_decision_pending<=0;
    if(state_context_valid && (!state_had_sample || state_delta!=0 && !state_delta[31])) begin
     state_payload<=received;state_receive_us<=state_time;state_valid<=1;
     last_sample<=received[128+:32];have_sample<=1;
    end else begin
     rejected_states<=rejected_states+1;
     if(state_new_config) begin
      session_valid<=0;mapping_valid<=0;phase<=CONFIG;pending<=0;have_sample<=0;sync_step<=0;
     end
    end
   end
   // SYNC time arithmetic is an explicit four-cycle service pipeline. Latch
   // the reply before returning borrowed RX storage; concurrent STATE reception
   // continues. No multicycle exception or live-payload dependency is needed.
   case(sync_step)
    4: begin sync_a_base<=$signed(sync_a_base_apm);sync_b_base<=$signed(sync_b_base_apm);sync_step<=3;end
    3: begin sync_a<=sync_a_apm;sync_b<=sync_b_apm;sync_step<=2;end
    2: begin
     sync_rtt<=sync_rtt_apm;
     sync_offset<=sync_average_apm;sync_step<=1;
    end
    1: begin
     sync_step<=0;
     if(sync_eligible && sync_rtt>=-4 && sync_rtt<=10000) begin
      clock_offset_us<=sync_offset;clock_error_us<=((sync_abs_rtt+14'd1)>>1)+32'd4+sync_capture_error;
      mapping_valid<=1;sync_received_us<=sync_t4;
     end else mapping_valid<=0;
    end
    default: begin end
   endcase
   if(event_valid && event_ready) begin event_valid<=0;ack_target<=event_payload[96+:32];end
   if(borrow_live && !collecting && !process_packet && packet_length<=280) begin
    read_index<=0;collecting<=packet_length!=0;read_wait<=0;
    if(packet_length==0) process_packet<=1;
   end
   if(read_valid) read_wait<=1;
   if(collecting && !borrow_live) begin
    // Overflow/framing discontinuity can revoke a borrowed parser packet.
    // Abandon its partial entity instead of waiting indefinitely for more reads.
    collecting<=0;read_wait<=0;process_packet<=0;rejected_replies<=rejected_replies+1;
   end else if(collecting && read_response) begin
    read_wait<=0;
    if(read_index==packet_length-1) begin collecting<=0;process_packet<=1;end
    else read_index<=read_index+1'b1;
   end
   if(tx_valid && tx_ready) begin
    if(tx_pos==0) begin
     tx_crc<=16'hffff;request_start<=now_us;
     if(first_send && request_cmd==8'h45) begin
      t1<=now_us;request_payload[128+:64]<=now_us;
     end
     first_send<=0;
    end
    if(tx_pos>=2 && tx_pos<request_length+8) tx_crc<=crc_byte(tx_crc,selected_byte);
    if(tx_pos==request_length+9) tx_active<=0;else tx_pos<=tx_pos+1'b1;
   end
   if(enable && new_session!=0) begin
    if(session_id!=0 && session_id!=new_session) begin
     session_id<=new_session;restart();reopen_required<=0;
    end else if(reopen_required) begin
     // Reuse of seq=1 in the failed session would violate anti-replay semantics.
     // Integration must allocate a fresh nonzero session before reconnecting.
     session_valid<=0;mapping_valid<=0;
    end
    else if(pending && !tx_active && request_elapsed_apm>=REQUEST_TIMEOUT_US) begin
     if(retries==2) restart();
     else begin retries<=retries+1'b1;tx_active<=1;tx_pos<=0;tx_crc<=16'hffff;request_start<=now_us;end
    end else if(!pending && !tx_active && !config_valid) begin
     if(next_seq==0) begin session_valid<=0;mapping_valid<=0;reopen_required<=1;sync_step<=0;end
     else case(phase)
      INFO: begin session_id<=new_session;launch(8'h40,0,0);end
      OPEN: launch(8'h41,16,{64'd0,32'd0,boot_id,session_id});
      CONFIG: launch(8'h42,12,{96'd0,session_id,boot_id});
      STREAM: launch(8'h43,16,{64'd0,16'd0,16'd200,session_id,boot_id});
      RUN: if(ack_target>last_event) launch(8'h49,16,{64'd0,ack_target,session_id,boot_id});
       else if(now_us>=next_sync) begin
        sync_id<=sync_id+1;launch(8'h45,24,{64'd0,sync_id+32'd1,session_id,boot_id});
       end
      default: restart();
     endcase
    end
   end else begin
    // Disabling the boundary also revokes its borrowed event mailbox.
    session_valid<=0;mapping_valid<=0;pending<=0;tx_active<=0;phase<=INFO;
    have_sample<=0;config_valid<=0;sync_step<=0;state_decision_pending<=0;state_valid<=0;event_valid<=0;
   end
   // Session rotation fences even an already-received configuration/reply.
   // Caller changing the nonce on this edge must not approve the old entity.
   if(enable && new_session==session_id && !reopen_required && config_valid && config_ready) begin
    config_valid<=0;
    if(config_approved) begin phase<=STREAM;session_valid<=1;end else restart();
   end
   // Responses are matched by command AND seq AND context. A CRC-valid wrong
   // boot response never selects a new boot; identity is established by INFO.
   if(process_packet && borrow_live && enable && new_session==session_id && !reopen_required && !session_expiring) begin
    if(packet_cmd==8'h81) begin
     state_time<=receive_time;state_delta<=sample_delta;
     state_had_sample<=have_sample;state_decision_pending<=1;
     state_context_valid<=session_valid && packet_length==96 && context_ok &&
       received[96+:32]==config_version && packet_seq==received[128+:16];
     // A late older configuration is rejected without revoking the new entity.
     // Only a strictly newer config requests a fresh immutable GET_CONFIG.
     state_new_config<=session_valid && packet_length==96 && context_ok && received[96+:32]>config_version;
    end else if(packet_cmd==8'h90 && packet_length==40 && context_ok && session_valid) begin
     if(!event_valid && received[96+:32]==ack_target+1) begin event_valid<=1;event_payload<=received[0+:320];end
     else if(received[96+:32]>ack_target) event_drops<=event_drops+1;
    end else if(packet_cmd==8'h82 && packet_length==40 && pending && request_cmd==8'h45 &&
                packet_seq==request_seq && context_ok && received[96+:32]==sync_id && received[128+:64]==t1) begin
     pending<=0;next_sync<=next_sync_apm;
     sync_t1<=t1;sync_t2<=t2;sync_t3<=t3;sync_t4<=receive_time;
     sync_eligible<=timing_bound_valid && capture_error_us<=1000000 && t3>=t2;
     sync_capture_error<=capture_error_us;sync_step<=4;
    end else if(response_ok) begin
     if(request_cmd==8'h40 && packet_length==64 && received[240+:16]==16'h4d32 &&
        received[256+:32]==1000000 && received[0+:64]!=0 && received[64+:32]==0 &&
        received[320+:16]==1024 && received[336+:16]>=200 && received[352+:16]==30 &&
        (received[288+:32]&32'h31)==32'h31 && (received[288+:32]&32'hffffff80)==0) begin
      boot_id<=received[0+:64];phase<=OPEN;pending<=0;
      // No events means expected first event 1; otherwise preserve oldest log.
      ack_target<=received[448+:32]!=0 ? received[448+:32]-1 : received[480+:32];
      last_event<=received[448+:32]!=0 ? received[448+:32]-1 : received[480+:32];
     end else if(context_ok) begin
      case(request_cmd)
       8'h41: if(packet_length==24) begin phase<=CONFIG;pending<=0;end
       8'h42: if(packet_length==280 && received[128+:32]!=0) begin
        // All entity bytes (and their complete digest) were consumed before
        // publication; digest-only builds retain only version and CRC.
        config_version<=received[128+:32];config_valid<=1;pending<=0;
       end
       8'h43: if(packet_length==20 && received[128+:16]==200 && received[144+:16]==0) begin
        phase<=RUN;pending<=0;next_sync<=now_us;
       end
       // New events may be consumed while this ACK is outstanding. Match its
       // frozen request target, not the evolving cumulative receive watermark.
       8'h49: if(packet_length==20 && received[128+:32]==request_payload[96+:32]) begin
        last_event<=received[128+:32];pending<=0;
       end
       default: rejected_replies<=rejected_replies+1;
      endcase
     end else rejected_replies<=rejected_replies+1;
    end else if(packet_cmd!=8'h81) rejected_replies<=rejected_replies+1;
   end
   // Mapping expires independently of STATE rate; its hardware uncertainty and
   // drift bound must be added by the frame selector, never hidden by 200Hz RX.
   if(mapping_valid && sync_elapsed_apm>SYNC_INTERVAL_US*2) mapping_valid<=0;
  end
 end
endmodule

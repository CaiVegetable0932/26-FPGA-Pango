`timescale 1ns/1ps
// MCU_POSE_V2 independent FPGA link, byte ports connect ONLY to MCU UART.
// GET_INFO(profile) -> OPEN -> GET_CONFIG(entity) -> SET_STREAM -> SYNC.
// One request, seq 1..65535 without wrap, two exact retries, 200ms deadline.
// No opcode for movement/HOME/zero/heartbeat is emitted. STATE is dispatched
// independently of transactions. Complete configuration must be archived and
// validated by the entity consumer before high-frequency state is admitted.
module mcu_readonly_client #(
 parameter BAUD=460800,REQUEST_TIMEOUT_US=200000,SYNC_INTERVAL_US=1000000
)(
 input clk,input rst_n,input [63:0] now_us,input enable,input [31:0] new_session,
 input rx_valid,input [7:0] rx_data,input rx_error,
 input timing_bound_valid,input [31:0] capture_error_us,
 output tx_valid,input tx_ready,output [7:0] tx_data,
 output reg session_valid,output reg [63:0] boot_id,output reg [31:0] session_id,
 output reg reopen_required,
 output reg config_valid,input config_ready,input config_approved,
 output reg [2111:0] config_entity,output reg [31:0] config_version,
 output reg state_valid,output reg [767:0] state_payload,output reg [63:0] state_receive_us,
 output reg event_valid,input event_ready,output reg [319:0] event_payload,
 output reg mapping_valid,output reg signed [63:0] clock_offset_us,
 output reg [31:0] clock_error_us,output reg [63:0] sync_received_us,
 output [31:0] bad_crc,bad_header,timeouts,overflows,
 output reg [31:0] rejected_states,rejected_replies,reconnects,event_drops
);
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
 reg [767:0] state_buffer;reg [63:0] state_time;
 reg [31:0] state_delta;
 wire [13:0] sync_abs_rtt=sync_rtt[63] ? -sync_rtt[13:0] : sync_rtt[13:0];
 reg [2239:0] received;
 reg [9:0] read_index;
 wire packet_valid,read_response;
 wire [7:0] packet_cmd,read_data;wire [15:0] packet_seq,packet_length;
 wire [63:0] receive_time;
 wire read_valid=collecting && !read_wait;
 wire packet_ack=process_packet || (packet_valid && !collecting && !process_packet && packet_length>280);
 wire [31:0] sample_delta=received[128+:32]-last_sample;
 wire context_ok=received[0+:64]==boot_id && received[64+:32]==session_id;
 wire response_ok=pending && packet_seq==request_seq && packet_cmd==8'h80 &&
   packet_length>=16 && received[96+:8]==request_cmd && received[104+:8]==0;
 wire [63:0] t2=received[192+:64],t3=received[256+:64];
 wire signed [63:0] a_offset=$signed(t1+REQUEST_LINE_US)-$signed(t2);
 wire signed [63:0] b_offset=$signed(receive_time-REPLY_LINE_US)-$signed(t3);
 wire signed [63:0] corrected_rtt=b_offset-a_offset;
 uart_v2_parser parser(.clk(clk),.rst_n(rst_n),.now_us(now_us),.byte_valid(rx_valid),.byte_data(rx_data),
  .byte_error(rx_error),.packet_valid(packet_valid),.packet_ready(packet_ack),.cmd(packet_cmd),
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
   state_decision_pending<=0;state_valid<=0;
   reconnects<=reconnects+1;
  end
 endtask
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   phase<=INFO;pending<=0;tx_active<=0;first_send<=0;request_cmd<=0;request_seq<=0;
   next_seq<=1;request_length<=0;request_payload<=0;tx_pos<=0;tx_crc<=16'hffff;
   retries<=0;request_start<=0;next_sync<=0;t1<=0;sync_id<=0;last_sample<=0;
   last_event<=0;ack_target<=0;have_sample<=0;collecting<=0;read_wait<=0;process_packet<=0;
   read_index<=0;received<=0;session_valid<=0;boot_id<=0;session_id<=0;
   config_valid<=0;config_entity<=0;config_version<=0;state_valid<=0;state_payload<=0;state_receive_us<=0;reopen_required<=0;
   event_valid<=0;event_payload<=0;mapping_valid<=0;clock_offset_us<=0;clock_error_us<=0;sync_received_us<=0;
   rejected_states<=0;rejected_replies<=0;reconnects<=0;event_drops<=0;
   sync_step<=0;sync_t1<=0;sync_t2<=0;sync_t3<=0;sync_t4<=0;
   sync_a_base<=0;sync_b_base<=0;sync_a<=0;sync_b<=0;sync_rtt<=0;sync_offset<=0;
   sync_capture_error<=0;sync_eligible<=0;
   state_decision_pending<=0;state_context_valid<=0;state_new_config<=0;state_had_sample<=0;
   state_buffer<=0;state_time<=0;state_delta<=0;
  end else begin
   state_valid<=0;process_packet<=0;
   // Stage sample delta separately from acceptance/statistics enables. Keep
   // the immutable complete STATE across parser ACK, never use the next packet.
   if(state_decision_pending) begin
    state_decision_pending<=0;
    if(state_context_valid && (!state_had_sample || state_delta!=0 && !state_delta[31])) begin
     state_payload<=state_buffer;state_receive_us<=state_time;state_valid<=1;
     last_sample<=state_buffer[128+:32];have_sample<=1;
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
    4: begin sync_a_base<=$signed(sync_t1+REQUEST_LINE_US);sync_b_base<=$signed(sync_t4-REPLY_LINE_US);sync_step<=3;end
    3: begin sync_a<=sync_a_base-$signed(sync_t2);sync_b<=sync_b_base-$signed(sync_t3);sync_step<=2;end
    2: begin
     sync_rtt<=sync_b-sync_a;
     sync_offset<=(sync_a>>>1)+(sync_b>>>1)+(sync_a[0] && sync_b[0]);sync_step<=1;
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
   if(packet_valid && !collecting && !process_packet && packet_length<=280) begin
    received<=0;read_index<=0;collecting<=packet_length!=0;read_wait<=0;
    if(packet_length==0) process_packet<=1;
   end
   if(read_valid) read_wait<=1;
   if(collecting && !packet_valid) begin
    // Overflow/framing discontinuity can revoke a borrowed parser packet.
    // Abandon its partial entity instead of waiting indefinitely for more reads.
    collecting<=0;read_wait<=0;rejected_replies<=rejected_replies+1;
   end
   if(collecting && read_response) begin
    received[read_index*8+:8]<=read_data;read_wait<=0;
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
    else if(pending && !tx_active && now_us-request_start>=REQUEST_TIMEOUT_US) begin
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
   end else begin session_valid<=0;mapping_valid<=0;pending<=0;tx_active<=0;phase<=INFO;have_sample<=0;config_valid<=0;sync_step<=0;state_decision_pending<=0;state_valid<=0;end
   // Session rotation fences even an already-received configuration/reply.
   // Caller changing the nonce on this edge must not approve the old entity.
   if(enable && new_session==session_id && !reopen_required && config_valid && config_ready) begin
    config_valid<=0;
    if(config_approved) begin phase<=STREAM;session_valid<=1;end else restart();
   end
   // Responses are matched by command AND seq AND context. A CRC-valid wrong
   // boot response never selects a new boot; identity is established by INFO.
   if(process_packet && enable && new_session==session_id && !reopen_required) begin
    if(packet_cmd==8'h81) begin
     state_buffer<=received[0+:768];state_time<=receive_time;state_delta<=sample_delta;
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
     pending<=0;next_sync<=now_us+SYNC_INTERVAL_US;
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
        config_entity<=received[128+:2112];config_version<=received[128+:32];config_valid<=1;pending<=0;
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
   if(mapping_valid && now_us-sync_received_us>SYNC_INTERVAL_US*2) mapping_valid<=0;
  end
 end
endmodule

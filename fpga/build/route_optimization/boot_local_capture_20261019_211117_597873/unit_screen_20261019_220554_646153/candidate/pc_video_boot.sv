`timescale 1ns/1ps
// Purpose: CP2102 PC-only RAW8 boot entity, compatible with host raw8_boot.py:
// UART 115200, V1 command 0x71, 32-byte epoch/MAC/IP/port payload and CCITT CRC.
// This is NOT the removed MCU_POSE_V1 protocol. It uses a separate parser and
// never emits motion commands. Boot addresses stay immutable; runtime 0x90/92
// status/mode and 0x94/95 geometry use queued whole entities and frozen readback.
module pc_video_boot #(parameter CLK_HZ=125000000,BAUD=115200)(
 input clk,rst_n,input uart_rx,output uart_tx,output reg configured,
 output reg [63:0] epoch,output reg [47:0] local_mac,peer_mac,
 output reg [31:0] local_ip,peer_ip,output reg [15:0] local_port,peer_port,
 input [767:0] control_status,
 output mode_submit_valid,input mode_submit_ready,output [1:0] mode_submit,output [31:0] mode_version,
 input [767:0] geometry_status,snapshot_s1_status,snapshot_result_status,snapshot_geometry_status,output geometry_submit_valid,input geometry_submit_ready,
 output [543:0] geometry_submit,output [31:0] geometry_version,geometry_entity_id,
 output snapshot_arm,input snapshot_arm_ready
);
 localparam IDLE=0,COLLECT=1,CHECK=2,SEND=3,DRAIN=4,RUN=5,TRANSMIT=6,SUBMIT=7,GUARD=8,GUARD_WAIT=9,GEOMETRY_SUBMIT=10,SNAPSHOT_SUBMIT=11;
 reg [3:0] state;reg [6:0] index,collect_length;reg [5:0] tx_index;reg waiting,tx_active,accepted;
 reg [7:0] operation;reg [1535:0] status_snapshot;reg have_snapshot;reg [7:0] snapshot_operation;
 reg [639:0] received;reg [255:0] reply;reg [15:0] reply_seq,tx_crc;
 reg [7:0] reply_cmd,selected_byte;
 wire byte_valid,byte_error,uart_ready;wire [7:0] byte_data;
 reg [6:0] us_divider;reg [63:0] now_us;
 wire packet_valid,read_response;wire [7:0] command,read_data;wire [15:0] seq,length;
 wire read_valid=state==COLLECT && !waiting;
 wire supported=(!configured && command==8'h71 && length==32) ||
  (configured && (((command==8'h90 || command==8'h95 || command==8'h96 || command==8'h97) && length==1) || (command==8'h92 && length==6) || (command==8'h94 && length==80) || (command==8'h93 && length==1)));
 wire packet_ready=state==CHECK || ((state==IDLE || state==RUN) && packet_valid && !supported);
 assign snapshot_arm=state==SNAPSHOT_SUBMIT;
 assign geometry_submit_valid=state==GEOMETRY_SUBMIT;
 assign geometry_submit=received[607:64],geometry_version=received[31:0],geometry_entity_id=received[63:32];
 // Validate all 19 signed words and CRC32 over the first 76 payload bytes.
 // These are the supported fixed-point implementation bounds, not an optical
 // calibration certificate. Invalid depth pixels still receive the mask.
 wire [607:0] entity_low,entity_high;
 genvar bound_word;
 generate for(bound_word=0;bound_word<19;bound_word=bound_word+1)begin: geometry_bounds
  localparam SMALL_A=bound_word==2 || bound_word==3 || bound_word==5 || bound_word==6 || bound_word==16 || bound_word==17;
  localparam TRANSLATION=bound_word==4 || bound_word==7 || bound_word==18;
  localparam RADIAL=bound_word==8 || bound_word==9,TANGENTIAL=bound_word==10 || bound_word==11;
  localparam FOCAL=bound_word==12 || bound_word==13,CENTRE=bound_word==14 || bound_word==15;
  localparam [31:0] LO=bound_word<2 || FOCAL ? 32'd1:SMALL_A ? -32'sh00800000:
   TRANSLATION || CENTRE ? -32'sh20000000:RADIAL ? -32'sh08000000:TANGENTIAL ? -32'sh01000000:32'h80000000;
  localparam [31:0] HI=SMALL_A ? 32'h00800000:TRANSLATION || FOCAL || CENTRE ? 32'h20000000:
   RADIAL ? 32'h08000000:TANGENTIAL ? 32'h01000000:32'h7fffffff;
  assign entity_low[bound_word*32+:32]=LO,entity_high[bound_word*32+:32]=HI;
 end endgenerate
 wire guard_ready,guard_valid,guard_accepted;
 parameter_entity_guard #(.WORDS(19)) geometry_guard(.clk(clk),.rst_n(rst_n),.submit_valid(state==GUARD),.submit_ready(guard_ready),
  .entity(received[607:0]),.lower_bounds(entity_low),.upper_bounds(entity_high),.expected_crc(received[639:608]),
  .format_supported(received[31:0]>geometry_status[576+:32] && received[63:32]!=0 && received[607:512]!=0),
  .result_valid(guard_valid),.result_ready(state==GUARD_WAIT),.validated(guard_accepted),.result_entity(),.reject_reason());
 assign mode_submit_valid=state==SUBMIT,mode_submit=received[1:0],mode_version=received[47:16];
 uart_8n1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(.clk(clk),.rst_n(rst_n),.rx(uart_rx),.tx(uart_tx),
  .rx_valid(byte_valid),.rx_data(byte_data),.framing_error(byte_error),.tx_valid(tx_active),.tx_ready(uart_ready),.tx_data(selected_byte));
 uart_v2_parser #(.WIRE_VERSION(1),.TIMEOUT_US(150000)) parser(.clk(clk),.rst_n(rst_n),.now_us(now_us),
  .byte_valid(byte_valid),.byte_data(byte_data),.byte_error(byte_error),.packet_valid(packet_valid),.packet_ready(packet_ready),
  .cmd(command),.seq(seq),.length(length),.receive_us(),.read_valid(read_valid),.read_index({3'd0,index}),
  .read_response(read_response),.read_data(read_data),.bad_crc(),.bad_header(),.timeouts(),.overflows(),.peak_bytes());
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer bit_no;
  begin v=c^{b,8'd0};for(bit_no=0;bit_no<8;bit_no=bit_no+1)v=(v<<1)^(v[15]?16'h1021:0);crc_byte=v;end
 endfunction
 wire entity_valid=received[63:0]!=0 && received[111:64]!=0 && received[159:112]!=0 &&
  !received[64] && !received[112] && received[167:160]!=0 && received[167:160]<224 &&
  received[199:192]!=0 && received[199:192]<224 && received[239:224]!=0 && received[255:240]!=0;
 // Reply formatter holds bytes/CRC under UART backpressure and echoes the PC
 // sequence. Configuration becomes active after the final UART stop-bit drain.
 always @*begin
  selected_byte=0;
  case(tx_index)
   0:selected_byte=8'h55;1:selected_byte=8'haa;2:selected_byte=1;3:selected_byte=reply_cmd;
   4:selected_byte=reply_seq[7:0];5:selected_byte=reply_seq[15:8];6:selected_byte=32;7:selected_byte=0;
   40:selected_byte=tx_crc[7:0];41:selected_byte=tx_crc[15:8];
   default:if(tx_index>=8 && tx_index<40)selected_byte=reply[(tx_index-8)*8+:8];
  endcase
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;index<=0;waiting<=0;tx_index<=0;tx_active<=0;accepted<=0;
   received<=0;reply<=0;reply_seq<=0;reply_cmd<=0;tx_crc<=16'hffff;configured<=0;
   collect_length<=0;operation<=0;have_snapshot<=0;snapshot_operation<=0;
   epoch<=0;local_mac<=0;peer_mac<=0;local_ip<=0;peer_ip<=0;local_port<=0;peer_port<=0;us_divider<=0;now_us<=0;end
  else begin
   if(us_divider==124)begin us_divider<=0;now_us<=now_us+1'b1;end else us_divider<=us_divider+1'b1;
   if(read_valid)waiting<=1;
   if(read_response)begin received[index*8+:8]<=read_data;waiting<=0;
    if(index==collect_length-1'b1)state<=CHECK;else index<=index+1'b1;end
   if(tx_active && uart_ready)begin
    if(tx_index>=2 && tx_index<40)tx_crc<=crc_byte(tx_crc,selected_byte);
    if(tx_index==41)begin tx_active<=0;state<=DRAIN;end else tx_index<=tx_index+1'b1;
   end
   case(state)
    IDLE:if(packet_valid)begin
     if(supported)begin index<=0;waiting<=0;state<=COLLECT;reply_seq<=seq;operation<=command;collect_length<=length[6:0];end
     else begin reply<=0;reply[7:0]<=command!=8'h71 ? 6:3;reply[15:8]<=command;reply_cmd<=8'h81;reply_seq<=seq;accepted<=0;state<=SEND;end
    end
    CHECK:begin
     reply<=0;reply[15:8]<=operation;accepted<=0;state<=SEND;
     if(operation==8'h71)begin
      reply[7:0]<=entity_valid ? 0:11;reply[95:32]<=received[63:0];reply[191:160]<=32'h38574152;
      reply_cmd<=entity_valid ? 8'h80:8'h81;accepted<=entity_valid;
      if(entity_valid)begin
      epoch<=received[63:0];local_mac<={received[71:64],received[79:72],received[87:80],received[95:88],received[103:96],received[111:104]};
      peer_mac<={received[119:112],received[127:120],received[135:128],received[143:136],received[151:144],received[159:152]};
      local_ip<={received[167:160],received[175:168],received[183:176],received[191:184]};
      peer_ip<={received[199:192],received[207:200],received[215:208],received[223:216]};local_port<=received[239:224];peer_port<=received[255:240];
      end
     end else if(operation==8'h90 || operation==8'h95 || operation==8'h96 || operation==8'h97)begin
      reply[23:16]<=received[7:0];reply[31:24]<=24;reply[255:224]<=32'h31424752;
      if(received[7:0]>=(operation==8'h96 ? 8:4) || (received[7:0]!=0 && (!have_snapshot || snapshot_operation!=operation)))begin reply[7:0]<=11;reply_cmd<=8'h81;end
      else begin
       reply[7:0]<=0;reply_cmd<=8'h80;
       if(received[7:0]==0)begin have_snapshot<=1;snapshot_operation<=operation;reply[223:32]<=operation==8'h96 ? snapshot_s1_status[0+:192]:(operation==8'h95 ? geometry_status[0+:192]:(operation==8'h97 ? snapshot_geometry_status[0+:192]:control_status[0+:192]));end
       else reply[223:32]<=status_snapshot[received[2:0]*192+:192];
      end
     end else if(operation==8'h93)begin
      if(received[7:0]!=0)begin reply[7:0]<=11;reply_cmd<=8'h81;end
      else if(!snapshot_arm_ready)begin reply[7:0]<=4;reply_cmd<=8'h81;end
      else state<=SNAPSHOT_SUBMIT;
     end else if(operation==8'h94)begin
      reply[63:32]<=received[31:0];reply[95:64]<=received[63:32];
      if(!geometry_submit_ready)begin reply[7:0]<=4;reply_cmd<=8'h81;end else state<=GUARD;
     end else begin
      // Received/validated is distinct from applied. The ACK reports a queued
      // mode entity; status page 1 supplies the actual capture epoch/frame.
      reply[63:32]<=received[47:16];
      if(received[7:0]>2 || received[15:8]!=0 || received[47:16]<=control_status[320+:32])begin reply[7:0]<=11;reply_cmd<=8'h81;end
      else if(!mode_submit_ready)begin reply[7:0]<=4;reply_cmd<=8'h81;end
      else state<=SUBMIT;
     end
    end
    SNAPSHOT_SUBMIT:if(snapshot_arm_ready)begin reply[7:0]<=0;reply[23:16]<=2;reply_cmd<=8'h80;state<=SEND;end
    GUARD:if(guard_ready)state<=GUARD_WAIT;
    GUARD_WAIT:if(guard_valid)begin
     if(!guard_accepted)begin reply[7:0]<=11;reply_cmd<=8'h81;state<=SEND;end
     else if(!geometry_submit_ready)begin reply[7:0]<=4;reply_cmd<=8'h81;state<=SEND;end
     else state<=GEOMETRY_SUBMIT;
    end
    GEOMETRY_SUBMIT:if(geometry_submit_ready)begin reply[7:0]<=0;reply[23:16]<=2;reply_cmd<=8'h80;state<=SEND;end
    SUBMIT:if(mode_submit_ready)begin reply[7:0]<=0;reply[23:16]<=2;reply_cmd<=8'h80;state<=SEND;end
    SEND:begin tx_active<=1;tx_index<=0;tx_crc<=16'hffff;state<=TRANSMIT;end
    DRAIN:if(uart_ready)begin if(accepted || configured)begin configured<=1;state<=RUN;end else state<=IDLE;end
    RUN:if(packet_valid)begin
     if(supported)begin index<=0;waiting<=0;state<=COLLECT;reply_seq<=seq;operation<=command;collect_length<=length[6:0];end
     else begin reply<=0;reply[7:0]<=6;reply[15:8]<=command;reply_cmd<=8'h81;reply_seq<=seq;accepted<=0;state<=SEND;end
    end
   endcase
  end
 end

 // The final payload response precedes CHECK by exactly one edge. For the
 // one-byte status commands the incoming byte is the complete page number;
 // retain the collected-byte form too so the predecode states its semantics.
 wire status_operation=operation==8'h90 || operation==8'h95 || operation==8'h96 || operation==8'h97;
 wire last_status_page_zero=read_response && index==collect_length-1'b1 &&
  status_operation && ((index==0) ? read_data==0 : received[7:0]==0);
 // ADS guide 5.15: preserve just the eight intentionally local enable copies.
 // Reset clears copies and all payload pages, matching original cold/mid-job
 // behavior. No new UART, reply, snapshot or command state is introduced.
 reg [7:0] status_capture_page /* synthesis syn_preserve=1 */;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)status_capture_page<=0;
  else status_capture_page<={8{last_status_page_zero}};
 end
 wire [1535:0] status_capture_data=operation==8'h96 ? {snapshot_result_status,snapshot_s1_status}:
  {768'd0,(operation==8'h95 ? geometry_status:(operation==8'h97 ? snapshot_geometry_status:control_status))};
 genvar status_page;
 generate for(status_page=0;status_page<8;status_page=status_page+1)begin: local_status_page
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)status_snapshot[status_page*192+:192]<=0;
   else if(status_capture_page[status_page])
    status_snapshot[status_page*192+:192]<=status_capture_data[status_page*192+:192];
  end
 end endgenerate
endmodule

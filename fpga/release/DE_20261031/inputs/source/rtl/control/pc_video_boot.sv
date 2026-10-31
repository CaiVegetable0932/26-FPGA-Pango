`timescale 1ns/1ps
// Purpose: CP2102 PC-only RAW8 boot entity, compatible with host raw8_boot.py:
// UART 115200, V1 command 0x71, 32-byte epoch/MAC/IP/port payload and CCITT CRC.
// This is NOT the removed MCU_POSE_V1 protocol. It uses a separate parser and
// never emits motion commands. Boot addresses stay immutable; runtime 0x90/92
// status/mode and 0x94/95 geometry use queued whole entities and frozen readback.
module pc_video_boot #(parameter LOCAL_ENTITY_VALIDATION=0,RAW_POSE=0,PROJECTIVE=0,FIXED_GRAY=0, parameter CLK_HZ=125000000,BAUD=115200,parameter [15:0] ENTITY_MASK=16'h0200,parameter STREAM_CCM=0,parameter SUMMARY_READBACK=0)(
 // A7 forwards raw mechanical pose; A8 reports its actual board transaction.
 output pose_request_valid,output [15:0] pose_sequence,output [415:0] pose_body,
 input pose_response_valid,input [7:0] pose_response_code,input [767:0] pose_status,
 input clk,rst_n,input uart_rx,output uart_tx,output reg configured,
 output reg [63:0] epoch,output reg [47:0] local_mac,peer_mac,
 output reg [31:0] local_ip,peer_ip,output reg [15:0] local_port,peer_port,
 input [767:0] control_status,affine_status,reference_status,
 output reference_submit_valid,output [511:0] reference_entity,
 output [31:0] reference_version,reference_entity_id,input [7:0] reference_submit_code,
 // Configuration-only packed buses. Consumers capture on COMMIT; no pixel
 // carries this staging payload. Readback freezes one selected entity record.
 output entity_submit_valid,output [15:0] entity_kind,entity_length,
 output [2047:0] entity_body,input [7:0] entity_submit_code,
 output [15:0] entity_read_kind,input [2303:0] entity_status,
 // Discrete motion actions queue at a source boundary independently of uploads.
 output runtime_action_valid,output [15:0] runtime_action,runtime_action_seq,input [7:0] runtime_action_code,
 output affine_submit_valid,output [95:0] affine_payload,output [15:0] affine_sequence,
 input [7:0] affine_submit_code,
 output mode_submit_valid,input mode_submit_ready,output [1:0] mode_submit,output [31:0] mode_version,
 input [767:0] geometry_status,output geometry_submit_valid,input geometry_submit_ready,
 output [543:0] geometry_submit,output [31:0] geometry_version,geometry_entity_id
);
 localparam IDLE=0,COLLECT=1,CHECK=2,SEND=3,DRAIN=4,RUN=5,TRANSMIT=6,SUBMIT=7,GUARD=8,GUARD_WAIT=9,GEOMETRY_SUBMIT=10,ACTION_SUBMIT=11,AFFINE_SUBMIT=12,ENTITY_REQUEST=13,ENTITY_WAIT=14,PAGE_REPLY=15,POSE_WAIT=16,MODE_CHECK=17,MODE_BUSY=18,MODE_DONE=19;
 reg [4:0] state;reg [6:0] index,collect_length;reg [5:0] tx_index;reg waiting,tx_active,accepted;
 reg [15:0] readback_kind,entity_last_sequence;reg [7:0] next_entity_page,entity_last_page;
 // Capacity follows advertised entities: LUT readback alone needs 12 pages;
 // MCU policy needs8, pose/frame records7, legacy/reference records4.
 localparam SNAPSHOT_PAGES=SUMMARY_READBACK?4:ENTITY_MASK[2]?12:ENTITY_MASK[12]?8:(ENTITY_MASK[8] || ENTITY_MASK[11])?7:4;
 localparam UPLOAD_BYTES=ENTITY_MASK[2]?256:(ENTITY_MASK[8] || ENTITY_MASK[13])?128:64;
 reg [7:0] operation;reg [SNAPSHOT_PAGES*192-1:0] status_snapshot;reg have_snapshot;reg [7:0] snapshot_operation;
 wire [639:0] received;reg [255:0] reply;reg [15:0] reply_seq,tx_crc;
 reg [7:0] reply_cmd,selected_byte;
 wire byte_valid,byte_error,uart_ready;wire [7:0] byte_data;
 reg [6:0] us_divider;reg [63:0] now_us;
 wire packet_valid,read_response;wire [7:0] command,read_data;wire [15:0] seq,length;
 wire read_valid=state==COLLECT && !waiting;
 wire supported=(!configured && command==8'h71 && length==32) ||
  (configured && (((command==8'h90 || command==8'h95 || (RAW_POSE && command==8'ha8)) && length==1) || (command==8'h92 && length==6) || (command==8'h94 && length==80) || (RAW_POSE && command==8'ha7 && length==52) || (command==8'ha6 && length==12) || (command==8'ha0 && length==1) || (command==8'ha4 && length==4) || (command==8'ha1 && length==24) || (command==8'ha2 && length>=9 && length<=72) || (command==8'ha3 && length==12) || (command==8'ha5 && length==8)));
 wire packet_ready=state==CHECK || ((state==IDLE || state==RUN) && packet_valid && !supported);
 wire entity_request_ready,entity_response_valid;wire [7:0] entity_response_code;
 wire [31:0] entity_transaction;wire [15:0] entity_frontier;
 wire upload_submit;wire [7:0] consumer_code=entity_kind==9?reference_submit_code:entity_submit_code;
 // Qualify each attempt with its own consumer only. In particular the
 // reference multiplier/validator must never control MCU session/event CE.
 assign reference_submit_valid=upload_submit && entity_kind==9 && reference_submit_code==0;
 // The board's camera/tone/colour/pose consumers each enforce their own
 // code==0 before mutation. Send them the immutable COMMIT attempt without
 // feeding another selected consumer's range checks back into every CE.
 // Keep the qualified legacy interface for callers without local guards.
 assign entity_submit_valid=upload_submit && entity_kind!=9 && (LOCAL_ENTITY_VALIDATION || entity_submit_code==0);
 assign entity_read_kind=received[15:0];
 wire read_kind_legal=received[15:0]==9 || received[15:0]==10 ||
                     (received[15:0]<=13 && ENTITY_MASK[received[3:0]]);
 function [7:0] page_count(input [15:0] kind);
  begin if(SUMMARY_READBACK && kind!=9 && kind!=10)page_count=2;else case(kind)
   1,4,5:page_count=3;
   2:page_count=12;
   3,7,9,10:page_count=4;
   6:page_count=2;
   8,11:page_count=7;
   // MCU policy plus diagnostics are one atomic readback, eight pages.
   12:page_count=8;
   default:page_count=0;
  endcase end
 endfunction
 // An exact last-page retry replays the frozen data without advancing. This
 // covers a lost/corrupt UART response, including page zero across a frame edge.
 wire [3:0] status_page=operation==8'ha4 ? received[19:16]:{2'd0,received[1:0]};
 // All status commands share one frozen-page mux. Page zero also passes this
 // stage, avoiding separate wide bypass networks for five backend records.
 // Pages are fixed 24B lanes. A shared one-hot decode avoids synthesizing
 // a variable 192-bit alignment/barrel network for the twelve legal pages.
 reg [191:0] frozen_page;integer read_page_index;
 always @*begin
  frozen_page=0;
  for(read_page_index=0;read_page_index<SNAPSHOT_PAGES;read_page_index=read_page_index+1)
   frozen_page=frozen_page | (status_snapshot[read_page_index*192+:192] & {192{status_page==read_page_index}});
 end
 wire entity_page_retry=have_snapshot && snapshot_operation==8'ha4 &&
  readback_kind==received[15:0] && entity_last_sequence==reply_seq && entity_last_page==received[23:16];
 // Operation and kind are mutually exclusive selections, so decode once
 // and combine in parallel instead of cascading wide priority multiplexers.
 wire [2303:0] selected_entity_status=
   ({2304{operation==8'ha4 && received[15:0]==10}} & {1536'd0,affine_status}) |
   ({2304{operation==8'ha4 && received[15:0]==9}} & {1536'd0,reference_status}) |
   ({2304{operation==8'ha4 && received[15:0]!=9 && received[15:0]!=10}} & generic_read_status) |
   ({2304{operation==8'h95}} & {1536'd0,geometry_status}) |
   ({2304{operation==8'h90}} & {1536'd0,control_status}) |
   ({2304{operation==8'ha8}} & {1536'd0,pose_status});
 // Schema 2 generic readback retains identity, version, pending/error and
 // the actual applied source frame. No parameter body is returned or stored.
 // Reference/affine and legacy status/geometry retain their complete records
 // because the PC needs them for dynamic control and adoption confirmation.
 wire [2303:0] generic_read_status=SUMMARY_READBACK?
  {2048'd0,entity_status[255:112],16'd0,entity_status[95:16],16'd2}:entity_status;
 // STREAM_CCM is an internal proof; command formats and COMMIT timing stay unchanged.
 pc_reference_upload #(.ENTITY_MASK(ENTITY_MASK),.UNQUALIFIED_SUBMIT(1),.STREAM_CCM(STREAM_CCM)) upload(.clk(clk),.rst_n(rst_n),.now_us(now_us),
  .request_valid(state==ENTITY_REQUEST),.request_ready(entity_request_ready),.command(operation),
  .length(collect_length),.payload(received),.response_valid(entity_response_valid),
  .response_ready(state==ENTITY_WAIT),.response_code(entity_response_code),
  .transaction(entity_transaction),.accepted_bytes(entity_frontier),
  .reference_submit_valid(upload_submit),.reference_entity(reference_entity),
  .entity_kind(entity_kind),.entity_body(entity_body),.entity_length(entity_length),
  .reference_version(reference_version),.reference_id(reference_entity_id),.reference_code(consumer_code));
 assign runtime_action_valid=state==ACTION_SUBMIT,runtime_action=received[15:0],runtime_action_seq=reply_seq;
 assign affine_submit_valid=state==AFFINE_SUBMIT;
 assign affine_payload=received[95:0],affine_sequence=reply_seq;
 assign pose_request_valid=state==POSE_WAIT;
 assign pose_body=received[415:0],pose_sequence=reply_seq;
 assign geometry_submit_valid=state==GEOMETRY_SUBMIT;
 assign geometry_submit=received[607:64],geometry_version=received[31:0],geometry_entity_id=received[63:32];
 // Validate all 19 signed words and CRC32 over the first 76 payload bytes.
 // These are the supported fixed-point implementation bounds, not an optical
 // calibration certificate. Capability bit4 admits a full projective row;
 // legacy profiles still require the canonical affine row. CRC/ranges remain mandatory.
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
  .format_supported(received[31:0]>geometry_status[576+:32] && received[63:32]!=0 && (PROJECTIVE || (received[543:512]==0 && received[575:544]==0 && received[607:576]==32'h04000000))),
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
 // The UART parser fills one byte at a time. Explicit byte enables avoid a
 // wide read/modify/write mux over the 80-byte collected command payload.
 genvar command_byte;
 generate for(command_byte=0;command_byte<80;command_byte=command_byte+1)begin:command_bytes
  reg [7:0] value;
  assign received[command_byte*8+:8]=value;
  always @(posedge clk or negedge rst_n)
   if(!rst_n)value<=0;
   else if(read_response && index==command_byte)value<=read_data;
 end endgenerate
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
   reply<=0;reply_seq<=0;reply_cmd<=0;tx_crc<=16'hffff;configured<=0;
   readback_kind<=0;next_entity_page<=0;entity_last_sequence<=0;entity_last_page<=0;collect_length<=0;operation<=0;have_snapshot<=0;snapshot_operation<=0;
   epoch<=0;local_mac<=0;peer_mac<=0;local_ip<=0;peer_ip<=0;local_port<=0;peer_port<=0;us_divider<=0;now_us<=0;end
  else begin
   if(us_divider==124)begin us_divider<=0;now_us<=now_us+1'b1;end else us_divider<=us_divider+1'b1;
   if(read_valid)waiting<=1;
   if(read_response)begin waiting<=0;
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
     end else if(operation==8'ha5 && (received[15:0]==3 || received[15:0]==4))begin
      if(received[63:16]!=0)begin reply[7:0]<=11;reply_cmd<=8'h81;end
      else if((received[15:0]==3 && !ENTITY_MASK[4]) || (received[15:0]==4 && !ENTITY_MASK[6]))begin reply[7:0]<=6;reply_cmd<=8'h81;end
      else state<=ACTION_SUBMIT;
     end else if(operation==8'ha1 || operation==8'ha2 || operation==8'ha3 || operation==8'ha5)begin
      state<=ENTITY_REQUEST;
     end else if(operation==8'ha7 && RAW_POSE)begin
      state<=POSE_WAIT;
     end else if(operation==8'ha6)begin
      reply[63:32]<=received[63:32];
      if(affine_submit_code!=0)begin reply[7:0]<=affine_submit_code;reply_cmd<=8'h81;end
      else state<=AFFINE_SUBMIT;
     end else if(operation==8'ha0)begin
      // Capability bit2 is reference upload. C algorithms remain clear until
      // their complete runtime paths are connected and verified.
      reply_cmd<=received[7:0]==0?8'h80:8'h81;
      reply[7:0]<=received[7:0]==0?0:11;reply[31:24]<=24;
      reply[63:32]<=32'h31474641;reply[79:64]<=1;reply[95:80]<=1;
      // Bit3 selects summary readback; bit6 means fixed grayscale with a
      // 192 knee and half-slope highlights, without tone/colour/exposure writes.
      reply[127:96]<=(SUMMARY_READBACK?32'h0000000d:32'h00000005) | (PROJECTIVE?32'h00000010:32'd0) | (RAW_POSE?32'h00000020:32'd0) | (FIXED_GRAY?32'h00000040:32'd0);reply[159:128]<={16'd0,ENTITY_MASK | 16'h0600};
      reply[175:160]<=UPLOAD_BYTES;reply[183:176]<=64;reply[191:184]<=1;
      reply[255:224]<=32'h31474641;
     end else if(operation==8'ha4)begin
      reply[23:16]<=received[23:16];reply[31:24]<=24;reply[255:224]<=32'h31474641;
      if(!read_kind_legal || received[31:24]!=0 || received[23:16]>=page_count(received[15:0]) ||
         (received[23:16]!=0 && !entity_page_retry && (!have_snapshot || snapshot_operation!=operation || readback_kind!=received[15:0] || next_entity_page!=received[23:16])))begin
       reply[7:0]<=11;reply_cmd<=8'h81;
      end else begin
       reply_cmd<=8'h80;
       state<=PAGE_REPLY;
       if(!entity_page_retry)begin
        entity_last_sequence<=reply_seq;entity_last_page<=received[23:16];
        if(received[23:16]==0)begin
         have_snapshot<=1;snapshot_operation<=operation;
         readback_kind<=received[15:0];next_entity_page<=1;
        end else next_entity_page<=next_entity_page+1'b1;
       end
      end
     end else if(operation==8'h90 || operation==8'h95 || operation==8'ha8)begin
      reply[23:16]<=received[7:0];reply[31:24]<=24;reply[255:224]<=32'h31424752;
      if(received[7:0]>=4 || (received[7:0]!=0 && (!have_snapshot || snapshot_operation!=operation)))begin reply[7:0]<=11;reply_cmd<=8'h81;end
      else begin
       reply[7:0]<=0;reply_cmd<=8'h80;
       // Freeze the 96-byte status entity at page zero for coherent readback.
       if(received[7:0]==0)begin have_snapshot<=1;snapshot_operation<=operation;end
       state<=PAGE_REPLY;
      end
     end else if(operation==8'h94)begin
      reply[63:32]<=received[31:0];reply[95:64]<=received[63:32];
      if(!geometry_submit_ready)begin reply[7:0]<=4;reply_cmd<=8'h81;end else state<=GUARD;
     end else begin
      // Received/validated is distinct from applied. The ACK reports a queued
      // mode entity; status page 1 supplies the actual capture epoch/frame.
      reply[63:32]<=received[47:16];
      if(FIXED_GRAY || received[7:0]==2)begin reply[7:0]<=6;reply_cmd<=8'h81;end
      else if(received[7:0]>2 || received[47] || received[15:8]!=0 || received[47:16]<=control_status[320+:32])begin reply[7:0]<=11;reply_cmd<=8'h81;end
      else state<=MODE_CHECK;
     end
    end
    POSE_WAIT:if(pose_response_valid)begin
     reply[7:0]<=pose_response_code;reply_cmd<=pose_response_code==0?8'h80:8'h81;
     reply[23:16]<=pose_response_code==0?2:0;reply[63:32]<=received[31:0];state<=SEND;
    end
    PAGE_REPLY:begin reply[223:32]<=frozen_page;state<=SEND;end
    ENTITY_REQUEST:if(entity_request_ready)state<=ENTITY_WAIT;
    ENTITY_WAIT:if(entity_response_valid)begin
     reply[7:0]<=entity_response_code;reply_cmd<=entity_response_code==0?8'h80:8'h81;
     reply[23:16]<=entity_response_code==0 ? (operation==8'ha3 ? 2:1):0;
     reply[63:32]<=entity_transaction;reply[79:64]<=entity_frontier;
     reply[127:96]<=reference_version;reply[159:128]<=reference_entity_id;state<=SEND;
    end
    ACTION_SUBMIT:begin
     reply[7:0]<=runtime_action_code;reply_cmd<=runtime_action_code==0?8'h80:8'h81;
     reply[23:16]<=runtime_action_code==0?2:0;state<=SEND;
    end
    AFFINE_SUBMIT:begin
     // Recheck arbitration at the actual acceptance edge, including retries.
     reply[7:0]<=affine_submit_code;reply_cmd<=affine_submit_code==0?8'h80:8'h81;
     reply[23:16]<=affine_submit_code==0?2:0;state<=SEND;
    end
    GUARD:if(guard_ready)state<=GUARD_WAIT;
    GUARD_WAIT:if(guard_valid)begin
     if(!guard_accepted)begin reply[7:0]<=11;reply_cmd<=8'h81;state<=SEND;end
     else if(!geometry_submit_ready)begin reply[7:0]<=4;reply_cmd<=8'h81;state<=SEND;end
     else state<=GEOMETRY_SUBMIT;
    end
    GEOMETRY_SUBMIT:if(geometry_submit_ready)begin reply[7:0]<=0;reply[23:16]<=2;reply_cmd<=8'h80;state<=SEND;end
    // Separate the live consumer readiness path from the wide UART reply CE.
    // Readiness can depend on an unrelated entity validation network. Sample
    // arbitration into FSM state, recheck at the actual handshake, then emit
    // ACK one cycle later. MODE_DONE deasserts valid, so no duplicate submit.
    MODE_CHECK:if(mode_submit_ready)state<=SUBMIT;else state<=MODE_BUSY;
    MODE_BUSY:begin reply[7:0]<=4;reply_cmd<=8'h81;state<=SEND;end
    SUBMIT:if(mode_submit_ready)state<=MODE_DONE;
    MODE_DONE:begin reply[7:0]<=0;reply[23:16]<=2;reply_cmd<=8'h80;state<=SEND;end
    SEND:begin tx_active<=1;tx_index<=0;tx_crc<=16'hffff;state<=TRANSMIT;end
    DRAIN:if(uart_ready)begin if(accepted || configured)begin configured<=1;state<=RUN;end else state<=IDLE;end
    RUN:if(packet_valid)begin
     if(supported)begin index<=0;waiting<=0;state<=COLLECT;reply_seq<=seq;operation<=command;collect_length<=length[6:0];end
     else begin reply<=0;reply[7:0]<=6;reply[15:8]<=command;reply_cmd<=8'h81;reply_seq<=seq;accepted<=0;state<=SEND;end
    end
   endcase
  end
 end

 // Private readback storage is overwritten in full on accepted page zero.
 // Reset clears have_snapshot/state, so no page can expose its uninitialized
 // payload. Keep the exact original capture edge and last-page retry freeze;
 // removing the payload reset reduces reset/control-set routing pressure.
 wire capture_status_snapshot=state==CHECK &&
  (((operation==8'h90 || operation==8'h95 || operation==8'ha8) && received[7:0]==0) ||
   (operation==8'ha4 && read_kind_legal && received[31:24]==0 &&
    received[23:16]==0 && page_count(received[15:0])!=0 && !entity_page_retry));
 always @(posedge clk) if(rst_n && capture_status_snapshot)
  status_snapshot<=selected_entity_status;
endmodule

`timescale 1ns/1ps
// Board-only MCU boundary: UART, externally allocated session range, explicit
// configuration evidence, and latest-event mailbox in the 125MHz memory domain.
// No policy is approved at reset. PC grants must be persisted across FPGA reset;
// overlapping ranges are also rejected within this FPGA lifetime.
module mcu_link_adapter #(parameter CLK_HZ=125000000,BAUD=460800,CONFIG_DIGEST_ONLY=0)(
 input clk,rst_n,commissioned,input uart_rx,output uart_tx,
 input submit_valid,input [511:0] body,input [31:0] version,entity_id,
 output [7:0] submit_code,output reg [2303:0] status,
 output enable,rx_valid,rx_error,output [7:0] rx_data,
 input tx_valid,input [7:0] tx_data,output tx_ready,
 output [31:0] new_session,output timing_valid,output [31:0] capture_error,
 input config_valid,input [2111:0] config_entity,input [31:0] config_version,config_crc32,
 output config_ready,config_approved,input reopen_required,
 input session_valid,mapping_valid,input [63:0] boot_id,
 input event_valid,input [319:0] event_payload,output event_ready
);
 reg [511:0] active;
 reg [31:0] active_version,active_id,session,last_reserved;
 reg [31:0] reconnects,rx_bytes,rx_errors,event_count,last_event_id;
 reg [319:0] last_event;
 reg blocked,rotating,scanning,checked,matched;
 reg [1:0] reset_guard;
 reg [8:0] cursor;
 reg [31:0] crc,observed_crc,observed_version;
 reg [63:0] observed_boot;
 reg [7:0] error_code;
 wire uart_ready;
 wire requested=body[0];
 wire policy_ok=body[7:0]<=1 && body[15:8]<=1 && body[23:16]<=1 &&
   body[31:24]==0 && body[511:288]==0 && version!=0 && !version[31] &&
   version>active_version && entity_id!=0 && !entity_id[31] &&
   (!requested || (body[63:32]!=0 && body[63:32]>last_reserved && body[95:64]>=body[63:32])) &&
   (!body[8] || (requested && body[127:96]!=0 && body[191:128]!=0 && body[287:256]!=0)) &&
   (!body[16] || (requested && body[8] && body[255:224]<=1000 && body[287:256]!=0));
 assign submit_code=policy_ok?8'd0:8'd11;
 assign enable=commissioned && active[0] && !blocked && reset_guard==0;
 assign new_session=session;
 assign timing_valid=enable && active[16] && matched;
 assign capture_error=active[255:224];
 assign config_ready=enable && config_valid && checked && active[8];
 assign config_approved=matched;
 // Record the complete event before cumulative ACK. This latest-event mailbox
// is an explicit consumer, not a lossless external archival log.
 assign event_ready=enable && !submit_valid;
 assign tx_ready=uart_ready && enable;
 uart_8n1 #(.CLK_HZ(CLK_HZ),.BAUD(BAUD)) uart(.clk(clk),.rst_n(rst_n),
   .rx(uart_rx),.tx(uart_tx),.rx_valid(rx_valid),.rx_data(rx_data),.framing_error(rx_error),
   .tx_valid(tx_valid && enable),.tx_ready(uart_ready),.tx_data(tx_data));
 function [31:0] crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer j;begin v=c^b;for(j=0;j<8;j=j+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc_byte=v;end
 endfunction
 wire [31:0] next_crc=crc_byte(crc,config_entity[cursor*8+:8]);
 // Existing A4 freezes header32 + policy64 + diagnostics96 = eight pages.
 always @* begin
  status=0;status[15:0]=1;status[31:16]=12;
  status[63:32]=active_version;status[95:64]=active_id;status[111:96]=160;
  status[112]=active_version!=0;status[120+:8]=error_code;status[256+:512]=active;
  status[768+:7]={scanning,blocked,matched,config_valid,mapping_valid,session_valid,enable};
  status[800+:8]=error_code;status[832+:32]=observed_crc;status[864+:32]=observed_version;
  status[896+:64]=observed_boot;status[960+:32]=session;status[992+:32]=reconnects;
  status[1024+:32]=rx_bytes;status[1056+:32]=rx_errors;status[1088+:32]=event_count;
  status[1120+:32]=last_event_id;status[1152+:320]=last_event;status[1472+:32]=last_reserved;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   active<=0;active_version<=0;active_id<=0;session<=0;last_reserved<=0;
   reconnects<=0;rx_bytes<=0;rx_errors<=0;event_count<=0;last_event_id<=0;last_event<=0;
   blocked<=0;rotating<=0;scanning<=0;checked<=0;matched<=0;reset_guard<=0;
   cursor<=0;crc<=32'hffffffff;observed_crc<=0;observed_version<=0;observed_boot<=0;error_code<=0;
  end else begin
   if(rx_valid && rx_bytes!=32'hffffffff)rx_bytes<=rx_bytes+1'b1;
   if(rx_error && rx_errors!=32'hffffffff)rx_errors<=rx_errors+1'b1;
   if(reset_guard!=0)reset_guard<=reset_guard-1'b1;
   if(!reopen_required)rotating<=0;
   if(!config_valid)begin scanning<=0;checked<=0;end
   // The client holds its complete entity until ready. Approval binds all
   // bytes by CRC plus boot/version and the externally archived evidence ID.
   if(enable && config_valid && !scanning && !checked)begin
    scanning<=!CONFIG_DIGEST_ONLY;cursor<=0;crc<=32'hffffffff;matched<=0;
    observed_boot<=boot_id;observed_version<=config_version;
    // The board client publishes this CRC only after all264 borrowed bytes
    // have passed context/length checks. No configuration byte is omitted.
    if(CONFIG_DIGEST_ONLY)begin
     checked<=1;observed_crc<=config_crc32;
     matched<=active[8] && boot_id==active[191:128] && config_version==active[127:96] &&
       config_entity[31:0]==config_version && config_crc32==active[223:192];
    end
   end else if(scanning && config_valid)begin
    crc<=next_crc;
    if(cursor==263)begin
     scanning<=0;checked<=1;observed_crc<=~next_crc;
     matched<=active[8] && boot_id==active[191:128] && config_version==active[127:96] &&
       config_entity[31:0]==config_version && ~next_crc==active[223:192];
    end else cursor<=cursor+1'b1;
   end
   if(config_ready && !matched)begin blocked<=1;error_code<=3;end
   if(enable && reopen_required && !rotating)begin
    matched<=0;checked<=0;scanning<=0;rotating<=1;
    if(session<active[95:64])begin session<=session+1'b1;if(reconnects!=32'hffffffff)reconnects<=reconnects+1'b1;end
    else begin blocked<=1;error_code<=2;end
   end
   if(event_valid && event_ready)begin
    last_event<=event_payload;last_event_id<=event_payload[127:96];
    if(event_count!=32'hffffffff)event_count<=event_count+1'b1;
   end
   // COMMIT fences old replies; reserve the entire range to prevent overlaps.
   if(submit_valid && submit_code==0)begin
    active<=body;active_version<=version;active_id<=entity_id;session<=body[63:32];
    if(requested)last_reserved<=body[95:64];
    blocked<=0;rotating<=0;scanning<=0;checked<=0;matched<=0;reset_guard<=3;error_code<=0;
   end
  end
 end
endmodule

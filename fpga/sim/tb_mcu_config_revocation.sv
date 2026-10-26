`timescale 1ns/1ps
// Byte-link MCU peer model validates complete request frames, CRC, read-only
// opcodes and exact retries. UART wire time is modeled at 500k for exact 20us
// bit-frame duration; default 460800 electrical behavior is tested separately.
module tb_mcu_config_revocation #(parameter DIGEST_ONLY=0,REVOKE_STAGE=0,REVOKE_OVERFLOW=0);
 reg clk=0;always #4 clk=~clk;reg rst_n=0,enable=1;reg [63:0] now_us=0;
 always @(posedge clk) now_us<=now_us+1;
 reg [31:0] new_session=100;
 reg rx_valid=0,rx_error=0,tx_ready=0;reg [7:0] rx_data=0;
 wire tx_valid;wire [7:0] tx_data;wire session_valid,config_valid,state_valid,event_valid,mapping_valid,reopen_required;
 wire [63:0] boot_id,state_receive_us,sync_received_us;wire [31:0] session_id,config_version,clock_error_us;
 wire [2111:0] config_entity;wire [767:0] state_payload;wire [319:0] event_payload;
 wire [31:0] config_crc32;
 wire signed [63:0] clock_offset_us;
 wire [31:0] bad_crc,bad_header,timeouts,overflows,rejected_states,rejected_replies,reconnects,event_drops;
 reg config_ready=1,config_approved=1,event_ready=1;
 reg timing_bound_valid=1;reg [31:0] capture_error_us=0;
 reg [7:0] request [0:63],previous [0:63],golden [0:105];
 integer pos=0,request_count=0,state_count=0,tx_div=0,i,n;
 reg [7:0] last_cmd=0;reg [15:0] last_seq=0;reg [63:0] request_t1=0;
 reg [2239:0] p;reg [15:0] crc;reg [63:0] t2,t3;
 mcu_readonly_client #(.BAUD(500000),.CONFIG_DIGEST_ONLY(DIGEST_ONLY)) dut(.*);
 function automatic [15:0] update(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};for(j=0;j<8;j=j+1) v=(v<<1)^(v[15]?16'h1021:0);update=v;end
 endfunction
 always @(negedge clk) begin tx_ready=(tx_div==0);tx_div=(tx_div+1)%20;end
 always @(posedge clk) if(rst_n) begin
  if(dut.process_packet && dut.packet_cmd==8'h82 && $test$plusargs("debug"))
   $display("sync t1=%0d t2=%0d t3=%0d t4=%0d a=%0d b=%0d rtt=%0d reqseq=%0d pktseq=%0d sid=%0d syncid=%0d",dut.t1,dut.t2,dut.t3,dut.receive_time,dut.a_offset,dut.b_offset,dut.corrected_rtt,dut.request_seq,dut.packet_seq,dut.received[64+:32],dut.received[96+:32]);
  if(state_valid) state_count=state_count+1;
  if(tx_valid && tx_ready) begin
   request[pos]=tx_data;
   if(pos==0) request_t1=now_us;
   if(pos>=9 && pos==request[6]+9) begin
    crc=16'hffff;for(n=2;n<pos-1;n=n+1) crc=update(crc,request[n]);
    if(request[0]!=8'h55 || request[1]!=8'haa || request[2]!=2 || {request[pos],request[pos-1]}!=crc) $fatal(1,"TX wire CRC");
    last_cmd=request[3];last_seq={request[5],request[4]};request_count=request_count+1;pos=0;
    if(last_cmd!=8'h40 && last_cmd!=8'h41 && last_cmd!=8'h42 && last_cmd!=8'h43 && last_cmd!=8'h45 && last_cmd!=8'h49) $fatal(1,"movement permission escaped");
   end else pos=pos+1;
  end
 end
 task send_byte(input [7:0] b);
  begin repeat(19) @(negedge clk);rx_data=b;rx_valid=1;@(negedge clk);rx_valid=0;end
 endtask
 task reply(input [7:0] command,input [15:0] s,input integer len,input [2239:0] payload);
  reg [15:0] c;reg [7:0] b;integer j;
  begin
   send_byte(8'h55);send_byte(8'haa);c=16'hffff;
   for(j=0;j<len+6;j=j+1) begin
    case(j)
     0:b=2;1:b=command;2:b=s[7:0];3:b=s[15:8];4:b=len&255;5:b=(len>>8)&255;
     default:b=payload[(j-6)*8+:8];
    endcase
    c=update(c,b);send_byte(b);
   end
   send_byte(c[7:0]);send_byte(c[15:8]);
  end
 endtask
 task common_reply(input [7:0] command,input integer len,input [2239:0] data);
  begin
   p=data<<128;p[0+:64]=11;p[64+:32]=(command==8'h40)?0:new_session;p[96+:8]=command;
   reply(8'h80,last_seq,len+16,p);
  end
 endtask
 // Exercise request, response and publish edges separately. Framing loss is
 // injected at the UART input; the overflow variant injects a full ring state
 // plus a real incoming byte to exercise the same-edge capacity-loss fence.
 initial begin
  config_ready=0;repeat(5) @(negedge clk);rst_n=1;
  wait(last_cmd==8'h40);p=0;p[112+:16]=16'h4d32;p[128+:32]=1000000;p[160+:32]=32'h31;
  p[192+:16]=1024;p[208+:16]=200;p[224+:16]=30;common_reply(8'h40,48,p);
  wait(last_cmd==8'h41);p=1;common_reply(8'h41,8,p);
  wait(last_cmd==8'h42);
  fork
   begin p=1;common_reply(8'h42,264,p);end
   begin
    if(REVOKE_STAGE==0)wait(dut.collecting && dut.read_index==279 && dut.read_valid);
    else if(REVOKE_STAGE==1)wait(dut.collecting && dut.read_index==279 && dut.read_response);
    else wait(dut.process_packet && dut.packet_cmd==8'h80 && dut.packet_length==280);
    @(negedge clk);
    if(REVOKE_OVERFLOW)begin force dut.parser.occupancy=12'd2048;rx_valid=1;rx_data=0;end
    else rx_error=1;
    @(negedge clk);rx_error=0;rx_valid=0;
    if(REVOKE_OVERFLOW)release dut.parser.occupancy;
   end
  join
  repeat(10)@(negedge clk);
  $display("REVOCATION_OBSERVATION digest=%0d stage=%0d ring_overflow=%0d errors=%0d config_valid=%0d packet_valid=%0d config_crc=%08h",DIGEST_ONLY,REVOKE_STAGE,REVOKE_OVERFLOW,overflows,config_valid,dut.packet_valid,config_crc32);
  if(overflows!=1)$fatal(1,"test did not revoke parser borrow");
  if(config_valid)$fatal(1,"revoked CONFIG was published");
  $display("MCU_CONFIG_REVOCATION_PASS");$finish;
 end
 initial begin #2000000;$fatal(1,"revocation test timeout");end
endmodule

`timescale 1ns/1ps
// Byte-link MCU peer model validates complete request frames, CRC, read-only
// opcodes and exact retries. UART wire time is modeled at 500k for exact 20us
// bit-frame duration; default 460800 electrical behavior is tested separately.
module tb_mcu_readonly_client;
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
 // Accelerated model time retains room for the longest CONFIG frame while
 // exercising all three retry deadlines without millions of idle clocks.
 mcu_readonly_client #(.BAUD(500000),.REQUEST_TIMEOUT_US(20000),.SYNC_INTERVAL_US(50000)) dut(.*);
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
 initial begin
  $readmemh("state.hex",golden);repeat(5) @(negedge clk);rst_n=1;
  wait(last_cmd==8'h40);p=0;p[112+:16]=16'h4d32;p[128+:32]=1000000;
  p[192+:16]=1024;p[208+:16]=200;p[224+:16]=30;
  // Missing state/SYNC/persistent-boot capabilities cannot establish identity.
  common_reply(8'h40,48,p);repeat(300) @(negedge clk);
  if(boot_id!=0 || session_valid) $fatal(1,"unsupported capabilities admitted");
  p=0;p[112+:16]=16'h4d32;p[128+:32]=1000000;p[160+:32]=32'h31;
  p[192+:16]=1024;p[208+:16]=200;p[224+:16]=30;
  common_reply(8'h40,48,p);
  wait(last_cmd==8'h41);if({request[15],request[14],request[13],request[12]}!=11) $fatal(1,"OPEN boot");
  p=1;common_reply(8'h41,8,p);
  wait(last_cmd==8'h42);p=1;common_reply(8'h42,264,p);
  wait(last_cmd==8'h43);p=200;common_reply(8'h43,4,p);
  wait(last_cmd==8'h45);
  repeat(20) @(negedge clk);t2=now_us;t3=now_us+3;
  p=0;p[0+:64]=11;p[64+:32]=100;p[96+:32]=1;
  for(i=0;i<8;i=i+1) p[128+i*8+:8]=request[24+i];
  p[192+:64]=t2;p[256+:64]=t3;
  repeat(3) @(negedge clk);reply(8'h82,last_seq,40,p);
  repeat(300) @(negedge clk);
  if(!session_valid || !mapping_valid || clock_error_us>5) $fatal(1,"session/time mapping valid=%b error=%0d",mapping_valid,clock_error_us);
  p=0;for(i=0;i<96;i=i+1) p[i*8+:8]=golden[i+8];reply(8'h81,7,96,p);
  repeat(300) @(negedge clk);if(state_count!=1) $fatal(1,"STATE not admitted");
  reply(8'h81,7,96,p);p[0+:64]=10;p[128+:32]=8;reply(8'h81,8,96,p);
  repeat(300) @(negedge clk);if(state_count!=1 || rejected_states!=2) $fatal(1,"old state overwrote current");
  p[0+:64]=11;p[128+:32]=8;reply(8'h81,8,96,p);repeat(300) @(negedge clk);
  if(state_count!=2) $fatal(1,"fresh STATE rejected");
  // Consume event2 while ACK(event1) is pending; the response must match the
  // immutable transmitted watermark and allow a subsequent ACK(event2).
  p=0;p[0+:64]=11;p[64+:32]=100;p[96+:32]=1;p[224+:16]=1;p[256+:32]=1;
  reply(8'h90,1,40,p);wait(request_count==6);
  if(last_cmd!=8'h49 || request[20]!=1) $fatal(1,"first event ACK");
  p=0;p[0+:64]=11;p[64+:32]=100;p[96+:32]=2;p[224+:16]=2;p[256+:32]=1;
  reply(8'h90,2,40,p);p=1;common_reply(8'h49,4,p);wait(request_count==7);
  if(last_cmd!=8'h49 || request[20]!=2) $fatal(1,"new event blocked old ACK");
  p=2;common_reply(8'h49,4,p);
  // A backpressured event must be revoked when the session times out.
  event_ready=0;p=0;p[0+:64]=11;p[64+:32]=100;p[96+:32]=3;
  reply(8'h90,3,40,p);wait(event_valid);
  // SYNC timeout produces two byte-identical retries, then demands fresh session.
  wait(request_count==8);
  for(i=0;i<34;i=i+1) previous[i]=request[i];
  wait(request_count==9);for(i=0;i<34;i=i+1) if(previous[i]!=request[i]) $fatal(1,"retry changed request");
  wait(request_count==10);for(i=0;i<34;i=i+1) if(previous[i]!=request[i]) $fatal(1,"second retry changed request");
  wait(reopen_required);if(session_valid || mapping_valid || event_valid) $fatal(1,"failed session retained");
  new_session=101;wait(request_count==11);if(last_cmd!=8'h40) $fatal(1,"new session did not discover profile");
  p=0;p[112+:16]=16'h4d32;p[128+:32]=1000000;p[160+:32]=32'h31;
  p[192+:16]=1024;p[208+:16]=200;p[224+:16]=30;common_reply(8'h40,48,p);
  wait(request_count==12);p=1;common_reply(8'h41,8,p);
  wait(request_count==13);config_ready=0;p=1;common_reply(8'h42,264,p);wait(config_valid);
  @(negedge clk);new_session=102;config_ready=1;
  wait(request_count==14);
  if(last_cmd!=8'h40 || session_valid || config_valid) $fatal(1,"old config approval crossed session rotation");
  // Reestablish the new session, then disable with an unconsumed event.
  p=0;p[112+:16]=16'h4d32;p[128+:32]=1000000;p[160+:32]=32'h31;
  p[192+:16]=1024;p[208+:16]=200;p[224+:16]=30;common_reply(8'h40,48,p);
  wait(request_count==15);p=1;common_reply(8'h41,8,p);
  wait(request_count==16);p=1;common_reply(8'h42,264,p);
  wait(request_count==17);p=200;common_reply(8'h43,4,p);
  wait(request_count==18);p=0;p[0+:64]=11;p[64+:32]=102;p[96+:32]=1;
  reply(8'h90,1,40,p);wait(event_valid);
  @(negedge clk);enable=0;repeat(3)@(negedge clk);
  if(event_valid || session_valid || mapping_valid)$fatal(1,"disable retained event/session");
  $display("MCU_READONLY_CLIENT_PASS states=%0d rejected=%0d retries=2 events=2 session_fence=1",state_count,rejected_states);$finish;
 end
 initial begin #20000000;$fatal(1,"client timeout");end
endmodule

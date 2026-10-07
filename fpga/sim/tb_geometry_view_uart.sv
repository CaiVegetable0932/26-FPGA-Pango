`timescale 1ns/1ps
// Purpose: exercise DISPLAY_CONTROL capability and 0x35 through physical UART
// pins including CRC, length, session, retries and pre-application response.
module tb_geometry_view_uart;
 parameter DISPLAY=1;
 localparam real BIT_NS=1.0e9/115200;
 reg clk=0,rst_n=0,rx=1;always #(1.0e9/1843200/2)clk=~clk;
 wire tx,context_valid,command_valid;wire [31:0] session_id;
 wire [7:0] command,code;wire [255:0] payload;wire [95:0] reply;
 wire [31:0] frame_revision,frame_packed;
 mcu_protocol #(.CLK_HZ(1843200),.GEOMETRY_CONTROL(1),.DISPLAY_CONTROL(DISPLAY)) dut(
  .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.link_epoch(64'd7),.link_epoch_valid(1'b1),
  .board_time_us(64'd0),.status_flags(32'd0),.board_diagnostics(96'd0),.video_diagnostics(96'd0),.chain_diagnostics(288'd0),
  .session_active(context_valid),.current_session_id(session_id),.geometry_command_valid(command_valid),
  .geometry_command(command),.geometry_payload(payload),.geometry_code(code),.geometry_reply(reply),
  .env_valid(),.env_session_id(),.env_event_seq(),.env_mcu_time_us(),.env_board_time_us(),
  .env_lux_milli(),.env_angle_mdeg(),.env_measurement_valid(),.rx_good_count(),.rx_error_count(),.tx_overflow_count());
 geometry_view_control control(clk,rst_n,context_valid,64'd7,session_id,command_valid,command,payload,1'b0,
  32'd0,32'd2560,code,reply,frame_revision,frame_packed);
 integer responses=0,expected=0,n;reg [255:0] received[0:31];reg [255:0] request_payload,last;
 function [15:0] crc_byte(input [15:0] prior,input [7:0] value);
  integer k;reg [15:0] c;begin c=prior;
   for(k=7;k>=0;k=k-1)begin if(c[15]^value[k])c=(c<<1)^16'h1021;else c=c<<1;end
   crc_byte=c;end
 endfunction
 task check(input bit ok,input string label_text);begin if(!ok)$fatal(1,"VIEW_UART_FAIL %s",label_text);end endtask
 task octet(input [7:0] value);integer k;begin
  rx=0;#(BIT_NS);for(k=0;k<8;k=k+1)begin rx=value[k];#(BIT_NS);end rx=1;#(BIT_NS);
 end endtask
 task send(input [7:0] op,input integer length,input bit corrupt);
  integer k;reg [15:0] crc;reg [7:0] v;begin
   octet(8'h55);octet(8'haa);crc=16'hffff;
   for(k=0;k<6+length;k=k+1)begin
    case(k)0:v=1;1:v=op;2:v=expected;3:v=0;4:v=length;5:v=0;default:v=request_payload[(k-6)*8+:8];endcase
    crc=crc_byte(crc,v);octet(v);
   end
   if(corrupt)crc=crc^1;octet(crc[7:0]);octet(crc[15:8]);
  end
 endtask
 // Independent TX decoder verifies every response CRC before recording it.
 initial begin:monitor
  reg [7:0] v;reg [255:0] p;reg [15:0] crc;reg [7:0] crc_low;integer k,offset;
  offset=0;p=0;crc=16'hffff;
  forever begin
   @(negedge tx);#(BIT_NS/2);
   for(k=0;k<8;k=k+1)begin #(BIT_NS);v[k]=tx;end
   #(BIT_NS);check(tx==1,"stop bit");
   if(offset==0)check(v==8'h55,"sync55");if(offset==1)check(v==8'haa,"syncaa");
   if(offset==2)crc=16'hffff;
   if(offset>=2 && offset<40)crc=crc_byte(crc,v);
   if(offset>=8 && offset<40)p[(offset-8)*8+:8]=v;
   if(offset==40)crc_low=v;
   if(offset==41)begin check({v,crc_low}==crc,"response CRC");received[responses]=p;responses=responses+1;offset=0;end
   else offset=offset+1;
  end
 end
 task expect_code(input [7:0] wanted);begin
  wait(responses>expected);last=received[expected];expected=expected+1;
  check(last[7:0]==wanted,$sformatf("code expected %0d got %0d",wanted,last[7:0]));
 end endtask
 initial begin
  repeat(6)@(negedge clk);rst_n=1;repeat(6)@(negedge clk);
  request_payload=0;send(1,0,0);expect_code(0);
  check(last[223:192]==(DISPLAY?32'h18f:32'h8f),"CAPS preserves 0x80 and independently gates 0x100");
  request_payload=0;request_payload[63:0]=7;request_payload[95:64]=3;send(2,12,0);expect_code(0);
  request_payload[127:96]=1;request_payload[159:128]=3;request_payload[191:160]=10;
  send(8'h35,24,0);expect_code(DISPLAY?0:6);
  if(DISPLAY)begin
   check(last[191:160]==1 && last[223:192]==0 && last[255:224]==2560,"12-byte request/applied revision packed reply");
   send(8'h35,24,0);expect_code(1);
   request_payload[159:128]=2;send(8'h35,24,0);expect_code(10);
   request_payload[127:96]=2;request_payload[159:128]=4;send(8'h35,24,0);expect_code(11);
   request_payload[159:128]=2;send(8'h35,20,0);expect_code(3);
   request_payload[95:64]=4;send(8'h35,24,0);expect_code(8);
   request_payload[95:64]=3;request_payload[63:0]=8;send(8'h35,24,0);expect_code(7);
   request_payload[63:0]=7;send(8'h35,24,1);expect_code(2);
   send(8'h35,24,0);expect_code(0);
   check(frame_revision==0 && frame_packed==2560,"UART requests cannot mutate current frame");
  end
  $display("GEOMETRY_VIEW_UART_PASS display=%0d responses=%0d",DISPLAY,responses);$finish;
 end
 initial begin #200000000;$fatal(1,"VIEW_UART_TIMEOUT");end
endmodule

`timescale 1ns/1ps
// Actual 460800 pin waveforms carry immutable C-generated 22452f3 frames.
// now_us is synthetic/frozen; this proves transport and policy integration,
// never oscillator accuracy, a physical timing bound, or pose calibration.
module tb_mcu_uart_peer #(parameter DIGEST_ONLY=1);
 reg clk=0;always #4 clk=~clk;reg rst_n=0,serial_rx=1,submit=0;
 reg [511:0] policy=0;wire serial_tx,enable,rx_valid,rx_error,tx_valid,tx_ready;
 wire [7:0] rx_data,tx_data,code;wire [31:0] new_session,capture_error,config_version,session_id;
 wire timing_valid,config_valid,config_ready,config_approved,reopen_required;
 wire session_valid,mapping_valid,event_valid,event_ready,state_valid;
 wire [63:0] boot_id;wire [2111:0] config_entity;wire [319:0] event_payload;
 wire [2303:0] status;wire [767:0] state_payload;
 wire [31:0] config_crc32;
 reg [7:0] data[0:289],packet[0:63];integer count=0,pos=0,states=0;
 wire received;wire [7:0] received_byte;reg [7:0] last_cmd;
 mcu_link_adapter #(.CONFIG_DIGEST_ONLY(DIGEST_ONLY)) adapter(.clk(clk),.rst_n(rst_n),.commissioned(1'b1),
  .uart_rx(serial_rx),.uart_tx(serial_tx),.submit_valid(submit),.body(policy),
  .version(32'd1),.entity_id(32'd7),.submit_code(code),.status(status),
  .enable(enable),.rx_valid(rx_valid),.rx_error(rx_error),.rx_data(rx_data),
  .tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready),.new_session(new_session),
  .timing_valid(timing_valid),.capture_error(capture_error),.config_valid(config_valid),
  .config_entity(config_entity),.config_version(config_version),.config_crc32(config_crc32),.config_ready(config_ready),
  .config_approved(config_approved),.reopen_required(reopen_required),.session_valid(session_valid),
  .mapping_valid(mapping_valid),.boot_id(boot_id),.event_valid(event_valid),
  .event_payload(event_payload),.event_ready(event_ready));
 mcu_readonly_client #(.CONFIG_DIGEST_ONLY(DIGEST_ONLY)) client(.clk(clk),.rst_n(rst_n),.now_us(64'd1000000),
  .enable(enable),.new_session(new_session),.rx_valid(rx_valid),.rx_data(rx_data),.rx_error(rx_error),
  .timing_bound_valid(timing_valid),.capture_error_us(capture_error),
  .tx_valid(tx_valid),.tx_ready(tx_ready),.tx_data(tx_data),.session_valid(session_valid),
  .boot_id(boot_id),.session_id(session_id),.reopen_required(reopen_required),
  .config_valid(config_valid),.config_ready(config_ready),.config_approved(config_approved),
  .config_entity(config_entity),.config_version(config_version),.config_crc32(config_crc32),.state_valid(state_valid),
  .state_payload(state_payload),.event_valid(event_valid),.event_ready(event_ready),
  .event_payload(event_payload),.mapping_valid(mapping_valid));
 uart_8n1 decoder(.clk(clk),.rst_n(rst_n),.rx(serial_tx),.tx(),.rx_valid(received),
  .rx_data(received_byte),.framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 function [15:0] crc16(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};for(j=0;j<8;j=j+1)v=(v<<1)^(v[15]?16'h1021:0);crc16=v;end
 endfunction
 reg [15:0] wire_crc;integer k;
 always @(posedge clk)if(rst_n)begin
  if(state_valid)states=states+1;
  if(received)begin
   packet[pos]=received_byte;
   if(pos>=9 && pos==packet[6]+9)begin
    wire_crc=16'hffff;for(k=2;k<pos-1;k=k+1)wire_crc=crc16(wire_crc,packet[k]);
    if({packet[pos],packet[pos-1]}!=wire_crc)$fatal(1,"MCU pin TX CRC");
    last_cmd=packet[3];count=count+1;pos=0;
    if(last_cmd!=8'h40 && last_cmd!=8'h41 && last_cmd!=8'h42 &&
       last_cmd!=8'h43 && last_cmd!=8'h45 && last_cmd!=8'h49)$fatal(1,"movement command");
   end else pos=pos+1;
  end
 end
 task send(input [7:0] b);integer j;begin
  @(negedge clk);serial_rx=0;repeat(271)@(negedge clk);
  for(j=0;j<8;j=j+1)begin serial_rx=b[j];repeat(271)@(negedge clk);end
  serial_rx=1;repeat(280)@(negedge clk);
 end endtask
 task feed(input string filename,input integer size);integer j;begin
  $readmemh(filename,data,0,size-1);for(j=0;j<size;j=j+1)send(data[j]);
  repeat(2000)@(negedge clk);
 end endtask
 reg [31:0] c;integer i,j;
 initial begin
  // Bind approval to all 264 actual firmware configuration bytes (reply+16).
  $readmemh("config.hex",data,0,289);c=32'hffffffff;
  for(i=24;i<288;i=i+1)begin c=c^data[i];for(j=0;j<8;j=j+1)c=(c>>1)^(c[0]?32'hedb88320:0);end
  policy=0;policy[0]=1;policy[8]=1;policy[63:32]=100;policy[95:64]=101;
  policy[127:96]=1;policy[191:128]=11;policy[223:192]=~c;policy[287:256]=7;
  repeat(4)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
  if(enable || timing_valid)$fatal(1,"unsafe boot");
  submit=1;@(negedge clk);submit=0;
  wait(count==1);if(last_cmd!=8'h40)$fatal(1,"INFO");feed("info.hex",74);
  wait(count==2);if(last_cmd!=8'h41)$fatal(1,"OPEN");feed("open.hex",34);
  wait(count==3);if(last_cmd!=8'h42)$fatal(1,"CONFIG");feed("config.hex",290);
  wait(count==4);if(last_cmd!=8'h43 || !config_approved)$fatal(1,"CONFIG approval");feed("stream.hex",30);
  wait(count==5);if(last_cmd!=8'h45)$fatal(1,"SYNC");feed("sync.hex",50);
  feed("state.hex",106);
  if(states!=1 || state_payload[167] || mapping_valid || timing_valid)$fatal(1,"state/timing gate");
  feed("reconnect_event.hex",50);wait(count==6);
  if(last_cmd!=8'h49 || packet[20]!=1 || status[1088+:32]!=1 || status[1120+:32]!=1)
   $fatal(1,"event mailbox before ACK");
  $display("MCU_UART_PEER_PASS requests=6 C_configuration=264 state=1 event=1 timing_unapproved=1");$finish;
 end
 initial begin #30000000;$fatal(1,"UART peer timeout count=%0d",count);end
endmodule

`timescale 1ns/1ps
// Board policy tests use synthetic configuration evidence. They prove gating,
// session monotonicity, mismatch quarantine and real UART serialization only.
module tb_mcu_link_adapter;
 reg clk=0;always #4 clk=~clk;reg rst_n=0,commissioned=0;
 reg submit_valid=0;reg [511:0] body=0;reg [31:0] version=1,entity_id=1;
 wire [7:0] submit_code;wire [2303:0] status;
 wire enable,rx_valid,rx_error,tx_ready,timing_valid,config_ready,config_approved,event_ready;
 wire [7:0] rx_data;wire [31:0] new_session,capture_error;
 reg tx_valid=0;reg [7:0] tx_data=0;wire uart_tx;
 reg config_valid=0;reg [2111:0] config_entity=0;reg [31:0] config_version=1;
 reg reopen_required=0,session_valid=0,mapping_valid=0;reg [63:0] boot_id=11;
 reg event_valid=0;reg [319:0] event_payload=0;
 mcu_link_adapter dut(.clk(clk),.rst_n(rst_n),.commissioned(commissioned),.uart_rx(uart_tx),.uart_tx(uart_tx),
 .submit_valid(submit_valid),.body(body),.version(version),.entity_id(entity_id),.submit_code(submit_code),.status(status),
 .enable(enable),.rx_valid(rx_valid),.rx_data(rx_data),.rx_error(rx_error),.tx_valid(tx_valid),.tx_data(tx_data),.tx_ready(tx_ready),
 .new_session(new_session),.timing_valid(timing_valid),.capture_error(capture_error),
 .config_valid(config_valid),.config_entity(config_entity),.config_version(config_version),.config_ready(config_ready),.config_approved(config_approved),
 .reopen_required(reopen_required),.session_valid(session_valid),.mapping_valid(mapping_valid),.boot_id(boot_id),
 .event_valid(event_valid),.event_payload(event_payload),.event_ready(event_ready));
 function [31:0] crc264(input [2111:0] v);
  reg [31:0] c;integer i,j;begin c=32'hffffffff;for(i=0;i<264;i=i+1)begin
   c=c^v[i*8+:8];for(j=0;j<8;j=j+1)c=(c>>1)^(c[0]?32'hedb88320:0);end crc264=~c;end
 endfunction
 task commit;begin @(negedge clk);#1;if(submit_code!=0)$fatal(1,"policy rejected %d",submit_code);
  submit_valid=1;@(negedge clk);submit_valid=0;repeat(5)@(negedge clk);end endtask
 task grant(input integer first,input integer last);begin
  body=0;body[0]=1;body[8]=1;body[16]=1;body[63:32]=first;body[95:64]=last;
  body[127:96]=1;body[191:128]=11;body[223:192]=crc264(config_entity);body[255:224]=100;body[287:256]=7;
 end endtask
 task rotate;begin @(negedge clk);reopen_required=1;repeat(4)@(negedge clk);reopen_required=0;repeat(3)@(negedge clk);end endtask
 initial begin
  config_entity[31:0]=1;config_entity[2111:2080]=32'h89abcdef;
  repeat(4)@(negedge clk);rst_n=1;repeat(3)@(negedge clk);
  if(enable || timing_valid || config_ready || uart_tx!=1)$fatal(1,"unsafe default");
  grant(100,102);body[16]=0;body[8]=0;commit();if(enable)$fatal(1,"commissioning bypass");
  commissioned=1;config_valid=1;repeat(280)@(negedge clk);
  if(config_ready || config_approved || timing_valid || status[832+:32]!=crc264(config_entity))$fatal(1,"unapproved entity");
  // New approval needs a newly reserved session range; old grants cannot replay.
  version=2;grant(103,105);commit();wait(config_ready);#1;
  if(!config_approved || !timing_valid)$fatal(1,"exact entity rejected");
  @(negedge clk);config_valid=0;repeat(4)@(negedge clk);
  event_payload[127:96]=23;event_valid=1;@(negedge clk);event_valid=0;
  if(status[1120+:32]!=23 || status[1088+:32]!=1)$fatal(1,"event not consumed");
  rotate();if(new_session!=104 || timing_valid)$fatal(1,"rotation");
  rotate();if(new_session!=105)$fatal(1,"second rotation");
  rotate();if(enable || status[800+:8]!=2)$fatal(1,"exhaustion");
  version=3;grant(105,110);#1;if(submit_code!=11)$fatal(1,"overlapping range admitted");
  grant(106,110);body[288]=1;#1;if(submit_code!=11)$fatal(1,"reserved admitted");
  grant(106,110);body[255:224]=1001;#1;if(submit_code!=11)$fatal(1,"timing bound relaxed");
  grant(106,110);commit();config_entity[2111]=~config_entity[2111];config_valid=1;
  wait(!enable);if(status[800+:8]!=3 || timing_valid)$fatal(1,"tail mismatch not quarantined");
  config_valid=0;version=4;grant(111,115);commit();config_valid=1;boot_id=12;
  wait(!enable);if(status[800+:8]!=3)$fatal(1,"wrong boot admitted");
  config_valid=0;boot_id=11;version=5;grant(116,120);commit();
  // Actual UART loopback at 125MHz/460800 exercises ready and pin-level bytes.
  wait(tx_ready);@(negedge clk);tx_data=8'ha5;tx_valid=1;@(negedge clk);tx_valid=0;
  wait(rx_valid);#1;if(rx_data!=8'ha5 || rx_error)$fatal(1,"UART loopback");
  version=6;body=0;commit();if(enable || timing_valid || config_ready)$fatal(1,"disable");
  $display("PASS MCU adapter: disabled defaults, full entity CRC, boot/version approval, grants/reconnect/exhaustion, events, UART");$finish;
 end
 initial begin #1000000;$fatal(1,"timeout");end
endmodule

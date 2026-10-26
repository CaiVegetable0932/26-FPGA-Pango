`timescale 1ns/1ps
// Actual UART -> CRC/monotonic upload -> trusted tone consumer. A decreasing
// cross-chunk LUT with a correct CRC must never pulse the bypassed consumer.
module tb_pc_tone_gateway;
 reg clk=0,rst=0,rx=1;always #4 clk=~clk;
 wire tx,configured,submit;wire [15:0] kind;wire [2047:0] body;wire [31:0] version,id;
 wire [7:0] code,byte_data;wire byte_valid;wire [2303:0] tone_status;
 integer replies=0,submissions=0;reg [7:0] response[0:999];reg [15:0] sequence_override=0;
 pc_video_boot #(.BAUD(12500000),.ENTITY_MASK(16'h0006)) boot_control(
  .clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.configured(configured),
  .entity_submit_valid(submit),.entity_kind(kind),.entity_body(body),.entity_submit_code(code),.entity_status(tone_status),
  .reference_version(version),.reference_entity_id(id),.reference_submit_code(8'd11),
  .reference_status(768'd0),.affine_status(768'd0),.affine_submit_code(8'd11),.geometry_status(768'd0),
  .geometry_submit_ready(1'b0),.control_status(768'd0),.mode_submit_ready(1'b0),.runtime_action_code(8'd6));
 tone_entity_control #(.LUT_PREVALIDATED(1)) consumer(.clk(clk),.rst_n(rst),.processing_clk(clk),.processing_rst_n(rst),
  .submit_valid(submit),.kind(kind),.body(body),.version(version),.entity_id(id),.submit_code(code),.read_kind(16'd2),.status(tone_status),
  .legacy_valid(1'b0),.legacy_mode(2'd0),.legacy_version(32'd0),.capture_boundary(1'b0),.epoch(64'd0),.frame_id(64'd0),
  .bind_valid(1'b0),.bind_slot(2'd0),.bind_page(1'b0),.release_valid(1'b0),.release_slot(2'd0),.cancel_valid(1'b0),.cancel_slot(2'd0),
  .geometry_idle(1'b1),.statistics_valid(1'b0),.luminance_sum(48'd0),.samples(32'd0));
 uart_8n1 #(.BAUD(12500000)) decode(.clk(clk),.rst_n(rst),.rx(tx),.tx(),.rx_valid(byte_valid),.rx_data(byte_data),
  .framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)begin
  if(byte_valid)begin response[replies]=byte_data;replies=replies+1;end
  if(submit)begin if(kind!=2 || body[512+:8]!=64)$fatal(1,"UART submitted unvalidated LUT");submissions=submissions+1;end
 end
 function [31:0] crc32_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc32_byte=v;end
 endfunction
 function [15:0] crc_byte(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer k;begin v=c^{b,8'd0};for(k=0;k<8;k=k+1)v=(v<<1)^(v[15]?16'h1021:0);crc_byte=v;end
 endfunction
 task send_byte(input [7:0] b);
  integer k;begin
   @(negedge clk);rx=0;repeat(10)@(negedge clk);
   for(k=0;k<8;k=k+1)begin rx=b[k];repeat(10)@(negedge clk);end
   rx=1;repeat(12)@(negedge clk);
  end
 endtask
 task request(input [7:0] command,input integer length,input [639:0] payload,input integer target);
  reg [15:0] crc;reg [7:0] b;integer i;
  begin
   send_byte(8'h55);send_byte(8'haa);crc=16'hffff;
   for(i=0;i<length+6;i=i+1)begin
    case(i)0:b=1;1:b=command;2:b=sequence_override!=0?sequence_override[7:0]:target;3:b=sequence_override[15:8];4:b=length;5:b=0;default:b=payload[(i-6)*8+:8];endcase
    crc=crc_byte(crc,b);send_byte(b);
   end
   send_byte(crc[7:0]);send_byte(crc[15:8]);wait(replies==target*42);repeat(20)@(negedge clk);
  end
 endtask

 reg [639:0] boot=0,payload;reg [2047:0] lut;reg [31:0] crc;integer i,block,target;
 task begin_lut(input [31:0] txid);
  begin
   crc=32'hffffffff;for(i=0;i<256;i=i+1)crc=crc32_byte(crc,lut[i*8+:8]);crc=~crc;
   payload=0;payload[191:0]={crc,16'd0,16'd256,32'd7,32'd2,txid,16'd1,16'd2};
   target=target+1;request(8'ha1,24,payload,target);
   if(response[(target-1)*42+8]!=0)$fatal(1,"UART LUT begin");
   for(block=0;block<4;block=block+1)begin
    payload={64'd0,lut[block*512+:512],8'd0,8'd64,16'(block*64),txid};
    target=target+1;request(8'ha2,72,payload,target);
    if(response[(target-1)*42+8]!=0)$fatal(1,"UART LUT chunk");
   end
  end
 endtask
 initial begin
  boot[0+:64]=99;boot[64+:48]=48'h010000000002;boot[112+:48]=48'h020000000002;
  boot[160+:32]=32'h0350a8c0;boot[192+:32]=32'h0250a8c0;boot[224+:16]=50001;boot[240+:16]=50000;
  #100;rst=1;repeat(20)@(negedge clk);target=1;request(8'h71,32,boot,target);wait(configured);
  for(i=0;i<256;i=i+1)lut[i*8+:8]=i;lut[512+:8]=1;
  begin_lut(25);
  // Exact chunk retries must not erase the across-boundary decreasing proof.
  target=target+1;request(8'ha2,72,payload,target);
  payload=0;payload[95:0]={32'd0,crc,32'd25};target=target+1;request(8'ha3,12,payload,target);
  if(response[(target-1)*42+8]!=11 || submissions!=0)$fatal(1,"UART accepted descending LUT with correct CRC");
  target=target+1;request(8'ha3,12,payload,target);
  if(response[(target-1)*42+8]!=11 || submissions!=0)$fatal(1,"UART retry lost monotonic failure");
  payload=0;payload[63:0]={32'd25,16'd0,16'd1};target=target+1;request(8'ha5,8,payload,target);
  for(i=0;i<256;i=i+1)lut[i*8+:8]=i;
  begin_lut(26);target=target+1;request(8'ha2,72,payload,target);
  if(response[(target-1)*42+8]!=0)$fatal(1,"UART good exact chunk retry changed monotonic proof");
  payload=0;payload[95:0]={32'd0,crc,32'd26};target=target+1;request(8'ha3,12,payload,target);
  if(response[(target-1)*42+8]!=0 || submissions!=1 || tone_status[256+:2048]!=lut || tone_status[32+:32]!=2)
   $fatal(1,"UART valid LUT failed trusted consumer");
  target=target+1;request(8'ha3,12,payload,target);
  if(response[(target-1)*42+8]!=0 || submissions!=1)$fatal(1,"UART valid COMMIT retry duplicated consumer");
  $display("PC_TONE_GATEWAY_PASS serial bad/good CRC-valid LUT, cross-chunk proof, retries and trusted consumer");$finish;
 end
 initial begin #5000000;$fatal(1,"PC_TONE_GATEWAY_TIMEOUT");end
endmodule

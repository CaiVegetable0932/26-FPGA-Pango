`timescale 1ns/1ps
// Real UART/CRC/upload path with the board's pipelined manual camera consumer.
// Force a backend wait at COMMIT to cover bounded timeout/retry independently
// of slow serial pacing; the internal token must never appear in wire replies.
module tb_pc_camera_validation;
 reg clk=0,rst_n=0,rx=1;always #4 clk=~clk;
 wire tx,configured,entity_submit;wire [2047:0] entity_body;
 wire [15:0] kind;wire [31:0] version,id;wire [7:0] camera_code;
 wire [2303:0] camera_status;reg hold_wait=0;
 wire [7:0] backend_code=hold_wait?8'hff:camera_code;
 pc_video_boot #(.BAUD(12500000),.ENTITY_MASK(16'h0080)) boot(.clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.configured(configured),
  .entity_submit_valid(entity_submit),.entity_body(entity_body),.entity_kind(kind),.entity_submit_code(backend_code),.entity_status(camera_status),
  .reference_version(version),.reference_entity_id(id),.reference_submit_code(8'd11),.reference_status(768'd0),
  .affine_submit_code(8'd6),.affine_status(768'd0),.runtime_action_code(8'd6),.control_status(768'd0),
  .geometry_status(768'd0),.geometry_submit_ready(1'b0),.mode_submit_ready(1'b0));
 camera_brightness_control #(.SUPPORT_AUTO(0),.PIPELINED_VALIDATION(1)) camera(.clk(clk),.rst_n(rst_n),
  .submit_valid(entity_submit&&kind==7),.body(entity_body[383:0]),.version(version),.entity_id(id),
  .submit_code(camera_code),.status(camera_status),.source_quiesced(1'b0),.apply_ready(1'b1),.apply_done(1'b0),.apply_error(3'd0),
  .capture_boundary(1'b0),.capture_epoch(64'd0),.capture_frame(64'd0),.statistics_valid(1'b0),.luminance_sum(48'd0),.samples(32'd0));
 wire byte_valid;wire [7:0] byte_data;integer received=0,submissions=0;
 reg [7:0] replies[0:419];
 uart_8n1 #(.BAUD(12500000)) decode(.clk(clk),.rst_n(rst_n),.rx(tx),.tx(),.rx_valid(byte_valid),.rx_data(byte_data),
  .framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)begin
  if(byte_valid)begin replies[received]=byte_data;received=received+1;end
  if(entity_submit)begin
   if(kind!=7 || backend_code!=0 || camera_code!=0)$fatal(1,"unapproved camera publication");
   submissions=submissions+1;
  end
 end
 function [15:0] crc16(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer k;begin v=c^{b,8'd0};for(k=0;k<8;k=k+1)v=(v<<1)^(v[15]?16'h1021:0);crc16=v;end
 endfunction
 function [31:0] crc32(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;begin v=c^b;for(k=0;k<8;k=k+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc32=v;end
 endfunction
 task send_byte(input [7:0] b);
  integer k;begin
   @(negedge clk);rx=0;repeat(10)@(negedge clk);
   for(k=0;k<8;k=k+1)begin rx=b[k];repeat(10)@(negedge clk);end
   rx=1;repeat(12)@(negedge clk);
  end
 endtask
 task request(input [7:0] command,input integer length,input [639:0] payload,input integer target,input [7:0] expected);
  reg [15:0] c;reg [7:0] b;integer i;begin
   send_byte(8'h55);send_byte(8'haa);c=16'hffff;
   for(i=0;i<length+6;i=i+1)begin
    case(i)0:b=1;1:b=command;2:b=target;3:b=0;4:b=length;5:b=0;default:b=payload[(i-6)*8+:8];endcase
    c=crc16(c,b);send_byte(b);
   end
   send_byte(c[7:0]);send_byte(c[15:8]);wait(received==target*42);repeat(20)@(negedge clk);
   if(replies[(target-1)*42+8]!==expected || replies[(target-1)*42+8]==8'hff)
    $fatal(1,"UART camera reply target=%0d code=%0d expected=%0d",target,replies[(target-1)*42+8],expected);
   c=16'hffff;for(i=2;i<40;i=i+1)c=crc16(c,replies[(target-1)*42+i]);
   if({replies[target*42-1],replies[target*42-2]}!==c)$fatal(1,"UART camera reply CRC");
  end
 endtask
 reg [639:0] payload;reg [383:0] body;reg [31:0] body_crc;integer i;
 task body_checksum;
  begin body_crc=32'hffffffff;for(i=0;i<48;i=i+1)body_crc=crc32(body_crc,body[i*8+:8]);body_crc=~body_crc;end
 endtask
 initial begin
  payload=0;payload[0+:64]=99;payload[64+:48]=48'h010000000002;payload[112+:48]=48'h020000000002;
  payload[160+:32]=32'h0350a8c0;payload[192+:32]=32'h0250a8c0;payload[224+:16]=50001;payload[240+:16]=50000;
  #100;rst_n=1;repeat(20)@(negedge clk);request(8'h71,32,payload,1,0);wait(configured);
  body=0;body[15:8]=1;body[23:16]=96;body[31:24]=144;body[32+:32]=106;
  body[64+:16]=16;body[80+:16]=16;body[96+:16]=32;body[112+:16]=1;
  body[128+:32]=106;body[160+:32]=106;body[192+:32]=256;body[224+:16]=1;body[240+:16]=2;
  body[256+:32]=1000000;body[288+:32]=106;body[320+:32]=1;body_checksum();
  payload=0;payload[191:0]={body_crc,16'd0,16'd48,32'd7,32'd2,32'd23,16'd1,16'd7};request(8'ha1,24,payload,2,0);
  payload=0;payload[447:0]={body,8'd0,8'd48,16'd0,32'd23};request(8'ha2,56,payload,3,0);
  hold_wait=1;payload=0;payload[95:0]={32'd0,body_crc,32'd23};request(8'ha3,12,payload,4,4);
  if(submissions || boot.entity_transaction!=23 || entity_body[383:0]!==body)$fatal(1,"camera timeout lost immutable transaction");
  fork
   begin wait(boot.upload.state==3);repeat(40)@(negedge clk);hold_wait=0;end
   begin request(8'ha3,12,payload,5,0);end
  join
  request(8'ha3,12,payload,6,0);
  if(submissions!=1 || boot.entity_transaction!=0 || camera.queued!==body || camera.qv!=2 || camera.qid!=7)
   $fatal(1,"camera deferred commit/retry not atomic");
  // A new illegal body has an independently valid CRC and must be rejected
  // without changing the previous queued command, even while consumer busy.
  body[256+:32]=0;body_checksum();
  payload=0;payload[191:0]={body_crc,16'd0,16'd48,32'd8,32'd3,32'd24,16'd1,16'd7};request(8'ha1,24,payload,7,0);
  payload=0;payload[447:0]={body,8'd0,8'd48,16'd0,32'd24};request(8'ha2,56,payload,8,0);
  payload=0;payload[95:0]={32'd0,body_crc,32'd24};request(8'ha3,12,payload,9,11);
  if(submissions!=1 || camera.queued[256+:32]!=1000000 || camera.qv!=2 || camera.qid!=7)$fatal(1,"invalid camera body changed pending command");
  $display("PC_CAMERA_VALIDATION_PASS replies=9 timeout_busy deferred_exact_retry rejected_invalid no_ff_wire");$finish;
 end
 initial begin #3000000;$fatal(1,"UART camera timeout received=%0d",received);end
endmodule

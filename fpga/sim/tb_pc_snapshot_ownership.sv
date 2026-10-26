// Private snapshot reset/ownership regression derived from tb_pc_mcu_link.
// Real UART requests verify stale-page rejection and exact page-zero retries.
`timescale 1ns/1ps
// Exercise kind12 through real PC UART framing, staging/CRC/COMMIT and frozen
// A4 pages in the production manual-image profile. Disabled custom LUT uploads
// must be rejected before staging while MCU policy remains available. The
// accelerated PC baud is independent of the production MCU UART.
module tb_pc_snapshot_ownership;
 reg clk=0,rst_n=0,rx=1;always #4 clk=~clk;
 wire tx,configured,valid;wire [15:0] kind,length,read_kind;
 wire [2047:0] body;wire [31:0] version,entity_id;wire [7:0] code;
 wire [2303:0] status;wire enabled;wire [31:0] session;
 integer replies=0,commits=0;reg [7:0] response[0:2047];
 wire byte_valid;wire [7:0] byte_data;
 reg ev=0;reg [319:0] event_payload=0;
 pc_video_boot #(.BAUD(12500000),.ENTITY_MASK(16'h1bca)) pc(
  .clk(clk),.rst_n(rst_n),.uart_rx(rx),.uart_tx(tx),.configured(configured),
  .entity_submit_valid(valid),.entity_kind(kind),.entity_length(length),.entity_body(body),
  .reference_version(version),.reference_entity_id(entity_id),.entity_submit_code(code),
  .entity_read_kind(read_kind),.entity_status(status),
  .control_status(768'd0),.geometry_status(768'd0),.reference_status(768'd0),
  .affine_status(768'd0),.reference_submit_code(8'd6),.affine_submit_code(8'd6),
  .runtime_action_code(8'd6),.mode_submit_ready(1'b0),.geometry_submit_ready(1'b0));
 mcu_link_adapter link(.clk(clk),.rst_n(rst_n),.commissioned(configured),
  .uart_rx(1'b1),.uart_tx(),.submit_valid(valid && kind==12),.body(body[511:0]),
  .version(version),.entity_id(entity_id),.submit_code(code),.status(status),
  .enable(enabled),.new_session(session),.rx_valid(),.rx_error(),.rx_data(),
  .tx_valid(1'b0),.tx_data(8'd0),.tx_ready(),.timing_valid(),.capture_error(),
  .config_valid(1'b0),.config_entity(2112'd0),.config_version(32'd0),
  .config_ready(),.config_approved(),.reopen_required(1'b0),
  .session_valid(1'b0),.mapping_valid(1'b0),.boot_id(64'd0),
  .event_valid(ev),.event_payload(event_payload),.event_ready());
 uart_8n1 #(.BAUD(12500000)) decoder(.clk(clk),.rst_n(rst_n),.rx(tx),.tx(),
  .rx_valid(byte_valid),.rx_data(byte_data),.framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)begin
  if(byte_valid)begin response[replies]=byte_data;replies=replies+1;end
  if(valid && kind==12)commits=commits+1;
 end
 function [15:0] crc16(input [15:0] c,input [7:0] b);
  reg [15:0] v;integer j;begin v=c^{b,8'd0};for(j=0;j<8;j=j+1)v=(v<<1)^(v[15]?16'h1021:0);crc16=v;end
 endfunction
 function [31:0] crc32(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer j;begin v=c^b;for(j=0;j<8;j=j+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc32=v;end
 endfunction
 task send_byte(input [7:0] b);
  integer k;begin
   @(negedge clk);rx=0;repeat(10)@(negedge clk);
   for(k=0;k<8;k=k+1)begin rx=b[k];repeat(10)@(negedge clk);end
   rx=1;repeat(12)@(negedge clk);
  end
 endtask
 task request(input [7:0] command,input integer size,input [639:0] payload,input integer target);
  reg [15:0] c;reg [7:0] b;integer j;
  begin
   send_byte(8'h55);send_byte(8'haa);c=16'hffff;
   for(j=0;j<size+6;j=j+1)begin
    case(j)0:b=1;1:b=command;2:b=retry_sequence!=0 ? retry_sequence[7:0]:target;3:b=retry_sequence[15:8];4:b=size;5:b=0;default:b=payload[(j-6)*8+:8];endcase
    c=crc16(c,b);send_byte(b);
   end
   send_byte(c[7:0]);send_byte(c[15:8]);wait(replies==target*42);repeat(20)@(negedge clk);
  end
 endtask
 reg [15:0] retry_sequence=0;
 reg [639:0] payload;reg [511:0] policy;reg [2303:0] frozen;
 reg [31:0] checksum;reg [15:0] c;integer i,p;
 initial begin
  #100;rst_n=1;repeat(20)@(negedge clk);
  if(enabled)$fatal(1,"enabled before commissioning");
  payload=0;payload[0+:64]=99;payload[64+:48]=48'h010000000002;payload[112+:48]=48'h020000000002;
  payload[160+:32]=32'h0350a8c0;payload[192+:32]=32'h0250a8c0;payload[224+:16]=50001;payload[240+:16]=50000;
  request(8'h71,32,payload,1);wait(configured);
  request(8'ha0,1,640'd0,2);
  // A0 ORs in its always-readable kind9/10 status bits. The advertised
  // entity mask is therefore 1bca|0600=1fca, with custom LUT, C4 and independent C6 viewport absent.
  if({response[42+27],response[42+26],response[42+25],response[42+24]}!=32'h00001fca)
   $fatal(1,"manual profile capability mask differs");
  if({response[42+29],response[42+28]}!=128 || response[42+30]!=64)
   $fatal(1,"manual profile must advertise max body128/chunk64");
  // Discovery policy cannot authorize poses; it only permits configuration retrieval.
  policy=0;policy[7:0]=1;policy[63:32]=100;policy[95:64]=110;
  checksum=32'hffffffff;for(i=0;i<64;i=i+1)checksum=crc32(checksum,policy[i*8+:8]);checksum=~checksum;
  payload=0;payload[191:0]={checksum,16'd0,16'd64,32'd7,32'd1,32'd23,16'd1,16'd12};
  request(8'ha1,24,payload,3);
  payload=0;payload[31:0]=23;payload[55:48]=64;payload[64+:512]=policy;request(8'ha2,72,payload,4);
  // A corrupt body CRC cannot publish a policy.
  payload=0;payload[95:0]={32'd0,checksum^32'd1,32'd23};request(8'ha3,12,payload,5);
  if(response[4*42+8]!=11 || enabled || commits!=0)$fatal(1,"bad CRC published policy");
  payload[63:32]=checksum;request(8'ha3,12,payload,6);request(8'ha3,12,payload,7);
  if(response[5*42+8]!=0 || response[6*42+8]!=0 || commits!=1 || !enabled || session!=100)
   $fatal(1,"policy not committed exactly once");
  frozen=status;request(8'ha4,4,640'd12,8);
  // Mutate diagnostics between pages; all eight pages must retain page0's image.
  @(negedge clk);ev=1;event_payload[127:96]=1;@(negedge clk);ev=0;
  for(p=1;p<8;p=p+1)begin payload=12;payload[23:16]=p;request(8'ha4,4,payload,8+p);end
  for(p=0;p<8;p=p+1)begin
   if(response[(7+p)*42+8]!=0)$fatal(1,"A4 page rejected");
   for(i=0;i<24;i=i+1)if(response[(7+p)*42+12+i]!==frozen[(p*24+i)*8+:8])$fatal(1,"snapshot drift");
  end
  payload=12;payload[23:16]=8;request(8'ha4,4,payload,16);
  if(response[15*42+8]!=11)$fatal(1,"A4 page overrun accepted");
  // A disabled kind cannot allocate the reduced staging buffer. Follow its
  // rejected BEGIN with CHUNK/COMMIT too: none may reach an entity consumer.
  payload=0;payload[191:0]={32'd0,16'd0,16'd256,32'd8,32'd2,32'd24,16'd1,16'd2};
  request(8'ha1,24,payload,17);
  if(response[16*42+8]!=6)$fatal(1,"disabled kind2 BEGIN accepted");
  payload=0;payload[31:0]=24;payload[55:48]=64;request(8'ha2,72,payload,18);
  if(response[17*42+8]!=11)$fatal(1,"disabled kind2 CHUNK allocated staging");
  payload=0;payload[31:0]=24;request(8'ha3,12,payload,19);
  if(response[18*42+8]!=11 || commits!=1)$fatal(1,"disabled kind2 COMMIT reached consumer");
  request(8'ha4,4,640'd2,20);
  if(response[19*42+8]!=11)$fatal(1,"disabled kind2 readback accepted");
  request(8'ha0,1,640'd0,21);
  if({response[20*42+25],response[20*42+24]}!=16'h1fca ||
     {response[20*42+29],response[20*42+28]}!=128 || !enabled || session!=100 || commits!=1)
   $fatal(1,"disabled LUT requests changed capability or MCU policy");
  // The resource profile also removes independent C6 viewport/zoom entity5.
  // Reject its BEGIN and READ explicitly without disturbing the MCU policy.
  payload=0;payload[191:0]={32'd0,16'd0,16'd32,32'd9,32'd2,32'd25,16'd1,16'd5};
  request(8'ha1,24,payload,22);
  if(response[21*42+8]!=6)$fatal(1,"disabled kind5 BEGIN accepted");
  request(8'ha4,4,640'd5,23);
  if(response[22*42+8]!=11 || !enabled || session!=100 || commits!=1)
   $fatal(1,"disabled kind5 READ accepted or changed MCU policy");
  // Reset after publishing a nonzero entity: its payload storage deliberately
  // retains old/unknown bits, but page one must be rejected until fresh page0.
  @(negedge clk);rst_n=0;repeat(4)@(negedge clk);rst_n=1;
  payload=0;payload[0+:64]=101;payload[64+:48]=48'h010000000002;payload[112+:48]=48'h020000000002;
  payload[160+:32]=32'h0350a8c0;payload[192+:32]=32'h0250a8c0;payload[224+:16]=50001;payload[240+:16]=50000;
  request(8'h71,32,payload,24);wait(configured);
  payload=12;payload[23:16]=1;request(8'ha4,4,payload,25);
  if(response[24*42+8]!=11 || pc.have_snapshot)$fatal(1,"stale snapshot visible after reset");
  request(8'ha4,4,640'd12,26);frozen=pc.status_snapshot;
  // Retry the same sequence/page after diagnostics can change. It must replay
  // the same complete frozen page and must not advance next_entity_page.
  @(negedge clk);ev=1;event_payload[127:96]=3;@(negedge clk);ev=0;
  retry_sequence=26;request(8'ha4,4,640'd12,27);retry_sequence=0;
  for(i=0;i<24;i=i+1)if(response[26*42+12+i]!==response[25*42+12+i])$fatal(1,"page0 retry recaptured status");
  if(pc.next_entity_page!=1)$fatal(1,"retry advanced page cursor");
  payload=12;payload[23:16]=1;request(8'ha4,4,payload,28);
  if(response[27*42+8]!=0)$fatal(1,"fresh continuation rejected");
  for(i=0;i<24;i=i+1)if(response[27*42+12+i]!==frozen[192+i*8+:8])$fatal(1,"fresh page1 drift");
  // Every response, including NAKs, must preserve the outer wire CRC.
  for(p=0;p<28;p=p+1)begin
   c=16'hffff;for(i=2;i<40;i=i+1)c=crc16(c,response[p*42+i]);
   if({response[p*42+41],response[p*42+40]}!=c)$fatal(1,"reply CRC");
  end
  $display("PC_SNAPSHOT_OWNERSHIP_PASS serial=28 reset_fence=1 page0_retry=1 entity_mask=1fca max_body=128 disabled_lut=NAK disabled_viewport=NAK commit_once=1 frozen_pages=8 bad_crc=NAK11");$finish;
 end
 initial begin #3000000;$fatal(1,"PC MCU timeout replies=%0d",replies);end
endmodule

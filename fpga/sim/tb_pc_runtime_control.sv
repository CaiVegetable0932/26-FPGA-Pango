`timescale 1ns/1ps
// Purpose: real serial GET_STATUS pages freeze one atomic backend snapshot;
// mode ACK means validated/queued, and busy/range failures never submit data.
module tb_pc_runtime_control;
 reg clk=0,rst=0,rx=1;always #4 clk=~clk;
 wire tx,configured,mode_valid;wire [1:0] mode;wire [31:0] version;
 reg ready=1;reg [767:0] status,original;
 integer replies=0,submissions=0;reg [7:0] response[0:713];
 reg [767:0] geometry_status=0,snapshot_s1_status,snapshot_result_status,snapshot_geometry_status;reg geometry_ready=1,snapshot_ready=1;
 wire geometry_valid,snapshot_arm;wire [543:0] geometry_entity;wire [31:0] geometry_version,geometry_id;
 integer geometry_submissions=0,snapshot_submissions=0;
 wire byte_valid;wire [7:0] byte_data;
 pc_video_boot #(.BAUD(12500000)) dut(.clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.configured(configured),
  .epoch(),.local_mac(),.peer_mac(),.local_ip(),.peer_ip(),.local_port(),.peer_port(),
  .snapshot_s1_status(snapshot_s1_status),.snapshot_result_status(snapshot_result_status),.snapshot_geometry_status(snapshot_geometry_status),.geometry_status(geometry_status),.geometry_submit_valid(geometry_valid),.geometry_submit_ready(geometry_ready),
  .geometry_submit(geometry_entity),.geometry_version(geometry_version),.geometry_entity_id(geometry_id),
  .snapshot_arm(snapshot_arm),.snapshot_arm_ready(snapshot_ready),.control_status(status),.mode_submit_valid(mode_valid),.mode_submit_ready(ready),.mode_submit(mode),.mode_version(version));
 uart_8n1 #(.BAUD(12500000)) decode(.clk(clk),.rst_n(rst),.rx(tx),.tx(),.rx_valid(byte_valid),.rx_data(byte_data),
  .framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)begin
  if(byte_valid)begin response[replies]=byte_data;replies=replies+1;end
  if(geometry_valid && geometry_ready)begin
   if(geometry_version!=2 || geometry_id!=7 || geometry_entity[320+:32]!=65536000)$fatal(1,"Wrong geometry submission version=%0d id=%0d fx=%0d",geometry_version,geometry_id,geometry_entity[320+:32]);geometry_submissions=geometry_submissions+1;
  end
  if(snapshot_arm && snapshot_ready)snapshot_submissions=snapshot_submissions+1;
  if(mode_valid && ready)begin
   if(mode!=1 || version!=2)$fatal(1,"Wrong submitted mode entity");submissions=submissions+1;
  end
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
    case(i)0:b=1;1:b=command;2:b=target;3:b=0;4:b=length;5:b=0;default:b=payload[(i-6)*8+:8];endcase
    crc=crc_byte(crc,b);send_byte(b);
   end
   send_byte(crc[7:0]);send_byte(crc[15:8]);wait(replies==target*42);repeat(20)@(negedge clk);
  end
 endtask
 reg [639:0] boot,payload;reg [31:0] entity_crc;reg [15:0] crc;integer i,p,reply_file;
 initial begin
  for(i=0;i<96;i=i+1)begin status[i*8+:8]=i*3+7;snapshot_s1_status[i*8+:8]=i*3+1;
   snapshot_result_status[i*8+:8]=i*5+7;snapshot_geometry_status[i*8+:8]=i*11+9;end
  status[320+:32]=1;original=status;
  boot=0;boot[0+:64]=99;boot[64+:48]=48'h010000000002;boot[112+:48]=48'h020000000002;
  boot[160+:32]=32'h0350a8c0;boot[192+:32]=32'h0250a8c0;boot[224+:16]=50001;boot[240+:16]=50000;
  #100;rst=1;repeat(20)@(negedge clk);request(8'h71,32,boot,1);wait(configured);
  request(8'h90,1,256'd0,2);
  status=~original;status[320+:32]=1;request(8'h90,1,256'd1,3);
  for(i=0;i<24;i=i+1)begin
   if(response[42+12+i]!=original[i*8+:8])$fatal(1,"Page 0 status differs");
   if(response[84+12+i]!=original[192+i*8+:8])$fatal(1,"Status pages did not share one snapshot");
  end
  payload=0;payload[7:0]=1;payload[47:16]=2;request(8'h92,6,payload,4);
  if(response[126+8]!=0 || response[126+10]!=2 || submissions!=1)$fatal(1,"Mode queued ACK failed");
  ready=0;payload[47:16]=3;request(8'h92,6,payload,5);
  if(response[168+3]!=8'h81 || response[168+8]!=4 || submissions!=1)$fatal(1,"Busy mode was accepted");
  ready=1;payload[7:0]=3;request(8'h92,6,payload,6);
  if(response[210+8]!=11 || submissions!=1)$fatal(1,"Invalid mode was accepted");
  geometry_status[576+:32]=1;
  payload=0;payload[31:0]=2;payload[63:32]=7;
  payload[64+:32]=67109;payload[192+:32]=67109;
  payload[384+:32]=65536000;payload[416+:32]=65536000;payload[576+:32]=32'h04000000;
  entity_crc=32'hffffffff;for(i=0;i<76;i=i+1)entity_crc=crc32_byte(entity_crc,payload[i*8+:8]);payload[639:608]=~entity_crc;
  request(8'h94,80,payload,7);
  if(response[252+8]!=0 || response[252+10]!=2 || geometry_submissions!=1)$fatal(1,"Geometry queued ACK failed");
  payload[608]=!payload[608];request(8'h94,80,payload,8);
  if(response[294+8]!=11 || geometry_submissions!=1)$fatal(1,"Geometry bad CRC accepted");
  payload[608]=!payload[608];payload[384+:32]=0;
  entity_crc=32'hffffffff;for(i=0;i<76;i=i+1)entity_crc=crc32_byte(entity_crc,payload[i*8+:8]);payload[639:608]=~entity_crc;
  request(8'h94,80,payload,9);
  if(response[336+8]!=11 || geometry_submissions!=1)$fatal(1,"Nonpositive focal accepted");
  request(8'h95,1,640'd0,10);
  if(response[378+8]!=0)$fatal(1,"Geometry readback failed");
  request(8'h93,1,640'd0,11);
  if(response[420+8]!=0 || snapshot_submissions!=1)$fatal(1,"Snapshot command failed");
  snapshot_ready=0;request(8'h93,1,640'd0,12);
  if(response[462+8]!=4 || snapshot_submissions!=1)$fatal(1,"Busy snapshot accepted");
  request(8'h96,1,640'd0,13);request(8'h96,1,640'd7,14);
  for(i=0;i<24;i=i+1)begin
   if(response[504+12+i]!=snapshot_s1_status[i*8+:8] || response[546+12+i]!=snapshot_result_status[(72+i)*8+:8])$fatal(1,"Snapshot descriptor pages differ");
  end
  request(8'h97,1,640'd0,15);for(i=0;i<24;i=i+1)if(response[588+12+i]!=snapshot_geometry_status[i*8+:8])$fatal(1,"Snapshot old entity readback differs");
  request(8'h90,1,640'd0,16);request(8'h97,1,640'd1,17);
  if(response[672+8]!=11)$fatal(1,"Interleaved readback used another frozen entity");
  for(p=0;p<17;p=p+1)begin
   crc=16'hffff;for(i=2;i<40;i=i+1)crc=crc_byte(crc,response[p*42+i]);
   if({response[p*42+41],response[p*42+40]}!=crc)$fatal(1,"Runtime reply CRC failed");
  end
  reply_file=$fopen("runtime_replies.bin","wb");for(i=0;i<714;i=i+1)$fwrite(reply_file,"%c",response[i]);$fclose(reply_file);
  $display("TB_PC_RUNTIME_CONTROL_PASS replies=17 mode=1 geometry=1 snapshot=1");$finish;
 end
 initial begin #5000000;$fatal(1,"PC runtime timeout state=%0d bytes=%0d",dut.state,replies);end
endmodule

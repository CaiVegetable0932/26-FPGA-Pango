`timescale 1ns/1ps
// Purpose: real serial GET_STATUS pages freeze one atomic backend snapshot;
// mode ACK means validated/queued, and busy/range failures never submit data.
module tb_pc_runtime_control;
 reg clk=0,rst=0,rx=1;always #4 clk=~clk;
 wire tx,configured,mode_valid;wire [1:0] mode;wire [31:0] version;
 reg ready=1;reg [767:0] status,original;
 integer replies=0,submissions=0;reg [7:0] response[0:2561];
 reg [767:0] geometry_status=0;reg geometry_ready=1;
 wire geometry_valid;wire [543:0] geometry_entity;wire [31:0] geometry_version,geometry_id;
 integer geometry_submissions=0;
 reg boundary=0;reg [15:0] sequence_override=0;wire affine_valid;wire [95:0] affine_payload;
 wire [15:0] affine_sequence;wire [7:0] affine_code;
 wire pending,enabled,requested;wire [31:0] control_version,requested_version;
 wire [63:0] applied_epoch,applied_frame;wire [191:0] applied_coeff;
 wire [767:0] affine_status={256'd0,applied_coeff,applied_frame,applied_epoch,
    requested_version,32'd1,32'd1,control_version,24'd0,5'd0,pending,enabled,requested,16'd10,16'd1};
 affine_frame_control affine(.clk(clk),.rst_n(rst),.submit_valid(affine_valid),
  .submit_sequence(affine_sequence),.submit_payload(affine_payload),.submit_code(affine_code),
  .other_pending(1'b0),.geometry_version(32'd1),.capture_geometry(448'd55),
  .reference_coefficients(192'd66),.capture_boundary(boundary),.capture_epoch(64'd99),.capture_frame(64'd77),
  .capture_coefficients(),.capture_enable(),.capture_control_version(),.pending(pending),
  .applied_enable(enabled),.requested_enable(requested),.control_version(control_version),
  .requested_version(requested_version),.applied_epoch(applied_epoch),.applied_frame(applied_frame),.applied_coefficients(applied_coeff));
 wire ref_valid,ref_legal;wire [511:0] ref_entity;
 wire [31:0] ref_version,ref_id;integer ref_submissions=0;
 reg [511:0] reference_body;reg [31:0] reference_crc;
 // Exercise the board's bounded sequential guard through real UART commands.
 wire ref_checked;
 affine_reference_guard #(.WIDTH(35),.HEIGHT(33),.PIPELINED(1)) ref_guard(.clk(clk),.rst_n(rst),.entity(ref_entity),.legal(ref_legal),.result_valid(ref_checked));
 always @(posedge clk)if(ref_valid)begin
  if(!ref_legal || ref_version!=2 || ref_id!=7)$fatal(1,"UART reference entity validation");
  ref_submissions=ref_submissions+1;
 end
 wire action_valid;wire [15:0] action,action_sequence;wire [7:0] action_code;
 wire clear_motion,clear_history;wire [319:0] action_status;integer motion_clears=0,history_clears=0;
 reg [2303:0] generic_status=0;
 frame_runtime_actions actions(.clk(clk),.rst_n(rst),.submit_valid(action_valid),.action(action),.request_seq(action_sequence),
  .submit_code(action_code),.capture_boundary(boundary),.epoch(64'd99),.frame_id(64'd77),
  .clear_motion(clear_motion),.clear_history(clear_history),.status_extension(action_status));
 always @(posedge clk)begin if(clear_motion)motion_clears<=motion_clears+1;if(clear_history)history_clears<=history_clears+1;end
 wire byte_valid;wire [7:0] byte_data;
 pc_video_boot #(.BAUD(12500000),.ENTITY_MASK(16'h0bee)) dut(.clk(clk),.rst_n(rst),.uart_rx(rx),.uart_tx(tx),.configured(configured),
  .runtime_action_valid(action_valid),.runtime_action(action),.runtime_action_seq(action_sequence),.runtime_action_code(action_code),
  .entity_status(generic_status),.entity_submit_code(8'd0),
  .reference_status(768'd0),.reference_submit_valid(ref_valid),.reference_entity(ref_entity),.reference_version(ref_version),.reference_entity_id(ref_id),.reference_submit_code(!ref_checked?8'hff:ref_legal?8'd0:8'd11),
  .affine_status(affine_status),.affine_submit_valid(affine_valid),.affine_payload(affine_payload),.affine_sequence(affine_sequence),.affine_submit_code(affine_code),
  .epoch(),.local_mac(),.peer_mac(),.local_ip(),.peer_ip(),.local_port(),.peer_port(),
  .geometry_status(geometry_status),.geometry_submit_valid(geometry_valid),.geometry_submit_ready(geometry_ready),
  .geometry_submit(geometry_entity),.geometry_version(geometry_version),.geometry_entity_id(geometry_id),
  .control_status(status),.mode_submit_valid(mode_valid),.mode_submit_ready(ready),.mode_submit(mode),.mode_version(version));
 uart_8n1 #(.BAUD(12500000)) decode(.clk(clk),.rst_n(rst),.rx(tx),.tx(),.rx_valid(byte_valid),.rx_data(byte_data),
  .framing_error(),.tx_valid(1'b0),.tx_ready(),.tx_data(8'd0));
 always @(posedge clk)begin
  if(byte_valid)begin response[replies]=byte_data;replies=replies+1;end
  if(geometry_valid && geometry_ready)begin
   if(geometry_version!=2 || geometry_id!=7 || geometry_entity[320+:32]!=65536000)$fatal(1,"Wrong geometry submission version=%0d id=%0d fx=%0d",geometry_version,geometry_id,geometry_entity[320+:32]);geometry_submissions=geometry_submissions+1;
  end
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
    case(i)0:b=1;1:b=command;2:b=sequence_override!=0?sequence_override[7:0]:target;3:b=sequence_override[15:8];4:b=length;5:b=0;default:b=payload[(i-6)*8+:8];endcase
    crc=crc_byte(crc,b);send_byte(b);
   end
   send_byte(crc[7:0]);send_byte(crc[15:8]);wait(replies==target*42);repeat(20)@(negedge clk);
  end
 endtask
 reg [639:0] boot,payload;reg [31:0] entity_crc;reg [15:0] crc;integer i,p,reply_file;
 initial begin
  for(i=0;i<96;i=i+1)status[i*8+:8]=i*3+7;
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
  if(response[420+8]!=6)$fatal(1,"Retired 93 accepted");
  request(8'h93,1,640'd0,12);
  if(response[462+8]!=6)$fatal(1,"Retired 93 repeat accepted");
  request(8'h96,1,640'd0,13);request(8'h96,1,640'd7,14);
  if(response[504+8]!=6 || response[546+8]!=6)$fatal(1,"Retired 96 accepted");
  request(8'h97,1,640'd0,15);
  if(response[588+8]!=6)$fatal(1,"Retired 97 accepted");
  // Retired commands do not corrupt subsequent status/frozen readback.
  request(8'h90,1,640'd0,16);request(8'h95,1,640'd1,17);
  if(response[630+8]!=0 || response[672+8]!=11)$fatal(1,"Readback operation fencing failed");
  // Negative compatibility checks use valid outer CRC and, for 0x94,
  // recomputed valid entity CRC: neither retired post nor projective is accepted.
  payload=0;payload[7:0]=2;payload[47:16]=5;request(8'h92,6,payload,18);
  if(response[714+8]!=6)$fatal(1,"Retired post mode did not return unsupported");
  payload=0;payload[31:0]=2;payload[63:32]=7;
  payload[384+:32]=65536000;payload[416+:32]=65536000;
  payload[512+:32]=1;payload[576+:32]=32'h04000000;
  entity_crc=32'hffffffff;for(i=0;i<76;i=i+1)entity_crc=crc32_byte(entity_crc,payload[i*8+:8]);payload[639:608]=~entity_crc;
  request(8'h94,80,payload,19);
  if(response[756+8]!=11 || geometry_submissions!=1)$fatal(1,"Projective third row accepted");
  request(8'ha0,1,640'd0,20);
  if(response[798+8]!=0 || response[798+12]!=8'h41)$fatal(1,"AFG1 capability missing");
  // Actual board mask omits C4 while preserving C3 calibration and history clear.
  if(response[798+24]!=8'hee || response[798+25]!=8'h0f)$fatal(1,"C4/C3 capabilities wrong");
  payload=0;payload[95:0]={32'd1,32'd1,32'd1};sequence_override=100;
  request(8'ha6,12,payload,21);request(8'ha6,12,payload,22);
  if(response[840+8]!=0 || response[882+8]!=0 || !pending || enabled)$fatal(1,"A6 queue/retry semantics");
  payload[0]=0;request(8'ha6,12,payload,23);
  if(response[924+8]!=11)$fatal(1,"Conflicting retry accepted");
  sequence_override=0;request(8'ha4,4,640'd10,24);
  if(response[966+8]!=0 || response[966+16]!=5)$fatal(1,"A4 pending record");
  boundary=1;@(negedge clk);boundary=0;repeat(2)@(negedge clk);
  if(!enabled || pending || control_version!=1)$fatal(1,"A6 capture boundary");
  request(8'ha4,4,640'h0001000a,25);
  if(response[1008+12]!=0)$fatal(1,"A4 frozen page changed across source boundary");
  request(8'ha4,4,640'd10,26);
  if(response[1050+16]!=3)$fatal(1,"A4 source applied record");
  payload=0;payload[95:0]={32'd1,32'd2,32'd0};request(8'ha6,12,payload,27);
  boundary=1;@(negedge clk);boundary=0;repeat(2)@(negedge clk);
  if(enabled || pending || control_version!=2)$fatal(1,"A6 OFF did not apply");
  request(8'h90,1,640'd0,28);request(8'ha4,4,640'h0001000a,29);
  if(response[1176+8]!=11)$fatal(1,"A4 interleaved page accepted");
  // Reference upload traverses the real V1 parser and bytewise CRC engine.
  reference_body=0;reference_body[0+:32]=32*65536;reference_body[32+:32]=32*65536;
  reference_body[64+:32]=17*65536;reference_body[96+:32]=16*65536;
  reference_body[128+:32]=2097152;reference_body[192+:32]=-17*2097152;
  reference_body[256+:32]=2097152;reference_body[288+:32]=-16*2097152;
  reference_body[320+:16]=35;reference_body[336+:16]=33;reference_body[352+:32]=1;reference_body[384+:16]=1;
  reference_crc=32'hffffffff;for(i=0;i<64;i=i+1)reference_crc=crc32_byte(reference_crc,reference_body[i*8+:8]);reference_crc=~reference_crc;
  payload=0;payload[191:0]={reference_crc,16'd0,16'd64,32'd7,32'd2,32'd23,16'd1,16'd9};
  request(8'ha1,24,payload,30);
  if(response[1218+8]!=0)$fatal(1,"UART BEGIN reference");
  payload=0;payload[319:0]={reference_body[255:0],8'd0,8'd32,16'd0,32'd23};
  request(8'ha2,40,payload,31);request(8'ha2,40,payload,32);
  if(response[1260+8]!=0 || response[1302+8]!=0)$fatal(1,"UART reference chunk retry");
  payload[319:0]={reference_body[511:256],8'd0,8'd32,16'd32,32'd23};request(8'ha2,40,payload,33);
  payload=0;payload[95:0]={32'd0,reference_crc,32'd23};request(8'ha3,12,payload,34);request(8'ha3,12,payload,35);
  if(response[1386+8]!=0 || response[1428+8]!=0 || ref_submissions!=1 || ref_entity!=reference_body)
   $fatal(1,"UART reference commit exactly once");
  // Simulate lost replies by replaying identical sequence/page, preserving the
  // frozen frontier. New sequence rereads of old nonzero pages remain invalid.
  sequence_override=201;request(8'ha4,4,640'd10,36);request(8'ha4,4,640'd10,37);
  sequence_override=202;request(8'ha4,4,640'h0001000a,38);request(8'ha4,4,640'h0001000a,39);
  sequence_override=0;request(8'ha4,4,640'h0002000a,40);
  if(response[35*42+8]!=0 || response[36*42+8]!=0 || response[37*42+8]!=0 || response[38*42+8]!=0 || response[39*42+8]!=0)
   $fatal(1,"A4 exact retry advanced/rejected frozen page");
  for(i=12;i<36;i=i+1)begin
   if(response[35*42+i]!=response[36*42+i] || response[37*42+i]!=response[38*42+i])$fatal(1,"A4 retry data drift");
  end
  // A full 12-page LUT record must stay frozen while backend bytes change.
  for(i=0;i<288;i=i+1)generic_status[i*8+:8]=(i*17+5)&255;
  request(8'ha4,4,640'd2,41);generic_status=0;
  for(p=1;p<12;p=p+1)begin payload=2;payload[23:16]=p;request(8'ha4,4,payload,41+p);end
  for(p=0;p<12;p=p+1)for(i=0;i<24;i=i+1)
   if(response[(40+p)*42+12+i]!==8'(((p*24+i)*17+5)&255))$fatal(1,"LUT frozen page %0d byte %0d",p,i);
  sequence_override=300;request(8'ha5,8,640'd3,53);request(8'ha5,8,640'd3,54);
  request(8'ha5,8,640'd4,55);sequence_override=301;request(8'ha5,8,640'd4,56);
  if(response[52*42+8]!=6 || response[53*42+8]!=6 || response[54*42+8]!=0 || response[55*42+8]!=4 || action_status[1]!=1)
   $fatal(1,"A5 C4 unsupported / history queue/busy");
  @(negedge clk);boundary=1;@(negedge clk);boundary=0;repeat(2)@(negedge clk);
  sequence_override=300;request(8'ha5,8,640'd3,57);
  if(response[56*42+8]!=6 || motion_clears!=0 || history_clears!=1 || action_status[1:0]!=0)$fatal(1,"A5 duplicate after apply");
  sequence_override=301;request(8'ha5,8,640'd4,58);
  @(negedge clk);boundary=1;@(negedge clk);boundary=0;repeat(2)@(negedge clk);
  sequence_override=0;request(8'ha5,8,640'h10003,59);
  if(response[57*42+8]!=0 || response[58*42+8]!=11 || motion_clears!=0 || history_clears!=2)$fatal(1,"A5 clear/reserved");
  // An old C4 BEGIN is rejected by the real upload parser, without staging.
  payload=0;payload[191:0]={32'd0,16'd0,16'd32,32'd1,32'd1,32'd99,16'd1,16'd4};
  request(8'ha1,24,payload,60);
  if(response[59*42+8]!=6 || dut.entity_transaction!=0)$fatal(1,"retired C4 upload not NAK6");
  for(p=0;p<60;p=p+1)begin
   crc=16'hffff;for(i=2;i<40;i=i+1)crc=crc_byte(crc,response[p*42+i]);
   if({response[p*42+41],response[p*42+40]}!=crc)$fatal(1,"Runtime reply CRC failed");
  end
  reply_file=$fopen("runtime_replies.bin","wb");for(i=0;i<1470;i=i+1)$fwrite(reply_file,"%c",response[i]);$fclose(reply_file);
  // Keep the historical 35-record interop prefix plus the full extended trace.
  reply_file=$fopen("runtime_replies_extended.bin","wb");for(i=0;i<60*42;i=i+1)$fwrite(reply_file,"%c",response[i]);$fclose(reply_file);
  $display("TB_PC_RUNTIME_CONTROL_PASS replies=60 mode=1 geometry=1 affine=ON_OFF reference=uploaded retired_commands=NAK6");$finish;
 end
 initial begin #5000000;$fatal(1,"PC runtime timeout state=%0d bytes=%0d",dut.state,replies);end
endmodule

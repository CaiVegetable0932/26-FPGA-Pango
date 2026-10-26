`timescale 1ns/1ps
// Compare the real upload + colour-consumer pair to its frozen baseline.
// New bytewise proof must match original signed coefficient legality, including
// chunk retries/boundaries, CRC failures, busy and frame-atomic publication.
module tb_stream_ccm_upload;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg request_valid=0,response_ready=0,capture_boundary=0;
 reg [63:0] now_us=0,epoch=2,frame_id=0;
 reg [7:0] command=0;reg [6:0] length=0;reg [639:0] payload=0;
 wire [1:0] request_ready,response_valid,submit;
 wire [7:0] response_code[0:1],consumer_code[0:1];
 wire [31:0] transaction[0:1],version[0:1],entity_id[0:1];
 wire [15:0] accepted_bytes[0:1],entity_kind[0:1],entity_length[0:1];
 wire [2047:0] entity_body[0:1];wire [2303:0] status[0:1];
 wire [31:0] cv[0:1],black[0:1];wire [63:0] gains[0:1];wire [161:0] ccm[0:1];
 integer commits[0:1],checks=0,trial,offset,n,seed=49217;
 reg [511:0] body;reg [31:0] crc;reg [191:0] header;
 reg [7:0] expected;integer before_commit;
 pc_reference_upload_baseline #(.ENTITY_MASK(16'h0008)) u0(
  .clk(clk),.rst_n(rst_n),.now_us(now_us),.request_valid(request_valid),.request_ready(request_ready[0]),
  .command(command),.length(length),.payload(payload),.response_valid(response_valid[0]),.response_ready(response_ready),
  .response_code(response_code[0]),.transaction(transaction[0]),.accepted_bytes(accepted_bytes[0]),
  .reference_submit_valid(submit[0]),.reference_entity(),.entity_body(entity_body[0]),.entity_kind(entity_kind[0]),
  .entity_length(entity_length[0]),.reference_version(version[0]),.reference_id(entity_id[0]),.reference_code(consumer_code[0]));
 pc_reference_upload #(.ENTITY_MASK(16'h0008),.STREAM_CCM(1)) u1(
  .clk(clk),.rst_n(rst_n),.now_us(now_us),.request_valid(request_valid),.request_ready(request_ready[1]),
  .command(command),.length(length),.payload(payload),.response_valid(response_valid[1]),.response_ready(response_ready),
  .response_code(response_code[1]),.transaction(transaction[1]),.accepted_bytes(accepted_bytes[1]),
  .reference_submit_valid(submit[1]),.reference_entity(),.entity_body(entity_body[1]),.entity_kind(entity_kind[1]),
  .entity_length(entity_length[1]),.reference_version(version[1]),.reference_id(entity_id[1]),.reference_code(consumer_code[1]));
 isp_colour_control_baseline #(.SUPPORT_AUTO(0)) c0(.clk(clk),.rst_n(rst_n),.submit_valid(submit[0]),
  .body(entity_body[0][511:0]),.version(version[0]),.entity_id(entity_id[0]),.submit_code(consumer_code[0]),
  .capture_boundary(capture_boundary),.epoch(epoch),.frame_id(frame_id),.capture_version(cv[0]),.capture_black(black[0]),
  .capture_gains(gains[0]),.capture_ccm(ccm[0]),.statistics_valid(1'b0),.red_sum(48'd0),.green_sum(48'd0),.blue_sum(48'd0),.neutral_count(32'd0),.status(status[0]));
 isp_colour_control #(.SUPPORT_AUTO(0),.CCM_PREVALIDATED(1)) c1(.clk(clk),.rst_n(rst_n),.submit_valid(submit[1]),
  .body(entity_body[1][511:0]),.version(version[1]),.entity_id(entity_id[1]),.submit_code(consumer_code[1]),
  .capture_boundary(capture_boundary),.epoch(epoch),.frame_id(frame_id),.capture_version(cv[1]),.capture_black(black[1]),
  .capture_gains(gains[1]),.capture_ccm(ccm[1]),.statistics_valid(1'b0),.red_sum(48'd0),.green_sum(48'd0),.blue_sum(48'd0),.neutral_count(32'd0),.status(status[1]));
 always @(posedge clk)if(rst_n)begin
  if(submit[0])commits[0]++;
  if(submit[1])commits[1]++;
 end
 function [31:0] crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;begin v=c^b;for(integer k=0;k<8;k++)v=(v>>1)^(v[0]?32'hedb88320:0);crc_byte=v;end
 endfunction
 task check(input bit ok,input string name);
  begin checks++;if(!ok)$fatal(1,"STREAM_CCM %s trial=%0d offset=%0d",name,trial,offset);end
 endtask
 task request(input [7:0] cmd,input [6:0] len,input [639:0] data,input [7:0] code);
  begin wait(&request_ready);@(negedge clk);command=cmd;length=len;payload=data;request_valid=1;
   @(negedge clk);request_valid=0;wait(&response_valid);#1;
   check(response_code[0]===code && response_code[1]===code,"response mismatch");
   check(transaction[0]===transaction[1] && accepted_bytes[0]===accepted_bytes[1],"upload ownership");
   check(status[0]===status[1],"public colour status");
   // ACK must span a rising edge, including immediate semantic rejection.
   response_ready=1;@(posedge clk);@(negedge clk);response_ready=0;
  end
 endtask
 initial begin
  commits[0]=0;commits[1]=0;repeat(3)@(negedge clk);rst_n=1;
  for(trial=0;trial<240;trial++)begin
   body=0;body[32+:64]=64'h1000100010001000;body[96]=1;
   // Legal dense matrices, exact +/- limits, row overflow, wrong extension,
   // and unrelated invalid gains exercise both halves of the shared proof.
   for(integer k=0;k<9;k++)body[128+k*32+:32]=$signed($random(seed))%35000;
   case(trial%10)
    0:begin body[128+:96]=0;body[128+:32]=-131072;end
    1:begin body[128+:32]=131071;body[160+:32]=1;body[192+:32]=0;end
    2:begin body[128+:32]=131071;body[160+:32]=2;end
    3:body[160+:32]=32'h00020000;
    4:body[192+:32]=32'hfffdffff;
    5:body[32+:16]=0;
    6:body[112]=1;
    7:begin body[384+:32]=-131072;body[352+:32]=0;body[320+:32]=0;end
    default:;
   endcase
   crc='1;for(integer b=0;b<64;b++)crc=crc_byte(crc,body[b*8+:8]);crc=~crc;
   header={crc,16'd0,16'd64,32'(trial+1),32'(trial+2),32'(trial+1),16'd1,16'd3};
   request('ha1,24,{448'd0,header},0);before_commit=commits[0];
   offset=0;
   while(offset<64)begin
    n=trial%4==0?1:trial%4==1?7:trial%4==2?19:64;if(n>64-offset)n=64-offset;
    payload=0;payload[31:0]=trial+1;payload[47:32]=offset;payload[55:48]=n;
    for(integer b=0;b<n;b++)payload[64+b*8+:8]=body[(offset+b)*8+:8];
    request('ha2,n+8,payload,0);request('ha2,n+8,payload,0);
    // A mismatched retry is rejected without modifying the streamed proof.
    payload[64]=~payload[64];request('ha2,n+8,payload,11);offset+=n;
   end
   request('ha3,12,{544'd0,32'd0,crc^32'd1,32'(trial+1)},11);
   #1;expected=consumer_code[0];
   request('ha3,12,{544'd0,32'd0,crc,32'(trial+1)},expected);
   request('ha3,12,{544'd0,32'd0,crc,32'(trial+1)},expected);
   check(commits[0]==commits[1] && commits[0]==before_commit+(expected==0),"exactly-once commit");
   if(expected!=0)request('ha5,8,{576'd0,32'(trial+1),16'd0,16'd1},0);
   // Do not expose a queued configuration until its original capture edge.
   @(negedge clk);capture_boundary=1;frame_id++;
   @(negedge clk);capture_boundary=0;#1;
   check({cv[0],black[0],gains[0],ccm[0]}==={cv[1],black[1],gains[1],ccm[1]},"frame publication");
   check(status[0]===status[1],"applied body/identity");
  end
  $display("STREAM_CCM_PASS transactions=%0d checks=%0d accepted=%0d",trial,checks,commits[0]);$finish;
 end
 initial begin #10000000;$fatal(1,"STREAM_CCM_TIMEOUT");end
endmodule

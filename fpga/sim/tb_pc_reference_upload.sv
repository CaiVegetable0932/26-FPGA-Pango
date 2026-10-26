`timescale 1ns/1ps
// Whole entity CRC, exact retry bytes, bounds, timeout and reference geometry.
module tb_pc_reference_upload;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg [63:0] now_us=0;reg request_valid=0,response_ready=0;
 wire request_ready,response_valid;reg [7:0] command=0;reg [6:0] length=0;
 reg [639:0] payload=0;wire [7:0] response_code;
 wire [31:0] transaction,reference_version,reference_id;wire [15:0] accepted_bytes;
 wire reference_submit_valid;wire [511:0] reference_entity;
 wire [2047:0] entity_body;wire [15:0] entity_kind,entity_length;
 reg [7:0] reference_code=0;integer submissions=0,checks=0;
 reg [511:0] body=0,guard_entity=0;wire legal;
 reg [2047:0] lut_body;reg [31:0] lut_crc;
 reg [31:0] crc;reg [191:0] header;
 pc_reference_upload #(.ENTITY_MASK(16'h037e)) dut(.*);
 affine_reference_guard #(.WIDTH(35),.HEIGHT(33)) guard(.entity(guard_entity),.legal(legal));
 always @(posedge clk)if(reference_submit_valid)submissions=submissions+1;
 function [31:0] crc_byte(input [31:0] c,input [7:0] b);
  reg [31:0] v;integer k;
  begin v=c^b;for(k=0;k<8;k=k+1)v=(v>>1)^(v[0]?32'hedb88320:0);crc_byte=v;end
 endfunction
 task check(input condition,input [511:0] message);
  begin if(condition!==1'b1)$fatal(1,"REFERENCE_UPLOAD_FAIL %0s",message);checks=checks+1;end
 endtask
 task request(input [7:0] cmd,input [6:0] size,input [639:0] bytes,input [7:0] expected);
  begin
   wait(request_ready);@(negedge clk);command=cmd;length=size;payload=bytes;request_valid=1;
   @(negedge clk);request_valid=0;wait(response_valid);#1;
   check(response_code==expected,"response code");response_ready=1;
   @(posedge clk);@(negedge clk);response_ready=0;
  end
 endtask
 initial begin
  body[0+:32]=32*65536;body[32+:32]=32*65536;
  body[64+:32]=17*65536;body[96+:32]=16*65536;
  body[128+:32]=2097152;body[192+:32]=-17*2097152;
  body[256+:32]=2097152;body[288+:32]=-16*2097152;
  body[320+:16]=35;body[336+:16]=33;body[352+:32]=1;body[384+:16]=1;
  guard_entity=body;#1;check(legal,"normalized reference accepted");
  guard_entity[128+:32]=2097153;#1;check(!legal,"matrix/intrinsics disagreement");
  guard_entity=body;guard_entity[160+:32]=1;#1;check(!legal,"rotated reference rejected");
  guard_entity=body;guard_entity[0+:32]=0;#1;check(!legal,"zero focal rejected");
  guard_entity=body;guard_entity[400]=1;#1;check(!legal,"reserved bits rejected");
  crc=32'hffffffff;for(integer i=0;i<64;i=i+1)crc=crc_byte(crc,body[i*8+:8]);crc=~crc;
  header={crc,16'd0,16'd64,32'd1,32'd2,32'd23,16'd1,16'd9};
  repeat(3)@(negedge clk);rst_n=1;
  request(8'ha1,24,{448'd0,header},0);
  request(8'ha1,24,{448'd0,header},0);
  check(transaction==23 && accepted_bytes==0,"BEGIN retry preserves frontier");
  request(8'ha3,12,{544'd0,32'd0,crc,32'd23},11);
  request(8'ha2,40,{320'd0,body[255:0],8'd0,8'd32,16'd0,32'd23},0);
  request(8'ha2,40,{320'd0,body[255:0],8'd0,8'd32,16'd0,32'd23},0);
  check(accepted_bytes==32,"CHUNK retry does not advance frontier");
  request(8'ha2,40,{320'd0,body[255:0]^256'd1,8'd0,8'd32,16'd0,32'd23},11);
  request(8'ha2,40,{320'd0,body[511:256],8'd0,8'd32,16'd31,32'd23},11);
  request(8'ha2,40,{320'd0,body[511:256],8'd0,8'd32,16'd32,32'd23},0);
  check(accepted_bytes==64 && reference_entity==body,"complete immutable staging");
  request(8'ha3,12,{544'd0,32'd0,crc^32'd1,32'd23},11);
  reference_code=4;request(8'ha3,12,{544'd0,32'd0,crc,32'd23},4);
  check(submissions==0 && transaction==23,"busy commit retains upload");
  // Internal validation wait never leaks 0xff onto the protocol. A bounded
  // timeout returns ordinary busy without destroying the uploaded entity.
  reference_code=8'hff;request(8'ha3,12,{544'd0,32'd0,crc,32'd23},4);
  check(submissions==0 && transaction==23 && reference_entity==body,"validation timeout changed transaction");
  fork
   begin repeat(40)@(negedge clk);reference_code=0;end
   begin request(8'ha3,12,{544'd0,32'd0,crc,32'd23},0);end
  join
  request(8'ha3,12,{544'd0,32'd0,crc,32'd23},0);
  check(submissions==1 && transaction==0,"COMMIT retry queues exactly once");
  header[63:32]=24;header[95:64]=3;
  request(8'ha1,24,{448'd0,header},0);
  now_us=2000001;repeat(3)@(negedge clk);
  check(transaction==0 && accepted_bytes==0,"staging timeout");
  // The generic gateway must retain all 256 LUT bytes and the ninth frontier
  // bit. Four independent 64-byte chunks cover the largest active schema.
  for(integer i=0;i<256;i=i+1)lut_body[i*8+:8]=i;
  lut_crc=32'hffffffff;for(integer i=0;i<256;i=i+1)lut_crc=crc_byte(lut_crc,lut_body[i*8+:8]);lut_crc=~lut_crc;
  header={lut_crc,16'd0,16'd256,32'd7,32'd2,32'd25,16'd1,16'd2};
  request(8'ha1,24,{448'd0,header},0);
  for(integer block=0;block<4;block=block+1)
   request(8'ha2,72,{64'd0,lut_body[block*512+:512],8'd0,8'd64,16'(block*64),32'd25},0);
  request(8'ha2,72,{64'd0,lut_body[1536+:512],8'd0,8'd64,16'd192,32'd25},0);
  check(accepted_bytes==256 && entity_kind==2 && entity_body==lut_body,"256-byte LUT complete");
  request(8'ha3,12,{544'd0,32'd0,lut_crc,32'd25},0);
  check(submissions==2,"generic LUT commit queued exactly once");
  $display("TB_PC_REFERENCE_UPLOAD_PASS checks=%0d",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"REFERENCE_UPLOAD_TIMEOUT");end
endmodule

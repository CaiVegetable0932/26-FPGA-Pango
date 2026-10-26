`timescale 1ns/1ps
// Prove canonical storage never launders illegal raw fields, while accepted
// entities retain their exact bytes, version/ID and capture-boundary identity.
module tb_reference_canonical_bank;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,attempt=0,capture=0;
 reg [511:0] raw=0,good_body,saved_body;
 reg [31:0] version=1,id=7;
 wire valid,legal,legacy_legal,ready,pending,applied;
 wire [511:0] active,captured;
 wire [31:0] active_version,active_id,capture_version,capture_id;
 wire [63:0] applied_epoch,applied_frame;
 // Exactly the production post-validation projection; the raw guard retains
 // all checks and only its completed legal result authorizes submission.
 wire [511:0] canonical={112'd0,16'd1,raw[383:352],16'd1080,16'd1920,
                        raw[319:256],32'd0,raw[223:192],32'd0,raw[159:0]};
 affine_reference_guard #(.PIPELINED(1)) guard(.clk(clk),.rst_n(rst_n),.entity(raw),.legal(legal),.result_valid(valid));
 affine_reference_guard legacy(.entity(raw),.legal(legacy_legal));
 frame_parameter_bank bank(.clk(clk),.rst_n(rst_n),.submit_valid(attempt&&valid&&legal),
  .submit_ready(ready),.entity_validated(legal),.entity(canonical),.version(version),.entity_id(id),
  .received(),.validated(),.rejected(),.capture_boundary(capture),.epoch(64'h123456789abcdef0),.frame_id(64'd42),
  .active_entity(active),.active_version(active_version),.active_entity_id(active_id),
  .capture_entity(captured),.capture_version(capture_version),.capture_entity_id(capture_id),
  .applied(applied),.applied_ready(1'b1),.applied_epoch(applied_epoch),.applied_frame(applied_frame),.pending(pending));
 integer field,cycles,checks=0;
 task await_result;
  begin
   #1;cycles=0;
   while(!valid && cycles<73)begin @(negedge clk);cycles=cycles+1;end
   if(!valid || legal!==legacy_legal)$fatal(1,"canonical guard result/bound mismatch field=%0d",field);
  end
 endtask
 initial begin
  good_body=0;good_body[0+:32]=32'h04000000;good_body[32+:32]=32'h04000000;
  good_body[128+:32]=65536;good_body[256+:32]=65536;
  good_body[320+:16]=1920;good_body[336+:16]=1080;good_body[352+:32]=55;good_body[384+:16]=1;
  repeat(3)@(negedge clk);rst_n=1;raw=good_body;await_result();
  if(!legal || canonical!==raw)$fatal(1,"legal projection changed entity");
  attempt=1;@(negedge clk);attempt=0;
  if(!pending || captured!==good_body || capture_version!=1 || capture_id!=7)$fatal(1,"pending snapshot mismatch");
  // Mutating the live bus after commit must not alter the pending frame.
  raw=~good_body;capture=1;@(negedge clk);capture=0;
  if(active!==good_body || active_version!=1 || active_id!=7 || !applied ||
     applied_epoch!=64'h123456789abcdef0 || applied_frame!=42)$fatal(1,"capture identity mismatch");
  saved_body=active;@(negedge clk);version=2;id=8;
  for(field=0;field<9;field=field+1)begin
   @(negedge clk);raw=good_body;
   case(field)
    0:raw[160+:32]=1;
    1:raw[224+:32]=32'hffffffff;
    2:raw[320+:16]=1919;
    3:raw[336+:16]=1081;
    4:raw[384+:16]=0;
    5:raw[384+:16]=2;
    6:raw[400]=1;
    7:raw[511]=1;
    8:raw[352+:32]=0;
   endcase
   attempt=1;await_result();
   if(legal)$fatal(1,"malformed raw field became legal field=%0d",field);
   repeat(2)@(negedge clk);attempt=0;capture=1;@(negedge clk);capture=0;
   if(pending || active!==saved_body || active_version!=1 || active_id!=7 || applied)
    $fatal(1,"illegal canonical submission changed bank field=%0d",field);
   checks=checks+1;
  end
  // Nonzero centre/translation and embedded calibration ID remain unmodified.
  @(negedge clk);raw=good_body;raw[64+:32]=65536;raw[192+:32]=-65536;raw[352+:32]=99;
  await_result();if(!legal || canonical!==raw)$fatal(1,"nonzero valid projection mismatch");
  saved_body=raw;attempt=1;@(negedge clk);attempt=0;capture=1;@(negedge clk);capture=0;
  if(active!==saved_body || active_version!=2 || active_id!=8)$fatal(1,"second valid commit mismatch");
  $display("REFERENCE_CANONICAL_BANK_PASS malformed=%0d valid_commits=2",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"canonical bank timeout");end
endmodule

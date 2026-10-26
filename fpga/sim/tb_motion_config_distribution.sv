`timescale 1ns/1ps
// Compare every public field before and after clock edges against frozen L.
// Random submissions include legal/illegal entities, pending collisions,
// coincident capture, reset, and changing live bodies after acceptance.
module tb_motion_config_distribution #(parameter SUPPORT_VIEWPORT=1);
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,submit_valid=0,capture_boundary=0;
 reg [15:0] kind=0,read_kind=0;
 reg [1023:0] entity=0;
 reg [31:0] version=1,entity_id=1;
 reg [63:0] epoch=1,frame_id=0;
 wire [7:0] code[0:1];
 wire [255:0] cs[0:1],cv[0:1],s[0:1],v[0:1];
 wire [127:0] cc[0:1],c[0:1],versions[0:1];
 wire [1023:0] cp[0:1],p[0:1];
 wire [31:0] sv[0:1],vv[0:1],cver[0:1],pv[0:1];
 wire [2303:0] status[0:1];
 motion_config_bank #(.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT)) dut(.clk(clk),.rst_n(rst_n),.submit_valid(submit_valid),.kind(kind),.entity(entity),
  .version(version),.entity_id(entity_id),.submit_code(code[0]),.capture_boundary(capture_boundary),
  .epoch(epoch),.frame_id(frame_id),.capture_stabilization(cs[0]),.capture_viewport(cv[0]),
  .capture_completion(cc[0]),.capture_pose(cp[0]),.stabilization(s[0]),.viewport(v[0]),
  .completion(c[0]),.pose(p[0]),.stabilization_version(sv[0]),.viewport_version(vv[0]),
  .completion_version(cver[0]),.pose_version(pv[0]),.capture_versions(versions[0]),
  .read_kind(read_kind),.status(status[0]));
 motion_config_bank_baseline #(.SUPPORT_VIEWPORT(SUPPORT_VIEWPORT)) ref_dut(.clk(clk),.rst_n(rst_n),.submit_valid(submit_valid),.kind(kind),.entity(entity),
  .version(version),.entity_id(entity_id),.submit_code(code[1]),.capture_boundary(capture_boundary),
  .epoch(epoch),.frame_id(frame_id),.capture_stabilization(cs[1]),.capture_viewport(cv[1]),
  .capture_completion(cc[1]),.capture_pose(cp[1]),.stabilization(s[1]),.viewport(v[1]),
  .completion(c[1]),.pose(p[1]),.stabilization_version(sv[1]),.viewport_version(vv[1]),
  .completion_version(cver[1]),.pose_version(pv[1]),.capture_versions(versions[1]),
  .read_kind(read_kind),.status(status[1]));
 integer seed=42,iteration=0,checks=0,publishes=0,accepts=0;
 task compare;
  begin
   if({code[0],cs[0],cv[0],cc[0],cp[0],s[0],v[0],c[0],p[0],sv[0],vv[0],cver[0],pv[0],versions[0],status[0]} !==
      {code[1],cs[1],cv[1],cc[1],cp[1],s[1],v[1],c[1],p[1],sv[1],vv[1],cver[1],pv[1],versions[1],status[1]})
    $fatal(1,"configuration cycle mismatch iteration=%0d",iteration);
   checks++;
  end
 endtask
 initial begin
  if($value$plusargs("seed=%d",seed))begin end
  repeat(3)@(negedge clk);
  for(iteration=0;iteration<6000;iteration++)begin
   rst_n=iteration%197!=0;submit_valid=($random(seed)&3)!=0;
   capture_boundary=($random(seed)&3)==0;
   kind=($random(seed)&1)?8:6;read_kind=kind;
   entity=0;
   // Every fifth body is deliberately invalid; the rest exercise large pose
   // payloads or disabled-completion entities without weakening validation.
   if(kind==8)begin
    entity[0]=1;entity[63:32]=9;entity[128+:32]=-90000;entity[160+:32]=90000;
    entity[192+:32]=-80000;entity[224+:32]=80000;entity[256+:32]=65536;
    entity[288+:32]=1000;entity[320+:32]=7;entity[352+:32]=17;
    for(integer k=12;k<30;k++)entity[k*32+:32]=$random(seed);
   end else begin entity[15:8]=2;entity[47:32]=255;entity[95:64]=$random(seed);end
   if(iteration%5==0)entity[31:24]=8'hff;
   if(iteration%11==0)kind=4;
   if(iteration%13==0)read_kind=5;
   version=iteration%17==0?0:iteration+1;entity_id=iteration%19==0?0:iteration+7;
   frame_id=iteration;epoch=1+iteration/197;
   #1;compare();
   if(rst_n && submit_valid && code[0]==0)accepts++;
   if(rst_n && capture_boundary && dut.pending)publishes++;
   @(posedge clk);#1;compare();@(negedge clk);
  end
  if(accepts<500 || publishes<500)$fatal(1,"insufficient commit coverage");
  $display("MOTION_CONFIG_DISTRIBUTION_PASS checks=%0d accepts=%0d publishes=%0d",checks,accepts,publishes);$finish;
 end
endmodule

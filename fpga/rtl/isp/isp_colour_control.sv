`timescale 1ns/1ps
// Atomic ISP_COLOR entity. Runtime matrix uses linear RGB12; black/gains and
// coefficients are captured together before a source is admitted. Automatic
// gain updates create a new version and can only affect a subsequent source.
// SUPPORT_AUTO=0 retains manual black/gain/CCM controls and rejects AWB mode.
// The parameter is a build capability, not an implicit downgrade of a request.
module isp_colour_control #(parameter SUPPORT_AUTO=1,parameter CCM_PREVALIDATED=0)(
 input clk,rst_n,submit_valid,input [511:0] body,input [31:0] version,entity_id,
 output reg [7:0] submit_code,input capture_boundary,input [63:0] epoch,frame_id,
 output [31:0] capture_version,output [31:0] capture_black,
 output [63:0] capture_gains,output reg [161:0] capture_ccm,
 input statistics_valid,input [47:0] red_sum,green_sum,blue_sum,input [31:0] neutral_count,
 output reg [2303:0] status
);
 localparam [161:0] IDENTITY=162'd16384|(162'd16384<<72)|(162'd16384<<144);
 reg [511:0] active,queued;reg pending;reg [31:0] av,aid,qv,qid;
 reg [63:0] applied_epoch,applied_frame;reg [15:0] held;
 wire [511:0] selected=pending?queued:active;
 reg legal;reg signed [17:0] coefficient;reg [19:0] row_bound;integer i,j,k;
 reg [511:0] canonical_body;
 // Validation precedes canonical storage: signed extension bits and reserved
 // zeros remain identical on the wire but no longer consume independent FFs.
 always @*begin
  canonical_body=body;canonical_body[103:97]=0;canonical_body[111:105]=0;canonical_body[127:112]=0;
  // Validation rejects AWB in the manual profile; store its mode bit as a
  // literal zero too so synthesis need not prove the submit predicate.
  if(!SUPPORT_AUTO)canonical_body[104]=0;
  for(k=0;k<9;k=k+1)canonical_body[128+k*32+:32]={{14{body[145+k*32]}},body[128+k*32+:18]};
 end
 // Three full signed products need 33 bits. Restrict each absolute row sum to
 // 8.0 (131072 Q14), ensuring a deliberately conservative calibrated domain.
 always @*begin
  legal=body[96+:8]<=1 && body[104+:8]<=(SUPPORT_AUTO?1:0) && body[112+:16]==0;
  for(i=0;i<4;i=i+1)if(body[32+i*16+:16]==0)legal=0;
  // Only the physical board's CRC-bound STREAM_CCM gateway may omit this
  // parallel proof. Direct callers keep signed extension and all row bounds.
  if(!CCM_PREVALIDATED)for(i=0;i<3;i=i+1)begin
   row_bound=0;
   for(j=0;j<3;j=j+1)begin
    coefficient=$signed(body[128+(i*3+j)*32+:18]);
    if(body[146+(i*3+j)*32+:14]!={14{coefficient[17]}})legal=0;
    row_bound=row_bound+{2'd0,(coefficient[17]?(~coefficient+18'd1):coefficient)};
   end
   if(row_bound>131072)legal=0;
  end
  if(body[104+:8]==1)begin
   if(body[448+:16]<256 || body[464+:16]<body[448+:16] || body[480+:16]==0 || body[480+:16]>256 || body[496+:16]==0)legal=0;
   for(i=0;i<4;i=i+1)if(body[32+i*16+:16]<body[448+:16] || body[32+i*16+:16]>body[464+:16])legal=0;
  end
  submit_code=!legal || version==0 || version[31] || entity_id==0 || entity_id[31] || version<=av?11:pending?4:0;
  capture_ccm=IDENTITY;
  if(selected[96])for(i=0;i<9;i=i+1)capture_ccm[i*18+:18]=selected[128+i*32+:18];
  status=0;status[15:0]=1;status[31:16]=3;status[32+:32]=av;status[64+:32]=aid;
  status[96+:16]=64;status[112+:8]={6'd0,pending,1'b1};
  status[128+:64]=applied_epoch;status[192+:64]=applied_frame;status[256+:512]=active;
 end
 assign capture_version=pending?qv:av,capture_black=selected[31:0],capture_gains=selected[32+:64];
 function [15:0] adjust(input [15:0] gain,input [31:0] channel,target,input [15:0] low,high,step);
  reg [16:0] candidate;
  reg [32:0] channel_plus_band,target_plus_band;
  begin
   candidate=gain;channel_plus_band={1'b0,channel}+{6'd0,target[31:5]};target_plus_band={1'b0,target}+{6'd0,target[31:5]};
   // A 1/32 neutral deadband avoids chasing quantization and sensor noise.
   if(channel_plus_band<{1'b0,target})candidate={1'b0,gain}+step;
   else if({1'b0,channel}>target_plus_band)candidate=gain>step?gain-step:0;
   adjust=candidate<low?low:candidate>high?high:candidate[15:0];
  end
 endfunction
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   active<=0;active[32+:64]<=64'h1000100010001000;
   active[128+:32]<=16384;active[256+:32]<=16384;active[384+:32]<=16384;
   queued<=0;pending<=0;av<=1;aid<=1;qv<=0;qid<=0;applied_epoch<=0;applied_frame<=0;held<=0;
  end else begin
   if(capture_boundary && pending)begin active<=queued;av<=qv;aid<=qid;pending<=0;applied_epoch<=epoch;applied_frame<=frame_id;held<=0;end
   if(submit_valid && submit_code==0)begin queued<=canonical_body;qv<=version;qid<=entity_id;pending<=1;end
   // Only legal completed pre-CCM neutral statistics may drive bounded AWB.
   // RAW1080 sampled RGB sums fit 25 bits; 32-bit arithmetic keeps margin
   // and rejects impossible upper bits instead of truncating invalid sums.
   // Gr/Gb keep their calibrated ratio; R/B approach their green reference.
   if(SUPPORT_AUTO && statistics_valid && !pending && !submit_valid && active[104+:8]==1 && neutral_count>=16 && red_sum[47:32]==0 && green_sum[47:32]==0 && blue_sum[47:32]==0 && av<32'h7fffffff)begin
    if(held<active[496+:16])held<=held+1'b1;
    else if(adjust(active[32+:16],red_sum[31:0],green_sum[31:0],active[448+:16],active[464+:16],active[480+:16])!=active[32+:16] ||
      adjust(active[80+:16],blue_sum[31:0],green_sum[31:0],active[448+:16],active[464+:16],active[480+:16])!=active[80+:16])begin
     queued<=active;queued[32+:16]<=adjust(active[32+:16],red_sum[31:0],green_sum[31:0],active[448+:16],active[464+:16],active[480+:16]);
     queued[80+:16]<=adjust(active[80+:16],blue_sum[31:0],green_sum[31:0],active[448+:16],active[464+:16],active[480+:16]);
     qv<=av+1'b1;qid<=aid;pending<=1;
    end
   end
  end
 end
endmodule

`timescale 1ns/1ps
// Bounded tone policy, upload staging and two-page source lifetime management.
// A stable bundled mailbox copies one whole curve only while geometry is idle.
// Captures continue using the old page during copying; pages with source
// references are never overwritten. History owns S1, not the old tone page.
// This specialization is legal ONLY behind pc_reference_upload's CRC and
// monotonic byte scan. Standalone/direct consumers retain complete validation.
// Optional build capabilities preserve the manual built-in curves. Disabled
// AUTO or custom upload requests are rejected, never mapped to another curve.
module tone_entity_control #(parameter LUT_PREVALIDATED=0,SUPPORT_AUTO=1,SUPPORT_UPLOAD=1)(
 input clk,rst_n,processing_clk,processing_rst_n,
 input submit_valid,input [15:0] kind,input [2047:0] body,input [31:0] version,entity_id,
 output reg [7:0] submit_code,input [15:0] read_kind,output reg [2303:0] status,
 input legacy_valid,input [1:0] legacy_mode,input [31:0] legacy_version,output legacy_ready,
 input capture_boundary,input [63:0] epoch,frame_id,
 output [1:0] capture_mode,output [31:0] capture_version,capture_entity_id,capture_lut_version,
 output capture_page,
 output [1:0] current_mode,output [31:0] current_version,output current_pending,
 output [63:0] current_epoch,current_frame,
 input bind_valid,input [1:0] bind_slot,input bind_page,
 input release_valid,input [1:0] release_slot,input cancel_valid,input [1:0] cancel_slot,
 input geometry_idle,output programming,output initialized,
 input statistics_valid,input [47:0] luminance_sum,input [31:0] samples,
 output lut_write,output [7:0] lut_addr,lut_data,output lut_commit,lut_page,
 output [31:0] lut_program_version
);
 reg [255:0] active_config,queued_config;
 reg [31:0] active_version,active_id,queued_version,queued_id;
 reg [63:0] applied_epoch,applied_frame;
 reg [2047:0] uploaded;reg [31:0] uploaded_version,uploaded_id;
 reg [63:0] upload_epoch,upload_frame;reg upload_applied;
 reg active_page,publish_page,publish_pending;reg [31:0] page_generation,publish_generation;
 reg [1:0] preferred_mode;reg [1:0] active_curve;reg [15:0] held_frames;
 reg [2:0] owned,owned_page;reg [31:0] generation;
 reg request,copy_pending,copy_started,copy_page;reg [1:0] copy_curve;
 reg [31:0] copy_generation;reg seeded;
 (* syn_preserve=1 *) reg ack_meta,ack_sync;
 reg acknowledgement;
 wire page0_busy=|(owned & ~owned_page),page1_busy=|(owned & owned_page);
 wire free_other=active_page?!page0_busy:!page1_busy;
 wire pending=copy_pending || publish_pending;
 reg config_legal,lut_legal;integer i;
 // A disabled AUTO bit is canonicalized to zero after validation, allowing
 // synthesis to remove mode storage without proving the submit predicate.
 wire [255:0] canonical_config={160'd0,body[95:24],5'd0,body[18:16],6'd0,body[9:8],6'd0,(SUPPORT_AUTO?body[1:0]:{1'b0,body[0]})};
 wire [255:0] selected=publish_pending?queued_config:active_config;
 assign capture_page=publish_pending?publish_page:active_page;
 assign capture_version=publish_pending?queued_version:active_version;
 assign capture_entity_id=publish_pending?queued_id:active_id;
 assign capture_lut_version=publish_pending?publish_generation:page_generation;
 assign capture_mode=selected[7:0]==0?2'd0:2'd1;
 assign programming=copy_pending;
 assign initialized=seeded;
 assign legacy_ready=seeded && !pending && !submit_valid && legacy_mode<2 && legacy_version>active_version && !legacy_version[31];
 assign current_mode=active_config[7:0]==0?0:1,current_version=active_version,current_pending=pending;
 assign current_epoch=applied_epoch,current_frame=applied_frame;
 always @*begin
  config_legal=body[7:0]<=2 && body[15:8]<=3 && body[23:16]!=0 && body[23:19]==0 &&
   body[39:32]<body[47:40] && body[63:48]!=0 && body[255:96]==0;
  if(body[7:0]==2 && !body[16+body[9:8]])config_legal=0;
  if(!SUPPORT_AUTO && body[7:0]==2)config_legal=0;
  if(!SUPPORT_UPLOAD && body[15:8]==3)config_legal=0;
  if(body[15:8]==3 && (body[7:0]==2 || body[95:64]!=uploaded_version || uploaded_version==0))config_legal=0;
  lut_legal=1;
  if(SUPPORT_UPLOAD && !LUT_PREVALIDATED)for(i=1;i<256;i=i+1)if(body[i*8+:8]<body[(i-1)*8+:8])lut_legal=0;
  submit_code=6;
  if(kind==1)submit_code=generation==32'hffffffff || !config_legal || version<=active_version || version[31] || entity_id==0 || entity_id[31]?11:
   (!seeded || pending || !free_other)?4:0;
  if(kind==2 && SUPPORT_UPLOAD)submit_code=!lut_legal || version==0 || version[31] || entity_id==0 || entity_id[31] || version<=uploaded_version?11:(pending || (uploaded_version!=0 && !upload_applied))?4:0;
  status=0;status[15:0]=1;status[31:16]=read_kind;
  if(read_kind==1)begin
   status[32+:32]=active_version;status[64+:32]=active_id;status[96+:16]=32;
   status[112+:8]={6'd0,pending,seeded};status[128+:64]=applied_epoch;status[192+:64]=applied_frame;status[256+:256]=active_config;
  end else if(read_kind==2 && SUPPORT_UPLOAD)begin
   status[32+:32]=uploaded_version;status[64+:32]=uploaded_id;status[96+:16]=256;
   status[112+:8]={6'd0,(uploaded_version!=0 && !upload_applied),uploaded_version!=0};status[128+:64]=upload_epoch;status[192+:64]=upload_frame;status[256+:2048]=uploaded;
  end
 end
 // Source-domain request payload is held until the returned toggle. The
 // processing clock performs all 256 writes and a separate commit cycle.
 (* syn_preserve=1 *) reg request_meta,request_sync;
 reg copy_active,commit_pulse;reg [7:0] cursor;wire [7:0] builtin_value;
 tone_builtin_lut builtin(.curve(copy_curve),.address(cursor),.value(builtin_value));
 assign lut_write=copy_active,lut_addr=cursor,lut_data=(SUPPORT_UPLOAD && copy_curve==3)?uploaded[cursor*8+:8]:builtin_value;
 assign lut_commit=commit_pulse,lut_page=copy_page,lut_program_version=copy_generation;
 always @(posedge processing_clk or negedge processing_rst_n)begin
  if(!processing_rst_n)begin request_meta<=0;request_sync<=0;acknowledgement<=0;copy_active<=0;commit_pulse<=0;cursor<=0;end
  else begin
   request_meta<=request;request_sync<=request_meta;commit_pulse<=0;
   if(!copy_active && !commit_pulse && request_sync!=acknowledgement)begin copy_active<=1;cursor<=0;end
   if(copy_active)begin
    if(cursor==255)begin copy_active<=0;commit_pulse<=1;end else cursor<=cursor+1'b1;
   end
   if(commit_pulse)acknowledgement<=request_sync;
  end
 end
 // Explicit operand widths avoid promotion of the low-threshold ternary to
 // a signed 32-bit subtract/multiplier. All 32-bit count values still work.
 wire [7:0] lower_target=active_config[39:32]>active_config[31:24]?active_config[39:32]-active_config[31:24]:8'd0;
 wire [8:0] upper_target={1'b0,active_config[47:40]}+{1'b0,active_config[31:24]};
 wire [39:0] lower_product=lower_target*samples;
 wire [40:0] upper_product=upper_target*samples;
 reg [1:0] target_curve;
 always @*begin
  target_curve=active_curve;
  // Comparisons are based on a completed source, with a deadband around the
  // target interval. Each transition changes at most one built-in curve.
  if(luminance_sum < {8'd0,lower_product})begin
   if(active_curve==2 && active_config[17])target_curve=1;
   else if(active_curve>0 && active_config[16])target_curve=0;
  end else if(luminance_sum > {7'd0,upper_product})begin
   if(active_curve==0 && active_config[17])target_curve=1;
   else if(active_curve<2 && active_config[18])target_curve=2;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   active_config<=0;active_config[23:16]<=7;active_config[31:24]<=4;
   active_config[39:32]<=96;active_config[47:40]<=144;active_config[63:48]<=16;
   active_version<=1;active_id<=1;preferred_mode<=1;active_page<=0;page_generation<=1;active_curve<=0;
   applied_epoch<=0;applied_frame<=0;queued_config<=0;queued_version<=0;queued_id<=0;
   uploaded<=0;uploaded_version<=0;uploaded_id<=0;upload_epoch<=0;upload_frame<=0;upload_applied<=0;
   owned<=0;owned_page<=0;request<=0;copy_pending<=1;copy_started<=0;copy_page<=0;copy_curve<=0;copy_generation<=1;
   ack_meta<=0;ack_sync<=0;publish_pending<=0;publish_page<=0;publish_generation<=0;generation<=1;seeded<=0;held_frames<=0;
  end else begin
   ack_meta<=acknowledgement;ack_sync<=ack_meta;
   if(release_valid)owned[release_slot]<=0;
   if(cancel_valid)owned[cancel_slot]<=0;
   if(bind_valid)begin owned[bind_slot]<=1;owned_page[bind_slot]<=bind_page;end
   if(copy_pending && !copy_started && geometry_idle)begin request<=!request;copy_started<=1;end
   if(copy_pending && copy_started && ack_sync==request)begin
    copy_pending<=0;copy_started<=0;
    if(!seeded)seeded<=1;
    else begin publish_pending<=1;publish_page<=copy_page;publish_generation<=copy_generation;end
   end
   if(capture_boundary && publish_pending)begin
    active_config<=queued_config;active_version<=queued_version;active_id<=queued_id;
    active_page<=publish_page;page_generation<=publish_generation;active_curve<=copy_curve;
    applied_epoch<=epoch;applied_frame<=frame_id;publish_pending<=0;held_frames<=0;
    if(SUPPORT_UPLOAD && queued_config[15:8]==3)begin upload_applied<=1;upload_epoch<=epoch;upload_frame<=frame_id;end
   end
   if(SUPPORT_UPLOAD && submit_valid && submit_code==0 && kind==2)begin uploaded<=body;uploaded_version<=version;uploaded_id<=entity_id;upload_applied<=0;end
   if(submit_valid && submit_code==0 && kind==1)begin
    queued_config<=canonical_config;queued_version<=version;queued_id<=entity_id;
    if(body[7:0]!=0)preferred_mode<=SUPPORT_AUTO?body[1:0]:2'd1;
    // Even OFF commits prepare its selected curve so a later legacy enable
    // cannot silently select the previously configured page.
    copy_pending<=1;copy_started<=0;copy_page<=!active_page;copy_curve<=body[9:8];generation<=generation+1'b1;copy_generation<=generation+1'b1;
   end
   if(legacy_valid && legacy_ready && legacy_mode<2 && legacy_version>active_version)begin
    queued_config<=active_config;queued_config[7:0]<=legacy_mode==0?0:preferred_mode;
    queued_version<=legacy_version;queued_id<=active_id;publish_pending<=1;publish_page<=active_page;publish_generation<=page_generation;
   end
   if(SUPPORT_AUTO && statistics_valid && active_config[7:0]==2 && samples!=0 && !pending && !submit_valid && !legacy_valid)begin
    if(held_frames<active_config[63:48])held_frames<=held_frames+1'b1;
    else if(target_curve!=active_curve && free_other && generation!=32'hffffffff)begin
     queued_config<=active_config;queued_config[15:8]<=target_curve;queued_version<=active_version;queued_id<=active_id;
     copy_pending<=1;copy_started<=0;copy_page<=!active_page;copy_curve<=target_curve;
     generation<=generation+1'b1;copy_generation<=generation+1'b1;
    end
   end
  end
 end
endmodule

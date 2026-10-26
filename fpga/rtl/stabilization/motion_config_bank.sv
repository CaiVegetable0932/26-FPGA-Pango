`timescale 1ns/1ps
// Bounded source commit for C3/C6 and disabled C5 settings. C4 kind 4
// and dynamic viewport / enabled completion return UNSUPPORTED (6). ACK is
// queued, and only the source capture edge publishes a whole entity. Published
// bodies are copied into source-owned sidecars by the video integration.
// SUPPORT_VIEWPORT=0 explicitly withdraws kind 5 and publishes a unity crop.
module motion_config_bank #(parameter SUPPORT_VIEWPORT=1)(
 input clk,rst_n,input submit_valid,input [15:0] kind,input [1023:0] entity,
 input [31:0] version,entity_id,output reg [7:0] submit_code,
 input capture_boundary,input [63:0] epoch,frame_id,
 output [255:0] capture_stabilization,capture_viewport,output [127:0] capture_completion,
 output [1023:0] capture_pose,output reg [255:0] stabilization,viewport,
 output reg [127:0] completion,output reg [1023:0] pose,
 output reg [31:0] stabilization_version,viewport_version,completion_version,pose_version,
 output [127:0] capture_versions,
 input [15:0] read_kind,output reg [2303:0] status
);
 reg pending;reg [15:0] held_kind;reg [1023:0] held;reg [31:0] held_version,held_id;
 reg [63:0] applied_epoch,applied_frame;reg [31:0] active_version;reg legal;
 reg [31:0] ids[0:3];reg [63:0] epochs[0:3],frames[0:3];integer ri,j;
 localparam [255:0] UNITY_VIEWPORT=(256'd65536<<32)|(256'd65536<<64)|
                                  (256'd1<<96)|(256'd65536<<160);
 // Legal zoom<=2.0 Q16 and area<=1.0 Q16 need only 18/17 operand bits.
 // Upper-bit range checks below still reject every truncated illegal request.
 wire [35:0] zoom_square=entity[64+:18]*entity[64+:18];
 wire [52:0] retained_area_product=zoom_square*entity[160+:17];
 assign capture_stabilization=pending && held_kind==4?held[255:0]:stabilization;
 // Reserved fields were checked before enqueue. Carry their literal zeroes
 // through both publication paths instead of storing unreachable values.
 wire [255:0] queued_viewport={32'b0,held[223:32],24'b0,held[7:0]};
 // Kind 6 accepts only disabled completion (byte 0 is exactly zero). Make
 // this proven bit explicit so unavailable history capture cannot retain a
 // synthetic enable path through otherwise unreachable queued register data.
 wire [127:0] queued_completion={32'b0,held[95:64],16'b0,held[47:8],8'b0};
 wire [1023:0] queued_pose={64'b0,held[959:32],31'b0,held[0]};
 assign capture_viewport=!SUPPORT_VIEWPORT?UNITY_VIEWPORT:pending && held_kind==5?queued_viewport:viewport;
 assign capture_completion=pending && held_kind==6?queued_completion:completion;
 assign capture_pose=pending && held_kind==8?queued_pose:pose;
 assign capture_versions={pending && held_kind==8?held_version:pose_version,
  pending && held_kind==6?held_version:completion_version,
  !SUPPORT_VIEWPORT?32'd0:pending && held_kind==5?held_version:viewport_version,
  pending && held_kind==4?held_version:stabilization_version};
 // Conservative representable limits are explicit. Calibration/source IDs
 // identify supplied evidence; they are never asserted to be physical proof.
 always @*begin
  legal=0;active_version=0;
  case(kind)
   5:begin active_version=viewport_version;
    legal=SUPPORT_VIEWPORT && entity[7:0]<=2 && entity[31:8]==0 && entity[255:224]==0 &&
     entity[63:32]>=65536 && entity[95:64]>=entity[63:32] && entity[95:64]<=131072 &&
     entity[127:96]>0 && entity[127:96]<=4096 && entity[159:128]<=65536 &&
     entity[191:160]>0 && entity[191:160]<=65536 &&
     retained_area_product<=53'd281474976710656;end
   6:begin active_version=completion_version;
    legal=entity[7:0]<=1 && entity[15:8]!=0 && entity[63:48]==0 && entity[127:96]==0 &&
     entity[47:32]<=255 && (!entity[0] || entity[95:64]!=0);end
   8:begin active_version=pose_version;
    legal=entity[7:0]<=1 && entity[31:8]==0 && entity[1023:960]==0 &&
     (!entity[0] || (entity[63:32]!=0 && entity[351:320]!=0 && entity[383:352]!=0 &&
      entity[287:256]!=0 && entity[319:288]>0 && entity[319:288]<=1000 &&
      $signed(entity[128+:32])<=$signed(entity[160+:32]) &&
      $signed(entity[192+:32])<=$signed(entity[224+:32])));end
  endcase
  // Never queue removed features, even when another entity is pending.
  submit_code=(kind==4 || (kind==5 && (!SUPPORT_VIEWPORT || entity[7:0]==2)) || (kind==6 && entity[0]))?8'd6:!legal || version==0 || version[31] || entity_id==0 || entity_id[31] || version<=active_version ?8'd11:pending?8'd4:8'd0;
  status=0;status[15:0]=1;status[31:16]=read_kind;ri=0;
  case(read_kind)
   4:begin ri=0;status[63:32]=stabilization_version;status[111:96]=32;status[256+:256]=stabilization;end
   5:begin ri=1;status[63:32]=viewport_version;status[111:96]=32;status[256+:256]=viewport;end
   6:begin ri=2;status[63:32]=completion_version;status[111:96]=16;status[256+:128]=completion;end
   8:begin ri=3;status[63:32]=pose_version;status[111:96]=128;status[256+:1024]=pose;end
  endcase
  status[95:64]=ids[ri];status[112]=status[63:32]!=0;status[113]=pending && held_kind==read_kind;
  status[128+:64]=epochs[ri];status[192+:64]=frames[ri];
  // Kind 6 can retain a disabled entity; error 6 reports unavailable registration.
  if(read_kind==4 || read_kind==6)status[127:120]=8'd6;
  // Withdrawn capability has no live body/version/source identity. Direct
  // readers receive explicit UNSUPPORTED even if they bypass PC capability.
  if(!SUPPORT_VIEWPORT && read_kind==5)begin
   status=0;status[15:0]=1;status[31:16]=5;status[127:120]=8'd6;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   pending<=0;held_kind<=0;held<=0;held_version<=0;held_id<=0;applied_epoch<=0;applied_frame<=0;
   stabilization<=0;
   viewport<=UNITY_VIEWPORT;
   completion<=128'h00000000000000000000000000000100;pose<=0;
   stabilization_version<=0;viewport_version<=0;completion_version<=0;pose_version<=0;
   for(j=0;j<4;j=j+1)begin ids[j]<=0;epochs[j]<=0;frames[j]<=0;end
  end else begin
   if(submit_valid && submit_code==0)begin
    pending<=1;held_kind<=kind;held<={64'b0,entity[959:0]};held_version<=version;held_id<=entity_id;
   end
   if(capture_boundary && pending)begin
    pending<=0;applied_epoch<=epoch;applied_frame<=frame_id;
    // Each legal kind owns a fixed identity slot. Static writes avoid the
    // wide dynamic-index merge network while preserving atomic publication.
    for(j=1;j<4;j=j+1)if((SUPPORT_VIEWPORT || j!=1) && held_kind==(j==3?8:j+4))begin
     ids[j]<=held_id;epochs[j]<=epoch;frames[j]<=frame_id;
    end
    case(held_kind)
     5:if(SUPPORT_VIEWPORT)begin viewport<=queued_viewport;viewport_version<=held_version;end
     6:begin completion<=queued_completion;completion_version<=held_version;end
     8:begin pose<=queued_pose;pose_version<=held_version;end
    endcase
   end
  end
 end
endmodule

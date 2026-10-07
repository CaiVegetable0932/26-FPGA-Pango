// Purpose: session-scoped display intent. The processor consumes frame_original
// only after frame_prepare; controls do not alter an already processing frame.
// Applied fields describe a returned HDMI display snapshot, not requested work.
module geometry_view_control(input wire clk,rst_n,context_valid,
 input wire [63:0] epoch,input wire [31:0] session_id,
 input wire cmd_valid,input wire [7:0] cmd,input wire [255:0] payload,
 input wire frame_prepare,input wire [31:0] applied_revision,applied_packed,
 output reg [7:0] code,output wire [95:0] reply,
 output reg [31:0] frame_revision,frame_packed);
 reg [63:0] saved_epoch;reg [31:0] saved_session,requested_revision,requested_packed;
 wire context_match=context_valid && epoch==saved_epoch && session_id==saved_session;
 wire [31:0] revision=payload[127:96],flags=payload[159:128],size=payload[191:160];
 wire [31:0] packed_value=flags|(size<<8);
 assign reply={applied_packed,applied_revision,revision};
 always @* begin
  code=0;
  if(!context_valid)code=13;
  else if(revision==0 || flags[31:2]!=0 || size<4 || size>32)code=11;
  else if(context_match && revision<requested_revision)code=9;
  else if(context_match && revision==requested_revision)
   code=packed_value==requested_packed?1:10;
 end
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin saved_epoch<=0;saved_session<=0;requested_revision<=0;requested_packed<=2560;
  frame_revision<=0;frame_packed<=2560;end
 else begin
  if(!context_match)begin saved_epoch<=epoch;saved_session<=session_id;requested_revision<=0;requested_packed<=2560;end
  if(cmd_valid && cmd==8'h35 && code==0)begin
   saved_epoch<=epoch;saved_session<=session_id;requested_revision<=revision;requested_packed<=packed_value;
  end
  // Same-edge commands apply on the NEXT preparation, keeping this frame atomic.
  if(frame_prepare)begin frame_revision<=context_match?requested_revision:0;
   frame_packed<=context_match?requested_packed:32'd2560;end
 end
endmodule

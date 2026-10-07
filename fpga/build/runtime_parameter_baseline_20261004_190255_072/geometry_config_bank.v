// Purpose: session-scoped, readable K/D/affine shadow registers, hardware LUT
// generation and atomic processing-frame activation. Commands arrive only
// after UART CRC, length, epoch, session and response-queue checks.
module geometry_config_bank #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,rst_n,context_valid,input wire [63:0] epoch,
 input wire [31:0] session_id,
 input wire cmd_valid,input wire [7:0] cmd,input wire [255:0] payload,
 output reg [7:0] code,output reg [95:0] reply,
 input wire frame_start,input wire [63:0] source_frame_id,
 output reg [447:0] active_words,output reg [1:0] active_model,
 output reg active_enhance,active_bank,output reg [31:0] active_version,
 output reg [63:0] applied_frame_id,
 output wire build_busy,output reg build_failed,output reg pending,
 output reg build_start,output reg build_bank,
 output wire [1:0] build_model,output wire signed [31:0] k1,k2,k3,k4,
 input wire build_done,lut_failed
);
 reg [447:0] shadow_words,ready_words;
 reg [13:0] written;
 reg [31:0] shadow_version,ready_version;
 reg [1:0] shadow_model,ready_model;
 reg shadow_enhance,ready_enhance,ready_bank,shadow_valid,inflight;
 reg [63:0] shadow_epoch;reg [31:0] shadow_session;
 wire shadow_context=context_valid && shadow_epoch==epoch && shadow_session==session_id;
 wire [31:0] version=payload[127:96],index=payload[159:128];
 wire signed [31:0] value=payload[191:160];
 assign build_busy=inflight;
 assign build_model=shadow_model;
 assign k1=shadow_words[223:192],k2=shadow_words[255:224];
 assign k3=shadow_words[287:256],k4=shadow_words[319:288];
 // Purpose: reject unsafe fixed-point fields before calculating a table.
 // Full geometric validity also requires per-pixel bounds and LUT monotonicity.
 function magnitude_ok;
  input signed [31:0] v,limit;
  begin magnitude_ok=v>=-limit && v<=limit;end
 endfunction
 wire fields_ok=$signed(shadow_words[351:320])>0 && $signed(shadow_words[383:352])>0 &&
  $signed(shadow_words[351:320])<=32'sd268435456 && $signed(shadow_words[383:352])<=32'sd268435456 &&
  magnitude_ok(shadow_words[415:384],32'sd268435456) && magnitude_ok(shadow_words[447:416],32'sd268435456) &&
  magnitude_ok(k1,32'sd67108864) && magnitude_ok(k2,32'sd67108864) &&
  magnitude_ok(k3,32'sd67108864) && magnitude_ok(k4,32'sd67108864) &&
  magnitude_ok(shadow_words[31:0],32'sd268435456) && magnitude_ok(shadow_words[63:32],32'sd268435456) &&
  magnitude_ok(shadow_words[95:64],32'sd268435456) && magnitude_ok(shadow_words[127:96],32'sd268435456) &&
  magnitude_ok(shadow_words[159:128],32'sd268435456) && magnitude_ok(shadow_words[191:160],32'sd268435456);
 // Purpose: bounded 12-byte extension replies fit the existing 32-byte MCU
 // response. COMMIT acknowledges staging, never pretends parameters are active.
 always @* begin
  code=0;reply=0;
  reply[31:0]=active_version;reply[95:32]=applied_frame_id;
  case(cmd)
   8'h30:begin
    if(version==0 || payload[135:128]>2 || payload[143:137]!=0 ||
       payload[159:144]!=WIDTH || payload[175:160]!=HEIGHT || payload[191:176]!=0)code=11;
    else if(inflight || pending)code=13;
    else if(shadow_valid && shadow_context && version==shadow_version)begin
     code=(payload[129:128]==shadow_model && payload[136]==shadow_enhance)?1:10;
    end else if(version<=active_version)code=9;
   end
   8'h31:begin
    if(!shadow_valid || !shadow_context || version!=shadow_version)code=13;
    else if(inflight || pending)code=13;
    else if(index>=14)code=11;
    else if(written[index] && $signed(shadow_words[index*32+:32])==value)code=1;
    reply={shadow_version,value,index};
   end
   8'h32:begin
    if(version==active_version && version!=0)code=1;
    else if(!shadow_valid || !shadow_context || version!=shadow_version)code=13;
    else if(inflight || pending)code=1;
    else if(written!=14'h3fff || !fields_ok)code=11;
   end
   8'h33:begin end
   8'h34:begin
    // READ payload: prefix, index LE32, bank (0 shadow / 1 active) LE32.
    if(version>17 || index>1)code=11;
    else begin
     reply[31:0]=version;
     reply[95:64]=index==0?shadow_version:active_version;
     if(version<14)reply[63:32]=index==0?shadow_words[version*32+:32]:active_words[version*32+:32];
     else if(version==14)reply[63:32]={16'b0,10'b0,build_failed,pending,inflight,
       index==0?shadow_enhance:active_enhance,index==0?shadow_model:active_model};
     else if(version==15)reply[63:32]={16'b0,2'b0,written};
     else if(version==16)reply[63:32]=applied_frame_id[31:0];
     else reply[63:32]=applied_frame_id[63:32];
    end
   end
   default:code=6;
  endcase
 end
 // Purpose: only a complete, hardware-validated table may replace the active
 // bank. Existing processing continues on its immutable old bank meanwhile.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   shadow_words<=0;ready_words<=0;active_words<=0;written<=0;
   shadow_version<=0;ready_version<=0;active_version<=0;shadow_valid<=0;
   shadow_epoch<=0;shadow_session<=0;shadow_model<=0;ready_model<=0;active_model<=0;
   shadow_enhance<=1;ready_enhance<=1;active_enhance<=1;
   active_bank<=0;ready_bank<=0;build_bank<=0;build_start<=0;inflight<=0;
   pending<=0;build_failed<=0;applied_frame_id<=0;
  end else begin
   build_start<=0;
   if(shadow_valid && !shadow_context)begin shadow_valid<=0;pending<=0;written<=0;end
   if(build_done)begin
    inflight<=0;build_failed<=lut_failed;
    if(!lut_failed && shadow_valid && shadow_context)begin
     ready_words<=shadow_words;ready_version<=shadow_version;ready_model<=shadow_model;
     ready_enhance<=shadow_enhance;ready_bank<=build_bank;pending<=1;
    end
   end
   if(frame_start && pending && shadow_context)begin
    active_words<=ready_words;active_version<=ready_version;active_model<=ready_model;
    active_enhance<=ready_enhance;active_bank<=ready_bank;
    applied_frame_id<=source_frame_id;pending<=0;
   end
   if(cmd_valid && code==0)case(cmd)
    8'h30:begin
     shadow_valid<=1;shadow_epoch<=epoch;shadow_session<=session_id;
     shadow_version<=version;shadow_model<=payload[129:128];shadow_enhance<=payload[136];
     written<=0;shadow_words<=0;build_failed<=0;
    end
    8'h31:begin shadow_words[index*32+:32]<=value;written[index]<=1;end
    8'h32:begin
     inflight<=1;build_start<=1;build_bank<=!active_bank;build_failed<=0;
    end
   endcase
  end
endmodule

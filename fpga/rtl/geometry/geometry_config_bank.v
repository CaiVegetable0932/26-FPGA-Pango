// Purpose: session-scoped, readable K/D/affine shadow registers, hardware LUT
// generation and atomic processing-frame activation. Commands arrive only
// after UART CRC, length, epoch, session and response-queue checks.
module geometry_config_bank #(parameter WIDTH=1920,HEIGHT=1080,
 // Opt-in UART integration: READ address/bank must settle at least one rising
 // edge before command acceptance. Default preserves the combinational API.
 parameter PREDECODE_READ=0)(
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
 reg [447:0] shadow_storage,ready_words;
 wire [447:0] shadow_words;
 reg [13:0] written;
 // Distinct from written: context invalidation clears admission history but
 // historically leaves shadow readback intact. Only reset/BEGIN zero data.
 reg [13:0] shadow_present;
 // Purpose: cache per-word range validity on the exact shadow-word write.
 // COMMIT reduces fourteen bits instead of cascading fourteen wide signed
 // comparisons into command admission. Zero defaults are legal except fx/fy.
 reg [13:0] field_valid;
 reg [31:0] shadow_version,ready_version;
 reg [1:0] shadow_model,ready_model;
 reg shadow_enhance,ready_enhance,ready_bank,shadow_valid,inflight;
 reg [63:0] shadow_epoch;reg [31:0] shadow_session;
 wire shadow_context=context_valid && shadow_epoch==epoch && shadow_session==session_id;
 wire [31:0] version=payload[127:96],index=payload[159:128];
 wire signed [31:0] value=payload[191:160];
 // Purpose: parallel fixed-word decoding replaces the variable wide selector.
 // Preserve same-cycle replies, invalid-index rejection and command priority.
 wire [13:0] write_select,duplicate_word;
 // Purpose: isolate READ's wide data mux from the WORD write-select decoder.
 // UART payload is complete before both CRC bytes; only combined bank/address
 // one-hot selects are registered, NEVER data/version/status. Thus a frame
 // activation immediately before acceptance is visible without reply latency.
 wire [17:0] read_shadow_select,read_active_select;
 wire read_shadow_bank;
 genvar read_no;
 generate if(PREDECODE_READ)begin:g_read_predecode
  reg [17:0] shadow_select_q,active_select_q /* synthesis syn_preserve=1 */;
  reg shadow_bank_q /* synthesis syn_preserve=1 */;
  for(read_no=0;read_no<18;read_no=read_no+1)begin:g_select
   always @(posedge clk or negedge rst_n)
    if(!rst_n)begin shadow_select_q[read_no]<=0;active_select_q[read_no]<=0;end
    else begin
     shadow_select_q[read_no]<=version==read_no && index==0;
     active_select_q[read_no]<=version==read_no && index==1;
    end
  end
  always @(posedge clk or negedge rst_n)
   if(!rst_n)shadow_bank_q<=0;else shadow_bank_q<=index==0;
  assign read_shadow_select=shadow_select_q,read_active_select=active_select_q;
  assign read_shadow_bank=shadow_bank_q;
 end else begin:g_read_combinational
  for(read_no=0;read_no<18;read_no=read_no+1)begin:g_select
   assign read_shadow_select[read_no]=version==read_no && index==0;
   assign read_active_select[read_no]=version==read_no && index==1;
  end
  assign read_shadow_bank=index==0;
 end endgenerate
 wire [17:0] read_select=read_shadow_select | read_active_select;
 wire [31:0] read_tree[0:62];
 genvar word_no,tree_no;
 generate for(word_no=0;word_no<14;word_no=word_no+1)begin:g_decode
  // Purpose: BEGIN clears validity, not 448 physical data flops. Unwritten
  // words read as zero everywhere (READ, duplicate checks, LUT and snapshots),
  // preserving the original reset/BEGIN semantics without a wide clear CE.
  assign shadow_words[word_no*32+:32]=shadow_present[word_no] ?
      shadow_storage[word_no*32+:32] : 32'd0;
  assign write_select[word_no]=index==word_no;
  assign duplicate_word[word_no]=write_select[word_no] && written[word_no] &&
      shadow_words[word_no*32+:32]==value;
  assign read_tree[31+word_no]=
      ({32{read_shadow_select[word_no]}} & shadow_words[word_no*32+:32]) |
      ({32{read_active_select[word_no]}} & active_words[word_no*32+:32]);
 end
 // Status and identity use the same balanced READ tree and fresh live values.
 assign read_tree[45]=
     ({32{read_shadow_select[14]}} & {26'b0,build_failed,pending,inflight,shadow_enhance,shadow_model}) |
     ({32{read_active_select[14]}} & {26'b0,build_failed,pending,inflight,active_enhance,active_model});
 assign read_tree[46]={32{read_select[15]}} & {18'b0,written};
 assign read_tree[47]={32{read_select[16]}} & applied_frame_id[31:0];
 assign read_tree[48]={32{read_select[17]}} & applied_frame_id[63:32];
 for(word_no=18;word_no<32;word_no=word_no+1)begin:g_read_pad
  assign read_tree[31+word_no]=0;
 end
 for(tree_no=0;tree_no<31;tree_no=tree_no+1)begin:g_read_reduce
  assign read_tree[tree_no]=read_tree[2*tree_no+1] | read_tree[2*tree_no+2];
 end endgenerate
 integer write_word;
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
 wire fields_ok=&field_valid;
 // Purpose: WORD writes need context/range admission, not the duplicate-value
 // comparator on their CE. A duplicate rewrites exactly the same word/flags;
 // its visible code remains DUPLICATE. Invalid context/index still cannot write.
 wire word_write_ok=cmd_valid && cmd==8'h31 && shadow_valid && shadow_context &&
     version==shadow_version && !inflight && !pending && index<14;
 // Purpose: BEGIN's data-clear token must not traverse error-code encoding
 // and decode back to code==OK. This is the exact successful BEGIN predicate;
 // duplicate/conflicting versions retain their reply code and never clear data.
 wire begin_write_ok=cmd_valid && cmd==8'h30 && version!=0 &&
     payload[135:128]<=2 && payload[143:137]==0 && payload[159:144]==WIDTH &&
     payload[175:160]==HEIGHT && payload[191:176]==0 && !inflight && !pending &&
     !(shadow_valid && shadow_context && version==shadow_version) && version>active_version;
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
    else if(|duplicate_word)code=1;
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
    if(!(|read_select))code=11;
    else begin
     reply[31:0]=version;
     reply[95:64]=read_shadow_bank?shadow_version:active_version;
     reply[63:32]=read_tree[0];
    end
   end
   default:code=6;
  endcase
 end
 // Purpose: only a complete, hardware-validated table may replace the active
 // bank. Existing processing continues on its immutable old bank meanwhile.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   shadow_storage<=0;ready_words<=0;active_words<=0;written<=0;shadow_present<=0;field_valid<=14'h33ff;
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
   if(begin_write_ok)begin
     shadow_valid<=1;shadow_epoch<=epoch;shadow_session<=session_id;
     shadow_version<=version;shadow_model<=payload[129:128];shadow_enhance<=payload[136];
     written<=0;shadow_present<=0;field_valid<=14'h33ff;build_failed<=0;
   end
   // COMMIT remains gated by the complete validation result; it does not
   // fan out into every shadow word or per-word range-valid bit.
   if(cmd_valid && code==0 && cmd==8'h32)begin
     inflight<=1;build_start<=1;build_bank<=!active_bank;build_failed<=0;
   end
   // Per-word parallel enables preserve the original mutation edge and flags.
   if(word_write_ok)for(write_word=0;write_word<14;write_word=write_word+1)
    if(write_select[write_word])begin
     shadow_storage[write_word*32+:32]<=value;written[write_word]<=1;shadow_present[write_word]<=1;
     if(write_word==10 || write_word==11)
      field_valid[write_word]<=value>0 && value<=32'sd268435456;
     else field_valid[write_word]<=magnitude_ok(value,
         (write_word>=6 && write_word<=9)?32'sd67108864:32'sd268435456);
    end
  end
endmodule

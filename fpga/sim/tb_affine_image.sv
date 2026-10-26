`timescale 1ns/1ps
// Purpose: OFF -> ON translated -> OFF -> pre-tone reference pixels through
// the actual affine selector, geometry/cache/interpolator and verified DDR writes.
// Real geometry/cache/refill/result writer and shared native DMA run together.
module tb_affine_image;
 localparam W=35,H=33,N=2,DST=32'h01800000;
 reg clk=0,rst_n=0,job_valid=0;always #4 clk=~clk;
 reg [447:0] coefficients=0;reg [1:0] enhancement=0;
 reg toggle_valid=0,boundary=0;reg [15:0] seq=0;reg [95:0] payload=0;
 reg [447:0] on_coefficients=0,job_coefficients=0;
 wire [447:0] selected;wire [7:0] toggle_code;
 affine_frame_control selection(.clk(clk),.rst_n(rst_n),.submit_valid(toggle_valid),
  .submit_sequence(seq),.submit_payload(payload),.submit_code(toggle_code),
  .other_pending(1'b0),.geometry_version(32'd7),.capture_geometry(on_coefficients),
  .reference_coefficients(coefficients[191:0]),.capture_boundary(boundary),
  .capture_epoch(64'd99),.capture_frame(64'd1),.capture_coefficients(selected),
  .capture_enable(),.capture_control_version(),.pending(),.applied_enable(),.requested_enable(),
  .control_version(),.requested_version(),.applied_epoch(),.applied_frame(),.applied_coefficients());
 always @(posedge clk)if(boundary)job_coefficients<=selected;
 reg lut_write=0,lut_commit=0;reg [7:0] lut_addr=0,lut_data=0;
 wire job_ready,job_done,job_failed;wire [615:0] result_metadata;
 wire [1:0] req_valid,req_ready,cancel,w_valid,w_ready,r_valid,r_ready,r_last,done,done_ready,error,cancelled;
 wire [63:0] req_addr,req_tag,done_tag;wire [9:0] req_beats;
 wire [511:0] w_data,r_data;wire [63:0] w_strb;
 geometry_frame_processor processor(.clk(clk),.rst_n(rst_n),.job_valid(job_valid),.job_ready(job_ready),
  .source_base(32'd0),.source_generation(32'd17),.result_base(DST),.result_generation(32'd19),
  .width(16'(W)),.height(16'(H)),.coefficients(job_coefficients),.metadata(616'h8000000000000007),
  .enhancement(enhancement),.lut_version(32'd1),.lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),.lut_commit(lut_commit),
  .job_done(job_done),.job_failed(job_failed),.result_metadata(result_metadata),
  .source_req_valid(req_valid[0]),.source_req_ready(req_ready[0]),.source_req_addr(req_addr[31:0]),.source_req_tag(req_tag[31:0]),
  .source_req_beats(req_beats[4:0]),.source_cancel(cancel[0]),.source_r_valid(r_valid[0]),.source_r_ready(r_ready[0]),
  .source_r_data(r_data[255:0]),.source_r_last(r_last[0]),.source_done(done[0]),.source_done_ready(done_ready[0]),
  .source_error(error[0]),.source_cancelled(cancelled[0]),.source_done_tag(done_tag[31:0]),
  .result_req_valid(req_valid[1]),.result_req_ready(req_ready[1]),.result_req_addr(req_addr[63:32]),.result_req_tag(req_tag[63:32]),
  .result_req_beats(req_beats[9:5]),.result_cancel(cancel[1]),.result_w_valid(w_valid[1]),.result_w_ready(w_ready[1]),
  .result_w_data(w_data[511:256]),.result_w_strb(w_strb[63:32]),.result_done(done[1]),.result_done_ready(done_ready[1]),
  .result_error(error[1]),.result_cancelled(cancelled[1]),.result_done_tag(done_tag[63:32]));
 assign w_valid[0]=0,w_data[255:0]=0,w_strb[31:0]=0,r_ready[1]=1;
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen;wire awvalid,arvalid,fault;
 reg awready=0,arready=0,native_wready=0,native_wlast=0,native_rvalid=0,native_rlast=0;
 wire [255:0] native_wdata;wire [31:0] native_wstrb;reg [255:0] native_rdata=0;
 ddr_native_dma #(.CLIENTS(2),.VERIFY_WRITES(1)) dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(2'b10),.req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),
  .w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_strb(w_strb),.cancel(cancel),.urgent(2'b00),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.done(done),.done_ready(done_ready),
  .error(error),.cancelled(cancelled),.done_tag(done_tag),.fault(fault),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
  .native_wdata(native_wdata),.native_wstrb(native_wstrb),.native_wready(native_wready),.native_wlast(native_wlast),.native_wid(4'b0),
  .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),.native_rdata(native_rdata),
  .native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rid(4'b0));
 byte result_mem[0:262143];integer cycle=0,wa=0,ra=0,wl=0,rl=0,wi=0,ri=0,checks=0,fd;
 function [23:0] pixel(input integer x,y);
  begin pixel={8'(x*17+y*3),8'(x*5+y*11),8'(x*29+y*7)};end
 endfunction
 function [7:0] memory_byte(input integer a);
  integer x,y,c;reg [23:0] value;
  begin
   if(a>=DST)memory_byte=result_mem[a-DST];
   else begin y=a/6144;x=(a%6144)/3;c=(a%6144)%3;value=pixel(x,y);
    if(x>=W || y>=H)memory_byte=8'hde;
    else case(c)0:memory_byte=value[23:16];1:memory_byte=value[15:8];2:memory_byte=value[7:0];endcase
   end
  end
 endfunction
 always @(negedge clk)begin
  awready=rst_n && wl==0 && cycle%7!=0;arready=rst_n && rl==0 && cycle%5!=0;
  native_wready=rst_n && wl>0 && cycle%3!=0;native_wlast=wl==1;
  native_rvalid=rst_n && rl>0 && cycle%4!=0;native_rlast=rl==1;
  for(integer b=0;b<32;b++)native_rdata[b*8+:8]=memory_byte(ra+ri*32+b);
 end
 always @(posedge clk)begin
  cycle++;
  if(!rst_n)begin wl=0;rl=0;wi=0;ri=0;end
  else begin
   if(native_wready)begin
    for(integer b=0;b<32;b++)if(native_wstrb[b])result_mem[wa-DST+wi*32+b]=native_wdata[b*8+:8];
    wi++;wl--;
   end
   if(native_rvalid)begin ri++;rl--;end
   if(awvalid && awready)begin wa=awaddr*4;wl=awlen+1;wi=0;end
   if(arvalid && arready)begin ra=araddr*4;rl=arlen+1;ri=0;end
  end
 end
 initial begin
  coefficients[0+:32]=2097152;coefficients[64+:32]=-(W/2)*2097152;
  coefficients[128+:32]=2097152;coefficients[160+:32]=-(H/2)*2097152;
  coefficients[320+:32]=32*65536;coefficients[352+:32]=32*65536;
  coefficients[384+:32]=(W/2)*65536;coefficients[416+:32]=(H/2)*65536;
  // ON translates the inverse sample position right by one source pixel.
  // An asymmetric RGB ramp distinguishes direction and catches PC-only toggles.
  on_coefficients=coefficients;on_coefficients[64+:32]=coefficients[64+:32]+2097152;
  repeat(4)@(negedge clk);rst_n=1;
  for(integer a=0;a<256;a++)begin @(negedge clk);lut_write=1;lut_addr=a;lut_data=255-a;end
  @(negedge clk);lut_write=0;lut_commit=1;@(negedge clk);lut_commit=0;
  for(integer f=0;f<4;f++)begin
   if(f==1 || f==2)begin
    @(negedge clk);seq=f;payload={32'd7,32'(f),31'd0,(f==1)};#1;
    if(toggle_code!=0)$fatal(1,"AFFINE_IMAGE switch rejected");toggle_valid=1;
    @(negedge clk);toggle_valid=0;
   end
   @(negedge clk);boundary=1;@(negedge clk);boundary=0;
   enhancement=f==3?1:0;for(integer a=0;a<262144;a++)result_mem[a]=8'h5a;
   wait(job_ready);@(negedge clk);job_valid=1;@(negedge clk);job_valid=0;
   wait(job_done);@(negedge clk);
   if(job_failed || fault || wl!=0 || rl!=0 || result_metadata!=616'h8000000000000007)$fatal(1,"PROCESSOR_FAIL metadata/failed/drain");
   for(integer y=0;y<H;y++)for(integer x=0;x<6144;x++)begin
    reg [23:0] value;reg [7:0] expected;value=pixel(x/3+(f==1?1:0),y);if(f==3)value=~value;
    if(f==1 && x/3==W-1)value=0;
    if(x>=W*3)expected=8'h5a;
    else case(x%3)0:expected=value[23:16];1:expected=value[15:8];2:expected=value[7:0];endcase
    if(result_mem[y*6144+x]!==expected)$fatal(1,"PROCESSOR_FAIL frame=%0d x/y=%0d/%0d",f,x,y);
    checks++;
   end
  end
  $display("TB_AFFINE_IMAGE_PASS frames=4 verified_result_bytes=%0d cycles=%0d",checks,cycle);$finish;
 end
 initial begin #20000000;$fatal(1,"AFFINE_IMAGE_TIMEOUT");end
endmodule

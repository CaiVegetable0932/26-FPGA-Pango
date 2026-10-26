`timescale 1ns/1ps
// Purpose: S1 memory -> complete processing job -> verified DST memory.
// Real geometry/cache/refill/result writer and native DMA run on two clocks.
// The job and final pixel counters cross only through mailbox snapshots.
module tb_geometry_processing_snapshot;
 // Fault mode runs a small five-frame sequence, while the default preserves
 // the original 35x33 multi-tile byte oracle unchanged.
 parameter W=35,H=33,FAULT_SEQUENCE=0,EXTERNAL_PAGES=0;
 localparam N=2,DST=32'h01800000;
 reg inject_cancel=0;
 parameter real PROC_HALF=3.333,PROC_PHASE=0.7;
 reg pclk=0,prst_n=0;
 initial begin #PROC_PHASE;forever #PROC_HALF pclk=~pclk;end
 reg clk=0,rst_n=0,job_valid=0;always #4 clk=~clk;
 wire [31:0] current_pixels,history_pixels,invalid_pixels;
 reg [447:0] coefficients=0;reg [1:0] enhancement=0;
 reg lut_write=0,lut_commit=0;reg [7:0] lut_addr=0,lut_data=0;
 wire job_ready,job_done,job_failed;wire [615:0] result_metadata;
 wire [1:0] req_valid,req_ready,cancel,w_valid,w_ready,r_valid,r_ready,r_last,done,done_ready,error,cancelled;
 wire [63:0] req_addr,req_tag,done_tag;wire [9:0] req_beats;
 wire [511:0] w_data,r_data;wire [63:0] w_strb;
 geometry_processing_domain_external_refill #(.EXTERNAL_TONE_PAGES(EXTERNAL_PAGES)) processor(.clk(clk),.rst_n(rst_n),.processing_clk(pclk),.processing_rst_n(prst_n),.job_valid(job_valid),.job_ready(job_ready),
  .source_base(32'd0),.source_generation(32'd17),.result_base(DST),.result_generation(32'd19),
  .width(16'(W)),.height(16'(H)),.coefficients(coefficients),.metadata(616'h8000000000000007),
  .enhancement(enhancement),.lut_version(32'd1),.lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),.lut_commit(lut_commit),
  .history_enable(1'b0),.history_base(32'b0),.history_generation(32'b0),
  .history_dx_q16(32'b0),.history_dy_q16(32'b0),.source_history(),
  .current_pixels(current_pixels),.history_pixels(history_pixels),.invalid_pixels(invalid_pixels),
  .lut_page(1'b0),.lut_program_version(32'd1),
  .job_done(job_done),.job_failed(job_failed),.result_metadata(result_metadata),
  .source_req_valid(req_valid[0]),.source_req_ready(req_ready[0]),.source_req_addr(req_addr[31:0]),.source_req_tag(req_tag[31:0]),
  .source_req_beats(req_beats[4:0]),.source_cancel(cancel[0]),.source_r_valid(r_valid[0]),.source_r_ready(r_ready[0]),
  .source_r_data(r_data[255:0]),.source_r_last(r_last[0]),.source_done(done[0]),.source_done_ready(done_ready[0]),
  .source_error(error[0]),.source_cancelled(cancelled[0]),.source_done_tag(done_tag[31:0]),
  .result_req_valid(req_valid[1]),.result_req_ready(req_ready[1]),.result_req_addr(req_addr[63:32]),.result_req_tag(req_tag[63:32]),
  .result_req_beats(req_beats[9:5]),.result_cancel(cancel[1]),.result_w_valid(w_valid[1]),.result_w_ready(w_ready[1]),
  .result_w_data(w_data[511:256]),.result_w_strb(w_strb[63:32]),.result_done(done[1]),.result_done_ready(done_ready[1]),
  .result_error(error[1]),.result_cancelled(cancelled[1] || inject_cancel),.result_done_tag(done_tag[63:32]));
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
  // Preserve raw RGB evidence from the actual synthetic source and observed
  // result memory. Derived pictures must never replace these byte records.
  fd=$fopen("s1_source.rgb","wb");
  for(integer y=0;y<H;y++)for(integer x=0;x<W;x++)begin
   reg [23:0] source;source=pixel(x,y);$fwrite(fd,"%c%c%c",source[23:16],source[15:8],source[7:0]);
  end
  $fclose(fd);
  repeat(4)@(negedge clk);rst_n=1;@(negedge pclk);prst_n=1;
  for(integer a=0;a<256;a++)begin @(negedge pclk);lut_write=1;lut_addr=a;lut_data=255-a;end
  @(negedge pclk);lut_write=0;lut_commit=1;@(negedge pclk);lut_commit=0;
  for(integer f=0;f<(FAULT_SEQUENCE?5:2);f++)begin
   // Frames 2/3 map every pixel out of bounds. Frame 3 injects a drained
   // cancelled DMA response, and frame 4 proves recovery with a fresh count.
   inject_cancel=FAULT_SEQUENCE && f==3;
   coefficients[64+:32]=(FAULT_SEQUENCE && (f==2 || f==3)) ? (W*2-W/2)*2097152 : -(W/2)*2097152;
   enhancement=f==1;for(integer a=0;a<262144;a++)result_mem[a]=8'h5a;
   wait(job_ready);@(negedge clk);job_valid=1;@(negedge clk);job_valid=0;
   wait(job_done);@(negedge clk);
   if(job_failed!==inject_cancel || fault || wl!=0 || rl!=0 || result_metadata!=616'h8000000000000007)$fatal(1,"PROCESSOR_FAIL metadata/failed/drain");
   // Completion must carry the final same-frame counts, already captured in
   // DDR. This catches a stale first/last pixel or a swapped return field.
   if(current_pixels!==((FAULT_SEQUENCE && (f==2 || f==3))?0:W*H) || history_pixels!==0 ||
      invalid_pixels!==((FAULT_SEQUENCE && (f==2 || f==3))?W*H:0))
    $fatal(1,"Completion counters current=%0d history=%0d invalid=%0d",current_pixels,history_pixels,invalid_pixels);
   fd=$fopen($sformatf("result_mode_%0d.rgb",f),"wb");
   for(integer y=0;y<H;y++)for(integer x=0;x<W*3;x++)$fwrite(fd,"%c",result_mem[y*6144+x]);
   $fclose(fd);
   for(integer y=0;y<H;y++)for(integer x=0;x<6144;x++)begin
    reg [23:0] value;reg [7:0] expected;value=pixel(x/3,y);if(f==1)value=~value;
    if(FAULT_SEQUENCE && f==2)value=0;
    if(x>=W*3)expected=8'h5a;
    else case(x%3)0:expected=value[23:16];1:expected=value[15:8];2:expected=value[7:0];endcase
    // A cancelled writer may publish only part of its frame. Its drain,
    // failed status, final geometry counters and next-frame recovery remain
    // checked; successful frames and every row guard retain byte comparison.
    if(!(FAULT_SEQUENCE && f==3 && x<W*3) && result_mem[y*6144+x]!==expected)$fatal(1,"PROCESSOR_FAIL frame=%0d x/y=%0d/%0d",f,x,y);
    checks++;
   end
  end
  $display("GEOMETRY_PROCESSING_SNAPSHOT_PASS frames=%0d verified_result_bytes=%0d cycles=%0d",FAULT_SEQUENCE?5:2,checks,cycle);$finish;
 end
 initial begin #20000000;$fatal(1,"PROCESSOR_TIMEOUT");end
endmodule

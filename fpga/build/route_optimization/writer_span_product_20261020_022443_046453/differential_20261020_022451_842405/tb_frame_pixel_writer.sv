`timescale 1ns/1ps
// Purpose: actual coordinate-addressed writer + full-readback native DMA.
// Independent byte memory verifies raster RAW/RGB and 32x8 tile output order,
// row padding, partial segments and physical 4KiB splits under backpressure.
module tb_frame_pixel_writer #(parameter W=35,H=9,TILED=1);
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg frame_valid=0,frame_rgb888=1,frame_abort=0,in_valid=0;
 reg [31:0] frame_base=0,frame_stride=6144,frame_generation=7;
 reg [15:0] frame_width=W,frame_height=H,in_x=0,in_y=0;
 reg [23:0] in_pixel=0;
 wire frame_ready,in_ready,frame_done,frame_failed;
 wire [31:0] accepted_pixels,req_addr,req_tag,done_tag;wire [4:0] req_beats;
 wire req_valid,req_ready,req_write,w_valid,w_ready,dma_cancel,done,done_ready,dma_error,dma_cancelled;
 wire [255:0] w_data;wire [31:0] w_strb;
 frame_pixel_writer #(.TILED(TILED)) writer(.*);
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen;wire awvalid,arvalid;
 reg awready=0,arready=0,native_wready=0,native_wlast=0,native_rvalid=0,native_rlast=0;
 wire [255:0] native_wdata;wire [31:0] native_wstrb;reg [255:0] native_rdata=0;
 wire fault;
 ddr_native_dma #(.CLIENTS(1),.VERIFY_WRITES(1)) dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),.allow_snapshot(1'b1),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),
  .w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_strb(w_strb),.cancel(dma_cancel),.urgent(1'b0),.r_ready(1'b1),
  .done(done),.done_ready(done_ready),.error(dma_error),.cancelled(dma_cancelled),.done_tag(done_tag),.fault(fault),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
  .native_wdata(native_wdata),.native_wstrb(native_wstrb),.native_wready(native_wready),.native_wlast(native_wlast),.native_wid(4'b0),
  .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),.native_rdata(native_rdata),
  .native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rid(4'b0));
 byte mem[0:262143];integer cycle=0,wa=0,ra=0,wl=0,rl=0,wi=0,ri=0,checks=0;
 function [23:0] pixel(input integer x,y);
  begin pixel={8'(x*17+y*3+1),8'(x*5+y*11+2),8'(x*29+y*7+3)};end
 endfunction
 always @(negedge clk)begin
  awready=rst_n && wl==0 && cycle%7!=0;arready=rst_n && rl==0 && cycle%5!=0;
  native_wready=rst_n && wl>0 && cycle%3!=0;native_wlast=wl==1;
  native_rvalid=rst_n && rl>0 && cycle%4!=0;native_rlast=rl==1;
  for(integer b=0;b<32;b++)native_rdata[b*8+:8]=mem[ra+ri*32+b];
 end
 always @(posedge clk)begin
  cycle++;
  if(!rst_n)begin wl=0;rl=0;wi=0;ri=0;end
  else begin
   if(native_wready)begin
    for(integer b=0;b<32;b++)if(native_wstrb[b])mem[wa+wi*32+b]=native_wdata[b*8+:8];
    wi++;wl--;
   end
   if(native_rvalid)begin ri++;rl--;end
   if(awvalid && awready)begin
    wa=awaddr*4;wl=awlen+1;wi=0;
    if(wa%4096+wl*32>4096)$fatal(1,"WRITER_FAIL physical column crossing");
   end
   if(arvalid && arready)begin ra=araddr*4;rl=arlen+1;ri=0;end
  end
 end
 task send_pixel(input integer x,y);
  begin @(negedge clk);in_x=x;in_y=y;in_pixel=pixel(x,y);in_valid=1;
   #1;while(!in_ready)begin @(negedge clk);#1;end
   @(posedge clk);@(negedge clk);in_valid=0;
  end
 endtask
 task test_frame(input logic rgb,input integer base,input integer stride);
  begin
   for(integer a=0;a<262144;a++)mem[a]=8'h5a;
   frame_rgb888=rgb;frame_base=base;frame_stride=stride;
   @(negedge clk);frame_valid=1;@(negedge clk);frame_valid=0;
   if(TILED)begin
    for(integer ty=0;ty<H;ty+=8)for(integer tx=0;tx<W;tx+=32)
     for(integer y=ty;y<ty+8 && y<H;y++)for(integer x=tx;x<tx+32 && x<W;x++)send_pixel(x,y);
   end else begin
    for(integer y=0;y<H;y++)for(integer x=0;x<W;x++)send_pixel(x,y);
   end
   wait(frame_done);@(negedge clk);
   if(frame_failed || fault || accepted_pixels!=W*H || wl!=0 || rl!=0)$fatal(1,"WRITER_FAIL incomplete/drain");
   for(integer y=0;y<H;y++)for(integer x=0;x<stride;x++)begin
    reg [23:0] expected;reg [7:0] b;expected=pixel(rgb?x/3:x,y);
    if(x>=W*(rgb?3:1))b=8'h5a;
    else if(!rgb)b=expected[7:0];
    else case(x%3)0:b=expected[23:16];1:b=expected[15:8];2:b=expected[7:0];endcase
    if(mem[base+y*stride+x]!==b)$fatal(1,"WRITER_FAIL rgb=%0d x/y=%0d/%0d got=%h expected=%h",rgb,x,y,mem[base+y*stride+x],b);
    checks++;
   end
  end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
  test_frame(1,0,6144);test_frame(0,0,2048);
  // Force an RGB tile segment to cross a physical column at byte 4096.
  test_frame(1,4032,6144);
  $display("FRAME_PIXEL_WRITER_PASS frames=3 checked_bytes=%0d",checks);$finish;
 end
 initial begin #10000000;$fatal(1,"WRITER_TIMEOUT");end
 wire  baseline_frame_ready;
 wire  baseline_in_ready;
 wire  baseline_frame_done;
 wire  baseline_frame_failed;
 wire  baseline_req_valid;
 wire  baseline_req_write;
 wire  baseline_w_valid;
 wire  baseline_dma_cancel;
 wire  baseline_done_ready;
 wire [31:0] baseline_accepted_pixels;
 wire [31:0] baseline_req_addr;
 wire [31:0] baseline_req_tag;
 wire [31:0] baseline_w_strb;
 wire [4:0] baseline_req_beats;
 wire [255:0] baseline_w_data;
 frame_pixel_writer_baseline #(.TILED(TILED)) baseline(.frame_ready(baseline_frame_ready),.in_ready(baseline_in_ready),.frame_done(baseline_frame_done),.frame_failed(baseline_frame_failed),.req_valid(baseline_req_valid),.req_write(baseline_req_write),.w_valid(baseline_w_valid),.dma_cancel(baseline_dma_cancel),.done_ready(baseline_done_ready),.accepted_pixels(baseline_accepted_pixels),.req_addr(baseline_req_addr),.req_tag(baseline_req_tag),.w_strb(baseline_w_strb),.req_beats(baseline_req_beats),.w_data(baseline_w_data),.clk(clk),.rst_n(rst_n),.frame_valid(frame_valid),.frame_base(frame_base),.frame_stride(frame_stride),.frame_generation(frame_generation),.frame_width(frame_width),.frame_height(frame_height),.frame_rgb888(frame_rgb888),.frame_abort(frame_abort),.in_valid(in_valid),.in_pixel(in_pixel),.in_x(in_x),.in_y(in_y),.req_ready(req_ready),.w_ready(w_ready),.done(done),.dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag));
 always @(negedge clk)begin #2;
  if(rst_n)begin
   if({frame_ready,in_ready,frame_done,frame_failed,accepted_pixels,req_valid,w_valid,dma_cancel,done_ready} !==
      {baseline_frame_ready,baseline_in_ready,baseline_frame_done,baseline_frame_failed,baseline_accepted_pixels,baseline_req_valid,baseline_w_valid,baseline_dma_cancel,baseline_done_ready})$fatal(1,"WRITER_DIFFERENTIAL control/latency");
   if(req_valid && {req_addr,req_tag,req_beats,req_write} !== {baseline_req_addr,baseline_req_tag,baseline_req_beats,baseline_req_write})$fatal(1,"WRITER_DIFFERENTIAL request");
   if(w_valid && {w_data,w_strb} !== {baseline_w_data,baseline_w_strb})$fatal(1,"WRITER_DIFFERENTIAL data");
  end
 end
endmodule

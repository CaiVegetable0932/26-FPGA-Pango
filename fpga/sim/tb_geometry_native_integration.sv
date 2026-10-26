`timescale 1ns/1ps
// Purpose: end-to-end S1 DDR reads -> real refill -> inverse map/cache/bilinear/
// enhancement pixels. Every partial-frame position is checked exactly once.
// The native memory contents are synthetic; no board throughput is inferred.
module tb_geometry_native_integration;
 localparam W=35,H=33;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg frame_valid=0,out_ready=0,lut_write=0,lut_commit=0;
 reg [7:0] lut_addr=0,lut_data=0;reg [1:0] mode=0;
 reg [447:0] coeff=0;
 wire frame_ready,out_valid,out_mask,frame_done,frame_failed,config_rejected;
 wire [23:0] out_rgb;wire [15:0] out_u,out_v;wire [63:0] out_tag;
 wire fill_req_valid,fill_req_ready,fill_valid,fill_ready,fill_last,fill_error;
 wire [11:0] fill_tile_x,fill_tile_y;wire [95:0] fill_rgb;wire [31:0] fill_bus_bytes;
 wire req_valid,req_ready,req_write,dma_cancel,r_valid,r_ready,r_last,done,done_ready,dma_error,dma_cancelled;
 wire [31:0] req_addr,req_tag,done_tag;wire [4:0] req_beats;wire [255:0] r_data;
 geometry_rgb_pipeline #(.FRAME_TAG_BITS(64),.SET_BITS(3)) geometry(
  .clk(clk),.rst_n(rst_n),.frame_valid(frame_valid),.frame_ready(frame_ready),.frame_width(16'(W)),.frame_height(16'(H)),
  .frame_coefficients(coeff),.frame_tag(64'h8000000000000007),.frame_enhancement(mode),.frame_lut_version(32'd1),
  .lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),.lut_commit(lut_commit),.lut_version(32'd1),
  .out_valid(out_valid),.out_ready(out_ready),.out_rgb(out_rgb),.out_mask(out_mask),.out_u(out_u),.out_v(out_v),.out_frame_tag(out_tag),
  .fill_req_valid(fill_req_valid),.fill_req_ready(fill_req_ready),.fill_tile_x(fill_tile_x),.fill_tile_y(fill_tile_y),
  .fill_valid(fill_valid),.fill_ready(fill_ready),.fill_rgb(fill_rgb),.fill_last(fill_last),.fill_error(fill_error),.fill_bus_bytes(fill_bus_bytes),
  .frame_done(frame_done),.frame_failed(frame_failed),.config_rejected(config_rejected));
 geometry_tile_refill refill(.clk(clk),.rst_n(rst_n),.fill_req_valid(fill_req_valid),.fill_req_ready(fill_req_ready),
  .fill_tile_x(fill_tile_x),.fill_tile_y(fill_tile_y),.source_base(32'd0),.source_stride(32'd6144),.source_generation(32'd19),
  .source_width(16'(W)),.source_height(16'(H)),.fill_valid(fill_valid),.fill_ready(fill_ready),.fill_rgb(fill_rgb),
  .fill_last(fill_last),.fill_error(fill_error),.fill_bus_bytes(fill_bus_bytes),.cancel(1'b0),
  .req_valid(req_valid),.req_ready(req_ready),.req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),.req_write(req_write),
  .dma_cancel(dma_cancel),.r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),
  .done(done),.done_ready(done_ready),.dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag));
 wire [27:0] araddr;wire [3:0] arlen;wire arvalid;
 reg arready=0,native_rvalid=0,native_rlast=0;reg [255:0] native_rdata=0;
 ddr_native_dma #(.CLIENTS(1)) dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),
  .cancel(dma_cancel),.urgent(1'b0),.w_valid(1'b0),.w_data(256'b0),.w_strb(32'b0),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.done(done),.done_ready(done_ready),
  .error(dma_error),.cancelled(dma_cancelled),.done_tag(done_tag),
  .awready(1'b0),.native_wready(1'b0),.native_wid(4'b0),.native_wlast(1'b0),
  .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
  .native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rdata(native_rdata),.native_rid(4'b0));
 integer cycle=0,left=0,index=0,address=0,received=0,checks=0;
 reg seen[0:W*H-1];
 function [23:0] pixel(input integer x,y);
  begin pixel={8'(x*17+y*3),8'(x*5+y*11),8'(x*29+y*7)};end
 endfunction
 function [7:0] memory_byte(input integer a);
  integer y,x,c;reg [23:0] value;
  begin y=a/6144;x=(a%6144)/3;c=(a%6144)%3;value=pixel(x,y);
   if(x>=W || y>=H)memory_byte=8'hde;
   else case(c)0:memory_byte=value[23:16];1:memory_byte=value[15:8];2:memory_byte=value[7:0];endcase
  end
 endfunction
 always @(negedge clk)begin
  arready=rst_n && left==0 && cycle%9>2;
  native_rvalid=rst_n && left>0 && cycle%4!=0;native_rlast=left==1;
  for(integer b=0;b<32;b++)native_rdata[b*8+:8]=memory_byte(address+index*32+b);
  out_ready=cycle%7!=0;
 end
 always @(posedge clk)if(rst_n)begin
  cycle++;
  if(native_rvalid)begin left--;index++;end
  if(arvalid && arready)begin address=araddr*4;left=arlen+1;index=0;end
  if(out_valid && out_ready)begin
   reg [23:0] expected;expected=pixel(out_u,out_v);if(mode!=0)expected=~expected;
   if(out_u>=W || out_v>=H || seen[out_v*W+out_u] || out_rgb!==expected ||
      !out_mask || out_tag!==64'h8000000000000007)$fatal(1,"GEOMETRY_NATIVE_FAIL pixel=%0d u/v=%0d/%0d rgb=%h expected=%h",received,out_u,out_v,out_rgb,expected);
   seen[out_v*W+out_u]=1;received++;checks++;
  end
 end
 initial begin
  // Exact identity inverse map (focal=32), so the independent source formula
  // is also the exact resampling golden, including every right/bottom edge.
  coeff[0+:32]=2097152;coeff[64+:32]=-(W/2)*2097152;
  coeff[128+:32]=2097152;coeff[160+:32]=-(H/2)*2097152;
  coeff[320+:32]=32*65536;coeff[352+:32]=32*65536;
  coeff[384+:32]=(W/2)*65536;coeff[416+:32]=(H/2)*65536;
  repeat(4)@(negedge clk);rst_n=1;
  for(integer a=0;a<256;a++)begin @(negedge clk);lut_write=1;lut_addr=a;lut_data=255-a;end
  @(negedge clk);lut_write=0;lut_commit=1;@(negedge clk);lut_commit=0;
  for(integer frame_no=0;frame_no<3;frame_no++)begin
   mode=frame_no;received=0;for(integer s=0;s<W*H;s++)seen[s]=0;
   wait(frame_ready);@(negedge clk);frame_valid=1;@(negedge clk);frame_valid=0;
   wait(frame_done);@(negedge clk);
   if(received!=W*H || frame_failed || config_rejected || left!=0)$fatal(1,"GEOMETRY_NATIVE_FAIL incomplete/drain");
  end
  $display("GEOMETRY_NATIVE_INTEGRATION_PASS frames=3 checked_pixels=%0d cycles=%0d",checks,cycle);$finish;
 end
 initial begin #10000000;$fatal(1,"GEOMETRY_NATIVE_TIMEOUT");end
endmodule

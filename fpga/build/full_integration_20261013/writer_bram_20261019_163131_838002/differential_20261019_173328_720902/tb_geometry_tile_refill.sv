`timescale 1ns/1ps
// Purpose: exercise the actual refill + native DMA together. Independent RGB
// formula checks quad ordering, RGB byte order, source stride, physical address,
// partial edges and 4KiB splits. Source memory is synthetic, not a camera image.
module tb_geometry_tile_refill #(parameter EDGE_WIDTH=1919);
 reg clk=0,rst_n=0;always #5 clk=~clk;
 reg fill_req_valid=0,fill_ready=0,cancel=0;
 wire fill_req_ready,fill_valid,fill_last,fill_error,busy;
 reg [11:0] fill_tile_x=0,fill_tile_y=0;
 reg [31:0] source_base=0,source_stride=6144,source_generation=17;
 reg [15:0] source_width=1920,source_height=1080;
 wire [95:0] fill_rgb;wire [31:0] fill_bus_bytes;
 wire req_valid,req_ready,req_write,dma_cancel,r_valid,r_ready,r_last,done,done_ready,dma_error,dma_cancelled;
 wire [31:0] req_addr,req_tag,done_tag;wire [4:0] req_beats;wire [255:0] r_data;
 geometry_tile_refill dut(.*);
 wire [27:0] araddr;wire [3:0] arlen;wire arvalid;
 reg arready=0,native_rvalid=0,native_rlast=0;reg [255:0] native_rdata=0;
 ddr_native_dma #(.CLIENTS(1)) dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),.allow_snapshot(1'b1),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_tag(req_tag),
  .req_beats(req_beats),.cancel(dma_cancel),.urgent(1'b0),.w_valid(1'b0),.w_data(256'b0),.w_strb(32'b0),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.done(done),.done_ready(done_ready),
  .error(dma_error),.cancelled(dma_cancelled),.done_tag(done_tag),
  .awready(1'b0),.native_wready(1'b0),.native_wid(4'b0),.native_wlast(1'b0),
  .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
  .native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rdata(native_rdata),.native_rid(4'b0));
 integer cycle=0,left=0,index=0,address=0,quads=0,checks=0,native_bytes=0,requests=0;
 reg scoring=0,expect_error=0,block_ar=0;
 reg [95:0] held;reg held_valid=0,held_last,held_error;
 function [23:0] rgb(input integer x,input integer y);
  begin rgb={8'(x+3*y+1),8'(x*7+y+2),8'(x+y*9+3)};end
 endfunction
 function [7:0] memory_byte(input integer a);
  integer y,x,channel;reg [23:0] value;
  begin y=(a-source_base)/source_stride;x=((a-source_base)%source_stride)/3;channel=(a-source_base)%source_stride%3;
   value=rgb(x,y);
   if(x>=source_width || y>=source_height)memory_byte=8'hde;
   else case(channel)0:memory_byte=value[23:16];1:memory_byte=value[15:8];2:memory_byte=value[7:0];endcase
  end
 endfunction
 always @(negedge clk)begin
  arready=rst_n && left==0 && !block_ar && cycle%5!=0;
  native_rvalid=rst_n && left!=0 && cycle%3!=0;native_rlast=left==1;
  for(integer b=0;b<32;b=b+1)native_rdata[b*8+:8]=memory_byte(address+index*32+b);
  fill_ready=scoring && cycle%4!=0;
 end
 always @(posedge clk)begin
  cycle++;
  if(!rst_n)begin left=0;index=0;held_valid=0;end
  else begin
   if(native_rvalid)begin left--;index++;native_bytes+=32;end
   if(arvalid && arready)begin
    address=araddr*4;left=arlen+1;index=0;requests++;
    if(address%4096+left*32>4096)$fatal(1,"physical column crossing");
    if((address-source_base)/source_stride>=source_height)$fatal(1,"read virtual row");
   end
   if(held_valid && {fill_rgb,fill_last,fill_error}!=={held,held_last,held_error})$fatal(1,"stalled quad changed");
   held_valid=fill_valid && !fill_ready;held=fill_rgb;held_last=fill_last;held_error=fill_error;
   if(fill_valid && fill_ready)begin
    if(expect_error)begin
     if(!fill_error || !fill_last)$fatal(1,"failure must terminate after drain");
    end else begin
     for(integer p=0;p<4;p=p+1)begin
      integer x,y;reg [23:0] expected;
      x=fill_tile_x*32+(quads%16)*2+(p%2);y=fill_tile_y*8+(quads/16)*2+(p/2);
      expected=(x>=source_width || y>=source_height)?0:rgb(x,y);
      if(fill_rgb[p*24+:24]!==expected)$fatal(1,"quad=%0d sample=%0d got=%h expected=%h",quads,p,fill_rgb[p*24+:24],expected);
      checks++;
     end
     if(fill_last!=(quads==63) || fill_error)$fatal(1,"quad termination");
    end
    quads++;
   end
  end
 end
 task submit(input integer tx,input integer ty);
  begin @(negedge clk);fill_tile_x=tx;fill_tile_y=ty;fill_req_valid=1;quads=0;
   @(posedge clk);@(negedge clk);fill_req_valid=0;end
 endtask
 task run_tile(input integer tx,input integer ty);
  integer before_bytes;
  begin before_bytes=native_bytes;scoring=1;submit(tx,ty);wait(quads==64);@(negedge clk);
   if(fill_bus_bytes!=native_bytes-before_bytes || busy)$fatal(1,"byte accounting/drain");
   scoring=0;repeat(3)@(negedge clk);
  end
 endtask
 initial begin
  repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
  run_tile(0,0);run_tile(42,3); // x*96=4032: actual row crosses 4KiB.
  source_width=EDGE_WIDTH;source_height=1079;run_tile(59,134); // odd right/bottom.
  // Abort an already VALID address: retain it through acceptance, then drain.
  scoring=1;block_ar=1;expect_error=1;submit(1,0);wait(arvalid);cancel=1;
  repeat(12)@(negedge clk);if(fill_valid || !arvalid)$fatal(1,"cancel withdrew address or completed early");
  block_ar=0;wait(quads==1);@(negedge clk);cancel=0;scoring=0;
  if(busy || left!=0)$fatal(1,"cancel completion before native drain");
  expect_error=0;run_tile(1,0);
  if(EDGE_WIDTH==1919)begin
   // Reset while an accepted transfer is returning data, then restart with
   // a tiny cold frame; no previously stored byte may become a valid sample.
   scoring=1;submit(0,0);wait(r_valid);@(negedge clk);rst_n=0;scoring=0;
   repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
   source_width=2;source_height=2;run_tile(0,0);
   // Exercise 1/2/3-beat row tails and both actual and virtual bottom rows.
   for(integer wi=0;wi<11;wi++)begin
    case(wi)
     0:source_width=2;1:source_width=10;2:source_width=11;3:source_width=21;
     4:source_width=22;5:source_width=31;6:source_width=32;7:source_width=33;
     8:source_width=63;9:source_width=64;10:source_width=65;
    endcase
    for(integer hi=0;hi<5;hi++)begin
     case(hi)0:source_height=2;1:source_height=3;2:source_height=7;
      3:source_height=8;4:source_height=9;endcase
     run_tile((source_width-1)/32,(source_height-1)/8);
    end
   end
   $display("STORAGE_EDGE_PASS tiny_cold_frame=1 tail_bottom_shapes=55 mid_dma_reset=1");
  end
  // Reject wrapped source spans before issuing any memory request.
  begin integer before_requests;before_requests=requests;
   source_base=32'hffffffe0;expect_error=1;scoring=1;submit(0,0);
   wait(quads==1);@(negedge clk);
   if(requests!=before_requests || busy)$fatal(1,"source address wrap not rejected");
  end
  $display("GEOMETRY_TILE_REFILL_PASS checks=%0d requests=%0d",checks,requests);$finish;
 end
 initial begin #2000000;$fatal(1,"REFILL_TIMEOUT");end
 wire  baseline_fill_req_ready;
 wire  baseline_fill_valid;
 wire  baseline_fill_last;
 wire  baseline_fill_error;
 wire  baseline_req_valid;
 wire  baseline_req_write;
 wire  baseline_dma_cancel;
 wire  baseline_r_ready;
 wire  baseline_done_ready;
 wire  baseline_busy;
 wire [31:0] baseline_fill_bus_bytes;
 wire [31:0] baseline_req_addr;
 wire [31:0] baseline_req_tag;
 wire [95:0] baseline_fill_rgb;
 wire [4:0] baseline_req_beats;
 geometry_tile_refill_baseline  baseline(.fill_req_ready(baseline_fill_req_ready),.fill_valid(baseline_fill_valid),.fill_last(baseline_fill_last),.fill_error(baseline_fill_error),.req_valid(baseline_req_valid),.req_write(baseline_req_write),.dma_cancel(baseline_dma_cancel),.r_ready(baseline_r_ready),.done_ready(baseline_done_ready),.busy(baseline_busy),.fill_bus_bytes(baseline_fill_bus_bytes),.req_addr(baseline_req_addr),.req_tag(baseline_req_tag),.fill_rgb(baseline_fill_rgb),.req_beats(baseline_req_beats),.clk(clk),.rst_n(rst_n),.fill_req_valid(fill_req_valid),.fill_tile_x(fill_tile_x),.fill_tile_y(fill_tile_y),.source_base(source_base),.source_stride(source_stride),.source_generation(source_generation),.source_width(source_width),.source_height(source_height),.fill_ready(fill_ready),.cancel(cancel),.req_ready(req_ready),.r_valid(r_valid),.r_data(r_data),.r_last(r_last),.done(done),.dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag));
 always @(negedge clk)begin #2;
  if(rst_n)begin
   if({fill_req_ready,fill_valid,req_valid,dma_cancel,r_ready,done_ready,busy,fill_bus_bytes} !==
      {baseline_fill_req_ready,baseline_fill_valid,baseline_req_valid,baseline_dma_cancel,baseline_r_ready,baseline_done_ready,baseline_busy,baseline_fill_bus_bytes})$fatal(1,"REFILL_DIFFERENTIAL control/latency");
   if(req_valid && {req_addr,req_tag,req_beats,req_write} !== {baseline_req_addr,baseline_req_tag,baseline_req_beats,baseline_req_write})$fatal(1,"REFILL_DIFFERENTIAL request");
   if(fill_valid && {fill_rgb,fill_last,fill_error} !== {baseline_fill_rgb,baseline_fill_last,baseline_fill_error})$fatal(1,"REFILL_DIFFERENTIAL quad");
  end
 end
endmodule

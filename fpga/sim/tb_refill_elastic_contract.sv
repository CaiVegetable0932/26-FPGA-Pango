`timescale 1ns/1ps
// Purpose: exercise the elastic refill output, terminal ownership, cancellation
// under stall, and continuous quad delivery with the real native DMA. Independent RGB
// formula checks quad ordering, RGB byte order, source stride, physical address,
// partial edges and 4KiB splits. Source memory is synthetic, not a camera image.
module tb_refill_elastic_contract;
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
 ddr_native_dma #(.CLIENTS(1)) dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_tag(req_tag),
  .req_beats(req_beats),.cancel(dma_cancel),.urgent(1'b0),.w_valid(1'b0),.w_data(256'b0),.w_strb(32'b0),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),.done(done),.done_ready(done_ready),
  .error(dma_error),.cancelled(dma_cancelled),.done_tag(done_tag),
  .awready(1'b0),.native_wready(1'b0),.native_wid(4'b0),.native_wlast(1'b0),
  .araddr(araddr),.arlen(arlen),.arvalid(arvalid),.arready(arready),
  .native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rdata(native_rdata),.native_rid(4'b0));
 integer cycle=0,left=0,index=0,address=0,quads=0,checks=0,native_bytes=0,requests=0;
 reg scoring=0,expect_error=0,block_ar=0;
 reg block_fill=0,require_contiguous=1,allow_cancel_tail=0,error_seen=0;
 integer last_quad_cycle=0;reg [31:0] held_bytes;
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
  fill_ready=scoring && !block_fill;
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
   if(held_valid && {fill_rgb,fill_last,fill_error,fill_bus_bytes}!=={held,held_last,held_error,held_bytes})$fatal(1,"stalled quad changed");
   held_valid=fill_valid && !fill_ready;held=fill_rgb;held_last=fill_last;held_error=fill_error;held_bytes=fill_bus_bytes;
   if(fill_valid && fill_ready)begin
    if(expect_error || (allow_cancel_tail && fill_error))begin
     if(!fill_error || !fill_last)$fatal(1,"failure must terminate after drain");
     error_seen=1;
    end else begin
     if(require_contiguous && quads%16!=0 && cycle!=last_quad_cycle+1)
      $fatal(1,"quad pipeline inserted a bubble");
     last_quad_cycle=cycle;
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
  source_width=1919;source_height=1079;run_tile(59,134); // odd right/bottom.
  // Hold the terminal output after the producer has finished. The next job
  // cannot take ownership until that last published beat is consumed.
  require_contiguous=0;scoring=1;submit(1,0);
  wait(fill_valid && fill_last);block_fill=1;
  repeat(5)begin @(negedge clk);if(!busy || fill_req_ready || !fill_valid || !fill_last)
   $fatal(1,"terminal output released job ownership early");end
  fill_req_valid=1;repeat(2)@(negedge clk);fill_req_valid=0;
  block_fill=0;wait(quads==64);@(negedge clk);scoring=0;
  if(busy)$fatal(1,"terminal output did not release job");
  // Cancellation may follow already-published quads. Preserve those beats,
  // then publish exactly one terminating error and drain every native request.
  allow_cancel_tail=1;error_seen=0;scoring=1;block_fill=1;submit(1,0);
  wait(fill_valid);@(negedge clk);cancel=1;
  repeat(5)@(negedge clk);block_fill=0;
  wait(error_seen);@(negedge clk);cancel=0;scoring=0;allow_cancel_tail=0;
  if(busy || left!=0)$fatal(1,"cancelled elastic output did not drain");
  run_tile(1,0);
  // Abort an already VALID address: retain it through acceptance, then drain.
  scoring=1;block_ar=1;expect_error=1;submit(1,0);wait(arvalid);cancel=1;
  repeat(12)@(negedge clk);if(fill_valid || !arvalid)$fatal(1,"cancel withdrew address or completed early");
  block_ar=0;wait(quads==1);@(negedge clk);cancel=0;scoring=0;
  if(busy || left!=0)$fatal(1,"cancel completion before native drain");
  expect_error=0;run_tile(1,0);
  // Reject wrapped source spans before issuing any memory request.
  begin integer before_requests;before_requests=requests;
   source_base=32'hffffffe0;expect_error=1;scoring=1;submit(0,0);
   wait(quads==1);@(negedge clk);
   if(requests!=before_requests || busy)$fatal(1,"source address wrap not rejected");
  end
  $display("REFILL_ELASTIC_CONTRACT_PASS checks=%0d requests=%0d",checks,requests);$finish;
 end
 initial begin #2000000;$fatal(1,"REFILL_TIMEOUT");end
endmodule

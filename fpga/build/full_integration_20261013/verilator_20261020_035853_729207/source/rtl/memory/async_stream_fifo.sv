`timescale 1ns/1ps
// Purpose: elastic dual-clock stream storage with binary RAM addresses and
// Gray-coded pointers. Each pointer crosses through two preserved registers.
// Joint cold reset is required; per-domain release is synchronous. Constrain
// Gray source-to-first-stage delay to one fast clock period in the board FDC.
module async_stream_fifo #(parameter WIDTH=8,ADDRESS_BITS=13)(
 input write_clk,write_rst_n,input write_valid,output write_ready,input [WIDTH-1:0] write_data,
 input read_clk,read_rst_n,output reg read_valid,input read_ready,output reg [WIDTH-1:0] read_data,
 output drained
);
 localparam DEPTH=1<<ADDRESS_BITS;
 reg [WIDTH-1:0] storage[0:DEPTH-1] /* synthesis syn_ramstyle="block_ram" */;
 reg [ADDRESS_BITS:0] write_binary,write_gray,read_binary,read_gray;
 (* syn_preserve=1 *) reg [ADDRESS_BITS:0] read_meta,read_sync,write_meta,write_sync;
 wire full=write_gray=={~read_sync[ADDRESS_BITS:ADDRESS_BITS-1],read_sync[ADDRESS_BITS-2:0]};
 wire empty=read_gray==write_sync;
 wire push=write_valid && write_ready;
 wire fetch=(!read_valid || read_ready) && !empty;
 wire [ADDRESS_BITS:0] next_write=write_binary+1'b1,next_read=read_binary+1'b1;
 assign write_ready=!full,drained=empty && !read_valid;
 // Independent clocked RAM ports; the read-side holding register is also the
 // synchronous RAM return. It stays unchanged under consumer backpressure.
 always @(posedge write_clk)if(push)storage[write_binary[ADDRESS_BITS-1:0]]<=write_data;
 always @(posedge read_clk)if(fetch)read_data<=storage[read_binary[ADDRESS_BITS-1:0]];
 always @(posedge write_clk or negedge write_rst_n)begin
  if(!write_rst_n)begin write_binary<=0;write_gray<=0;read_meta<=0;read_sync<=0;end
  else begin
   read_meta<=read_gray;read_sync<=read_meta;
   if(push)begin write_binary<=next_write;write_gray<=(next_write>>1)^next_write;end
  end
 end
 always @(posedge read_clk or negedge read_rst_n)begin
  if(!read_rst_n)begin read_binary<=0;read_gray<=0;write_meta<=0;write_sync<=0;read_valid<=0;end
  else begin
   write_meta<=write_gray;write_sync<=write_meta;
   if(!read_valid || read_ready)read_valid<=!empty;
   if(fetch)begin read_binary<=next_read;read_gray<=(next_read>>1)^next_read;end
  end
 end
endmodule

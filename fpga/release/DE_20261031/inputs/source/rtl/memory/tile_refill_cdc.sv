`timescale 1ns/1ps
// Experimental one-fill mailbox plus an existing, bounded async stream FIFO.
// All row requests stay in DDR. Fixed-gray mode stores one byte per pixel
// across CDC (32-bit quad), restoring RGB888 locally after the FIFO. LAST,
// error and cumulative byte count remain atomic, with unchanged handshake.
// A new tile is accepted only after the previous LAST is consumed. Common
// cold reset is mandatory. Gray pointers need <=6ns source-to-meta bounds;
// the held tile coordinates need a bounded-data capture constraint too.
module tile_refill_cdc #(parameter HISTORY_SUPPORT=0,GRAYSCALE=0)(
 input processing_clk,processing_rst_n,
 input fill_req_valid,output fill_req_ready,input [11:0] fill_tile_x,fill_tile_y,
 input fill_history,output reg memory_history,
 output fill_valid,input fill_ready,output [95:0] fill_rgb,
 output fill_last,fill_error,output [31:0] fill_bus_bytes,output reg busy,
 input memory_clk,memory_rst_n,
 output memory_req_valid,input memory_req_ready,output reg [11:0] memory_tile_x,memory_tile_y,
 input memory_fill_valid,output memory_fill_ready,input [95:0] memory_fill_rgb,
 input memory_fill_last,memory_fill_error,input [31:0] memory_fill_bus_bytes
);
 localparam M_IDLE=0,M_REQUEST=1,M_RUN=2;
 reg [1:0] mstate;
 reg request_toggle,accepted_toggle;
 // Domain bit crosses in the same held mailbox as tile coordinates. It remains
 // stable until the previous tile's LAST drains, including errors/cancellation.
 reg [24:0] tile_held;
 (* syn_preserve=1 *) reg request_meta,request_sync;
 localparam QUAD_BITS=GRAYSCALE?32:96;
 wire fifo_write_ready;wire [QUAD_BITS+33:0] fifo_data;wire fifo_drained;
 wire [QUAD_BITS-1:0] stored_quad,received_quad;
 // The upstream fixed-gray ISP guarantees R=G=B. Packing is wiring only:
 // no arithmetic, serialization, extra cycle, or change to FIFO pointers.
 genvar pixel;
 generate if(GRAYSCALE)begin:gray_quads
  for(pixel=0;pixel<4;pixel=pixel+1)begin:lanes
   assign stored_quad[pixel*8+:8]=memory_fill_rgb[pixel*24+:8];
   assign fill_rgb[pixel*24+:24]={3{received_quad[pixel*8+:8]}};
  end
 end else begin:rgb_quads
  assign stored_quad=memory_fill_rgb;
  assign fill_rgb=received_quad;
 end endgenerate
 assign fill_req_ready=!busy;
 assign memory_req_valid=mstate==M_REQUEST;
 assign memory_fill_ready=mstate==M_RUN && fifo_write_ready;
 assign {fill_last,fill_error,fill_bus_bytes,received_quad}=fifo_data;
 async_stream_fifo #(.WIDTH(QUAD_BITS+34),.ADDRESS_BITS(4)) quads(
  .write_clk(memory_clk),.write_rst_n(memory_rst_n),
  .write_valid(memory_fill_valid && mstate==M_RUN),.write_ready(fifo_write_ready),
  .write_data({memory_fill_last,memory_fill_error,memory_fill_bus_bytes,stored_quad}),
  .read_clk(processing_clk),.read_rst_n(processing_rst_n),.read_valid(fill_valid),
  .read_ready(fill_ready),.read_data(fifo_data),.drained(fifo_drained));
 always @(posedge processing_clk or negedge processing_rst_n)begin
  if(!processing_rst_n)begin busy<=0;request_toggle<=0;tile_held<=0;end
  else begin
   if(fill_req_valid && fill_req_ready)begin
    tile_held<={HISTORY_SUPPORT && fill_history,fill_tile_x,fill_tile_y};request_toggle<=!request_toggle;busy<=1;
   end
   if(fill_valid && fill_ready && fill_last)busy<=0;
  end
 end
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin
   mstate<=M_IDLE;request_meta<=0;request_sync<=0;accepted_toggle<=0;memory_tile_x<=0;memory_tile_y<=0;memory_history<=0;
  end else begin
   request_meta<=request_toggle;request_sync<=request_meta;
   case(mstate)
    M_IDLE:if(request_sync!=accepted_toggle)begin
     {memory_history,memory_tile_x,memory_tile_y}<=tile_held;mstate<=M_REQUEST;
    end
    M_REQUEST:if(memory_req_ready)begin accepted_toggle<=request_sync;mstate<=M_RUN;end
    M_RUN:if(memory_fill_valid && memory_fill_ready && memory_fill_last)mstate<=M_IDLE;
   endcase
  end
 end
endmodule

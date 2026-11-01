`timescale 1ns/1ps
// Bounded one-request reader using section 04 BYTE-address/32B-beat contract.
// Each row is independently unpacked; serialized chunks concatenate across
// rows without emitting DDR padding. Completion waits for adapter done ACK.
// Cancel always drains the issued transaction before done; slot release is an
// external frame-manager operation, never inferred from the last request.
module raw_dma_reader #(parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048,ALIGNED_ROWS=0)(
 input clk,input rst_n,input start,output start_ready,input [31:0] base_addr,
 input [31:0] slot_begin,slot_end,
 input cancel,output reg done,output reg failed,
 output req_valid,input req_ready,output [31:0] req_addr,output [4:0] req_beats,
 input r_valid,output r_ready,input [255:0] r_data,
 input dma_done,output dma_done_ready,input dma_error,
 output dma_cancel,output byte_valid,input byte_ready,output [7:0] byte_data
);
 // Static board geometry proves full chunks; partial-width or unaligned
 // readers preserve the general unpacker and serializer byte-count behavior.
 localparam FULL_CHUNKS=ALIGNED_ROWS && WIDTH>0 && (WIDTH%32)==0;
 localparam IDLE=0,ROW=1,REQ=2,READ=3,DRAIN=4,WAIT_ROW=5;
 reg [2:0] state;
 reg [31:0] row_base,burst_addr;
 reg [15:0] row;
 reg [15:0] remaining;
 reg aborted,row_ended,loaded;
 reg [255:0] chunk_q;
 reg [5:0] chunk_size,chunk_pos;
 wire unpack_start_ready,beat_ready,chunk_valid,chunk_last;
 wire [255:0] chunk_data;wire [5:0] chunk_bytes;
 wire [15:0] span=(4096-{4'd0,burst_addr[11:0]})>>5;
 wire [15:0] chosen=(remaining<16)?remaining:16;
 wire [4:0] burst_size=(chosen<span)?chosen:span;
 localparam [63:0] STRIDE_BYTES=STRIDE;
 wire [63:0] rounded_end=({32'd0,base_addr}+(HEIGHT-1)*STRIDE_BYTES+WIDTH+31)&64'hffffffffffffffe0;
 assign start_ready=state==IDLE;
 assign req_valid=state==REQ && !cancel && !aborted;
 assign req_addr=burst_addr;assign req_beats=burst_size;
 assign dma_cancel=aborted || cancel;
 assign dma_done_ready=state==READ || state==DRAIN;
 // Accept/discard any already-present client response during drain as well as
 // requesting adapter cancellation. The adapter may suppress later delivery;
 // neither policy can leave an issued response permanently backpressured.
 assign r_ready=state==DRAIN || (state==READ && (aborted || cancel || beat_ready));
 assign byte_valid=loaded && !aborted && !cancel;
 assign byte_data=chunk_q[chunk_pos*8+:8];
 // The board selects aligned chunks only for validated immutable frame-pool
 // bases/strides. Other callers preserve the complete unaligned-byte contract.
 dma_byte_unpack #(.ALIGNED_ROWS(ALIGNED_ROWS),.FULL_CHUNKS(FULL_CHUNKS)) unpack(.clk(clk),.rst_n(rst_n && !aborted),
  .start_valid(state==ROW && !cancel),.start_ready(unpack_start_ready),
  .start_offset(row_base[4:0]),.row_bytes(WIDTH),
  .beat_valid(r_valid && state==READ && !cancel && !aborted),.beat_ready(beat_ready),.beat_data(r_data),
  .chunk_valid(chunk_valid),.chunk_ready(!loaded && !cancel && !aborted),.chunk_data(chunk_data),
  .valid_bytes(chunk_bytes),.chunk_last(chunk_last));
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin state<=IDLE;row_base<=0;burst_addr<=0;row<=0;remaining<=0;
   aborted<=0;row_ended<=0;loaded<=0;chunk_q<=0;chunk_size<=0;chunk_pos<=0;done<=0;failed<=0;end
  else begin
   done<=0;
   if(start && start_ready) begin
    row_base<=base_addr;row<=0;state<=ROW;aborted<=0;failed<=0;loaded<=0;
    if(WIDTH<=0 || HEIGHT<=0 || STRIDE<WIDTH || slot_begin[4:0]!=0 || slot_end[4:0]!=0 ||
       (ALIGNED_ROWS && (base_addr[4:0]!=0 || (STRIDE&31)!=0)) ||
       (base_addr&32'hffffffe0)<slot_begin || rounded_end>{32'd0,slot_end}) begin
     state<=IDLE;done<=1;failed<=1;
    end
   end
   if(cancel && state!=IDLE) begin
    aborted<=1;failed<=1;loaded<=0;
    // Cancellation may coincide with the final adapter done/ACK, or remain
    // asserted throughout DRAIN. Both states assert dma_done_ready: consume
    // completion here too, otherwise the cancel branch masks the drain case
    // and waits forever for a response already acknowledged by the adapter.
    if((state==READ || state==DRAIN) && dma_done) begin state<=IDLE;done<=1;end
    else if(state==READ) state<=DRAIN;
    else if(state!=DRAIN) begin state<=IDLE;done<=1;end
   end else case(state)
    ROW: if(unpack_start_ready) begin
     burst_addr<=row_base&32'hffffffe0;remaining<=(row_base[4:0]+WIDTH+31)>>5;
     row_ended<=0;state<=REQ;
    end
    REQ: if(req_ready) state<=READ;
    READ: if(dma_done) begin
     if(dma_error) begin failed<=1;aborted<=1;state<=IDLE;done<=1;loaded<=0;end
     else if(remaining>burst_size) begin
      burst_addr<=burst_addr+burst_size*32;remaining<=remaining-burst_size;state<=REQ;
     end else state<=WAIT_ROW;
    end
    WAIT_ROW: if(row_ended && !loaded) begin
     if(row==HEIGHT-1) begin state<=IDLE;done<=1;end
     else begin row_base<=row_base+STRIDE;row<=row+1'b1;state<=ROW;end
    end
    DRAIN: if(dma_done) begin state<=IDLE;done<=1;loaded<=0;end
    default: begin end
   endcase
   if(chunk_valid && !loaded && !cancel && !aborted) begin
    chunk_q<=chunk_data;chunk_size<=FULL_CHUNKS ? 6'd32 : chunk_bytes;chunk_pos<=0;loaded<=1;
    if(chunk_last) row_ended<=1;
   end
   if(byte_valid && byte_ready) begin
    if(FULL_CHUNKS ? chunk_pos==31 : chunk_pos==chunk_size-1) loaded<=0;else chunk_pos<=chunk_pos+1'b1;
   end
  end
 end
endmodule

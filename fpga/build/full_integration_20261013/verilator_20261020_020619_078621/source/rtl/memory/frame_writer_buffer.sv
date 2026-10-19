`timescale 1ns/1ps
// Purpose: decouple an II=1 pixel producer from the segment writer's native
// request/readback stalls. A bounded coordinate/RGB RAM holds up to 513 pixels
// including the output register. Abort discards only local queued pixels while
// the underlying writer still drains every accepted native transaction.
module frame_writer_buffer #(parameter TILED=0,ADDRESS_BITS=9)(
 input clk,rst_n,input frame_valid,output frame_ready,
 input [31:0] frame_base,frame_stride,frame_generation,input [15:0] frame_width,frame_height,
 input frame_rgb888,frame_abort,input in_valid,output in_ready,input [23:0] in_pixel,input [15:0] in_x,in_y,
 output frame_done,frame_failed,output [31:0] accepted_pixels,
 output req_valid,input req_ready,output req_write,output [31:0] req_addr,req_tag,output [4:0] req_beats,
 output w_valid,input w_ready,output [255:0] w_data,output [31:0] w_strb,output dma_cancel,
 input done,output done_ready,input dma_error,dma_cancelled,input [31:0] done_tag
);
 reg [55:0] storage[0:(1<<ADDRESS_BITS)-1] /* synthesis syn_ramstyle="block_ram" */;
 reg [ADDRESS_BITS:0] write_index,read_index;
 reg output_valid,active,aborted;reg [55:0] q;
 reg [31:0] admitted,expected;
 wire empty=write_index==read_index;
 wire full=write_index[ADDRESS_BITS]!=read_index[ADDRESS_BITS] && write_index[ADDRESS_BITS-1:0]==read_index[ADDRESS_BITS-1:0];
 wire writer_ready,pixel_ready,writer_done,writer_failed;
 wire fetch=(!output_valid || pixel_ready) && !empty && !aborted && !frame_abort;
 assign frame_ready=writer_ready && !active && empty && !output_valid;
 assign in_ready=active && !aborted && !frame_abort && !full && !writer_failed && !writer_done && admitted<expected;
 assign frame_done=writer_done,frame_failed=writer_failed;
 always @(posedge clk)begin
  if(in_valid && in_ready)storage[write_index[ADDRESS_BITS-1:0]]<={in_y,in_x,in_pixel};
  if(fetch)q<=storage[read_index[ADDRESS_BITS-1:0]];
 end
 // Queue flush never resets the shared DDR fabric or the writer's ownership.
 // Exact input-count bounds prevent extra pixels from leaking into the next job.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin write_index<=0;read_index<=0;output_valid<=0;active<=0;aborted<=0;admitted<=0;expected<=0;end
  else begin
   if(frame_valid && frame_ready)begin active<=1;aborted<=0;admitted<=0;expected<=frame_width*frame_height;end
   if(in_valid && in_ready)begin write_index<=write_index+1'b1;admitted<=admitted+1'b1;end
   if(!output_valid || pixel_ready)output_valid<=!empty && !aborted && !frame_abort;
   if(fetch)read_index<=read_index+1'b1;
   if(frame_abort && active)begin aborted<=1;output_valid<=0;read_index<=write_index;end
   if(writer_done)begin active<=0;aborted<=0;output_valid<=0;read_index<=write_index;end
  end
 end
 frame_pixel_writer #(.TILED(TILED)) writer(.clk(clk),.rst_n(rst_n),.frame_valid(frame_valid && frame_ready),.frame_ready(writer_ready),
  .frame_base(frame_base),.frame_stride(frame_stride),.frame_generation(frame_generation),.frame_width(frame_width),.frame_height(frame_height),
  .frame_rgb888(frame_rgb888),.frame_abort(frame_abort || aborted),.in_valid(output_valid && !frame_abort && !aborted),.in_ready(pixel_ready),
  .in_pixel(q[23:0]),.in_x(q[39:24]),.in_y(q[55:40]),.frame_done(writer_done),.frame_failed(writer_failed),.accepted_pixels(accepted_pixels),
  .req_valid(req_valid),.req_ready(req_ready),.req_write(req_write),.req_addr(req_addr),.req_tag(req_tag),.req_beats(req_beats),
  .w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_strb(w_strb),.dma_cancel(dma_cancel),
  .done(done),.done_ready(done_ready),.dma_error(dma_error),.dma_cancelled(dma_cancelled),.done_tag(done_tag));
endmodule

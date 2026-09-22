// Purpose: four-phase frame lease/release across pixel and memory clocks.
// Prefetch during vertical blank; start only on a raster boundary. On underflow
// drain the entire remaining frame without display, never reset FIFO pointers.
module raw8_hdmi_consumer(
 input wire clk,rst_n,frame_ack,release_ack,
 output reg frame_req,release_req,
 input wire [255:0] word_data,input wire word_valid,output wire word_ready,
 output wire hs,vs,de,output wire [23:0] rgb,output wire [31:0] underflows
);
 (* syn_preserve=1 *) reg ack_meta,ack_sync,rel_meta,rel_sync;
 reg [2:0] state;reg start,active,drain;
 wire boundary,valid,ready,unpack_done;wire [7:0] sample;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin ack_meta<=0;ack_sync<=0;rel_meta<=0;rel_sync<=0;end
  else begin ack_meta<=frame_ack;ack_sync<=ack_meta;rel_meta<=release_ack;rel_sync<=rel_meta;end
 raw8_unpack u_unpack(.clk(clk),.reset_n(rst_n),.start(start),.idle(),
  .word_data(word_data),.word_valid(word_valid),.word_ready(word_ready),
  .pixel_data(sample),.pixel_valid(valid),.pixel_last(),
  .pixel_ready(ready || drain),.done(unpack_done));
 raw8_hdmi_timing u_raster(.clk(clk),.reset_n(rst_n),.enable(active && !drain),
  .sample(sample),.sample_valid(valid),.sample_ready(ready),.hsync(hs),.vsync(vs),
  .de(de),.frame_boundary(boundary),.rgb(rgb),.underflows(underflows));
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;start<=0;active<=0;drain<=0;frame_req<=0;release_req<=0;end
  else begin
   start<=0;
   if(ready && !valid)drain<=1;
   case(state)
    0:begin frame_req<=1;state<=1;end
    1:if(ack_sync)begin frame_req<=0;state<=2;end
    2:if(boundary && !ack_sync)begin start<=1;active<=1;drain<=0;state<=3;end
    3:if(unpack_done)begin active<=0;release_req<=1;state<=4;end
    4:if(rel_sync)begin release_req<=0;state<=5;end
    5:if(!rel_sync)state<=0;
    default:state<=0;
   endcase
  end
endmodule

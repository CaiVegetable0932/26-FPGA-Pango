`timescale 1ns/1ps
// Purpose: connect formal registered RGB/control to the established MINI
// three-stage TMDS encoders and Logos2 native serializers. No clock generation
// or ordinary-logic serialization here. serial_clk/pixel_clk are coherent 5:1.
// serializer_reset is the dedicated divider/OSERDES startup pulse; pixel_rst_n
// controls encoders only. Integration must retain GTP_IOCLKBUF/IOCLKDIV topology.
module hdmi_rgb888_tx #(parameter SPLIT_PIXEL_CLOCKS=0)(
 input pixel_clk,serial_clk,pixel_rst_n,serializer_reset,
 // Full scanout RAM/logic may require a global clock buffer. The serializers
 // retain the regional native divider clock; both clocks share that divider
 // and their real skew/data paths must remain related and timed in PDS.
 input serializer_pixel_clk,
 input [23:0] rgb,input hs,vs,de,
 input tag_valid,input [63:0] epoch,source_frame_id,input [31:0] generation,
 output [2:0] data_p,data_n,output clock_p,clock_n,
 output symbol_tag_valid,output [63:0] symbol_epoch,symbol_source_frame_id,
 output [31:0] symbol_generation
);
 wire [9:0] symbols[0:2];
 // Purpose: lane 0 is blue and carries HS/VS during blanking; red/green
 // blanking controls are zero. Pixel order R,G,B is independent of lane order.
 genvar lane;
 generate for(lane=0;lane<3;lane=lane+1) begin: channel
  tmds_encoder encoder(.pix_clk(pixel_clk),.rstn(pixel_rst_n),
   .din(rgb[lane*8+:8]),.c0(lane==0?hs:1'b0),.c1(lane==0?vs:1'b0),.de(de),.dout(symbols[lane]));
  tmds_serializer serializer(.pixel_clk(SPLIT_PIXEL_CLOCKS?serializer_pixel_clk:pixel_clk),.serial_clk(serial_clk),
   .reset(serializer_reset),.symbol(symbols[lane]),.data_p(data_p[lane]),.data_n(data_n[lane]));
 end endgenerate
 tmds_serializer clock_serializer(.pixel_clk(SPLIT_PIXEL_CLOCKS?serializer_pixel_clk:pixel_clk),.serial_clk(serial_clk),
 .reset(serializer_reset),.symbol(10'b1111100000),.data_p(clock_p),.data_n(clock_n));
 reg [2:0] valid_pipe;
 reg [63:0] epoch_pipe[0:2],id_pipe[0:2];
 reg [31:0] gen_pipe[0:2];
 integer i;
 // Purpose: source metadata tracks the encoder's three sample registers.
 // This is internal observability, not an identity claim for a capture card.
 always @(posedge pixel_clk or negedge pixel_rst_n)
  if(!pixel_rst_n) begin
   valid_pipe<=0;
   for(i=0;i<3;i=i+1) begin epoch_pipe[i]<=0;id_pipe[i]<=0;gen_pipe[i]<=0;end
  end else begin
   valid_pipe<={valid_pipe[1:0],tag_valid && de};
   epoch_pipe[0]<=epoch;id_pipe[0]<=source_frame_id;gen_pipe[0]<=generation;
   for(i=1;i<3;i=i+1) begin epoch_pipe[i]<=epoch_pipe[i-1];id_pipe[i]<=id_pipe[i-1];gen_pipe[i]<=gen_pipe[i-1];end
  end
 assign symbol_tag_valid=valid_pipe[2];
 assign symbol_epoch=epoch_pipe[2];assign symbol_source_frame_id=id_pipe[2];assign symbol_generation=gen_pipe[2];
endmodule

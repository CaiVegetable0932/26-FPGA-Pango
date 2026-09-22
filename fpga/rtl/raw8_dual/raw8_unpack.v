// Purpose: serialize little-endian DDR words into unchanged RAW8 bytes with
// ready/valid backpressure. A reader supplies only WIDTH/32 words per row,
// skipping the unwritten 128-byte DDR padding. Start only on a locked frame.
module raw8_unpack #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,reset_n,start, output wire idle,
 input wire [255:0] word_data,input wire word_valid,output wire word_ready,
 output wire [7:0] pixel_data,output wire pixel_valid,pixel_last,
 input wire pixel_ready,output reg done
);
 reg active,loaded;
 reg [255:0] shift;
 reg [4:0] lane;
 reg [21:0] count;
 assign idle=!active;
 assign word_ready=active && (!loaded || (pixel_ready && lane==31 && !pixel_last));
 assign pixel_valid=active && loaded;
 assign pixel_data=shift[7:0];
 assign pixel_last=pixel_valid && count==WIDTH*HEIGHT-1;
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin active<=0;loaded<=0;shift<=0;lane<=0;count<=0;done<=0;end
  else begin
   done<=0;
   if(start && !active)begin active<=1;loaded<=0;lane<=0;count<=0;end
   if(pixel_valid && pixel_ready)begin
    shift<=shift>>8;lane<=lane+1'b1;count<=count+1'b1;
    if(lane==31)loaded<=0;
    if(pixel_last)begin active<=0;loaded<=0;done<=1;end
   end
   // Purpose: allow a new word on the outgoing word's final accepted byte,
   // but never acknowledge an extra word on the final byte of the frame.
   if(word_valid && word_ready)begin shift<=word_data;loaded<=1;lane<=0;end
  end
endmodule

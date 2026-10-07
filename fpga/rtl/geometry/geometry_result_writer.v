// Purpose: pack grayscale results and an exact 1-bit/pixel validity mask into
// a private 4-MiB result slot. Only a matching ordered native-read fence may
// publish a frame. WIDTH*HEIGHT must be a multiple of 256 (true for 1080p).
module geometry_result_writer #(parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048)(
 input wire clk,rst_n,start,input wire [27:0] base,
 input wire pixel_valid,pixel_mask,input wire [7:0] pixel,output wire pixel_ready,
 output reg done,good,fault,
 output reg [27:0] awaddr,output wire [3:0] awlen,output reg awvalid,
 input wire awready,wready,wlast,input wire [3:0] wid,
 output reg [255:0] wdata,output wire [31:0] wstrb,
 output wire fence_req,output reg [27:0] fence_addr,
 input wire fence_ready,fence_valid,fence_done,input wire [255:0] fence_data
);
 reg [2:0] state;reg active,last_word,writing_mask;
 reg [27:0] held_base;reg [255:0] pack,mask_pack;
 reg [4:0] lane;reg [7:0] mask_lane;
 reg [31:0] count,mask_block;reg [11:0] column,row;
 reg matched;
 assign pixel_ready=active && state==0 && !fault;
 assign awlen=0,wstrb=32'hffffffff;
 assign fence_req=state==3;
 // Purpose: leave the 128-byte row padding untouched. Mask words are stored
 // at slot+0x280000, outside the 1080*2048 grayscale rows and inside the slot.
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   state<=0;active<=0;last_word<=0;writing_mask<=0;held_base<=0;
   pack<=0;mask_pack<=0;lane<=0;mask_lane<=0;count<=0;mask_block<=0;column<=0;row<=0;
   awaddr<=0;awvalid<=0;wdata<=0;fence_addr<=0;matched<=0;done<=0;good<=0;fault<=0;
  end else begin
   done<=0;
   if(start && !active && !fault)begin
    held_base<=base;active<=1;lane<=0;mask_lane<=0;count<=0;column<=0;row<=0;
    mask_block<=0;pack<=0;mask_pack<=0;good<=0;
   end
   if(pixel_valid && pixel_ready)begin
    pack[lane*8+:8]<=pixel;mask_pack[mask_lane]<=pixel_mask;
    count<=count+1'b1;lane<=lane+1'b1;mask_lane<=mask_lane+1'b1;
    if(lane==31)begin
     wdata<={pixel,pack[247:0]};awaddr<=(held_base+row*STRIDE+column)>>2;
     fence_addr<=held_base+row*STRIDE+column;
     awvalid<=1;state<=1;writing_mask<=0;last_word<=count==WIDTH*HEIGHT-1;
     if(column==WIDTH-32)begin column<=0;row<=row+1'b1;end else column<=column+12'd32;
    end
   end
   if(state==1 && awready)begin awvalid<=0;state<=2;end
   if((state==2 || (state==1 && awready)) && wready)begin
    if(!wlast || wid!=0)fault<=1;
    if(!writing_mask && mask_lane==0)begin
     wdata<=mask_pack;awaddr<=(held_base+28'h280000+(mask_block<<5))>>2;
     fence_addr<=held_base+28'h280000+(mask_block<<5);
     mask_block<=mask_block+1'b1;awvalid<=1;writing_mask<=1;state<=1;
    end else if(last_word)begin state<=3;matched<=0;end
    else state<=0;
   end
   if(state==3 && fence_ready)state<=4;
   if(state==4 && fence_valid)matched<=fence_data==wdata;
   if(state==4 && fence_done)begin
    active<=0;done<=1;good<=!fault && (matched || (fence_valid && fence_data==wdata));
    if(!(matched || (fence_valid && fence_data==wdata)))fault<=1;
    state<=0;
   end
  end
endmodule

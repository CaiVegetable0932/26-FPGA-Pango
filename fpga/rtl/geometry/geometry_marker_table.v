// Purpose: build twenty forward correspondences from one immutable processing
// configuration. Completion is required before publishing its result slot.
module geometry_marker_table #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,rst_n,start,original,input wire [1:0] model,input wire [447:0] words,
 output reg ready,output reg [1279:0] coordinates,output reg [19:0] visible_mask,
 output reg [31:0] status);
 reg [2:0] state;reg [4:0] index;reg [447:0] held_words;reg [1:0] held_model;reg held_original;
 reg lut_start,map_start;wire lut_done,lut_failed,map_done,map_visible,map_failed;
 wire [15:0] sx,sy;wire [23:0] color;wire signed [31:0] dx,dy,s0,s1;wire [10:0] li;
 geometry_marker_catalog #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_catalog(index,sx,sy,color);
 geometry_lens_lut u_lut(.clk(clk),.rst_n(rst_n),.start(lut_start),.build_bank(1'b0),
  .model(held_model),.k1(held_words[223:192]),.k2(held_words[255:224]),
  .k3(held_words[287:256]),.k4(held_words[319:288]),.busy(),.done(lut_done),.failed(lut_failed),
  .read_bank(1'b0),.read_index(li),.scale0(s0),.scale1(s1));
 geometry_marker_map #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_map(
  .clk(clk),.rst_n(rst_n),.start(map_start),.original(held_original),.model(held_model),
  .words(held_words),.sx(sx),.sy(sy),.done(map_done),.visible(map_visible),.failed(map_failed),
  .dx(dx),.dy(dy),.lut_index(li),.scale0(s0),.scale1(s1));
 always @(posedge clk or negedge rst_n)
 if(!rst_n)begin state<=0;ready<=0;coordinates<=0;visible_mask<=0;status<=0;
  index<=0;held_words<=0;held_model<=0;held_original<=0;lut_start<=0;map_start<=0;end
 else begin
  lut_start<=0;map_start<=0;
  case(state)
   0:if(start)begin held_words<=words;held_model<=model;held_original<=original;
    ready<=0;visible_mask<=0;status<=0;index<=0;state<=1;
    coordinates<={20{64'h8000000080000000}};
   end
   1:if(held_original || held_model==0)state<=3;
    else if(held_model>2 || (held_model==1 && held_words[319:256]!=0))begin status<=9;ready<=1;state<=0;end
    else begin lut_start<=1;state<=2;end
   2:if(lut_done)begin
    if(lut_failed)begin status<=5;ready<=1;state<=0;end else state<=3;
   end
   3:begin map_start<=1;state<=4;end
   4:if(map_done)begin
    coordinates[index*64+:64]<={dy,dx};visible_mask[index]<=map_visible;
    if(map_failed)status[1]<=1;
    if(index==19)begin ready<=1;status[0]<=1;state<=0;end
    else begin index<=index+1'b1;state<=3;end
   end
  endcase
 end
endmodule

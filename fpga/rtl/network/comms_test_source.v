// Purpose: backpressure-safe SYNTHETIC RAW8 test source, not camera capture.
// Fixed 1920x1080/30 admission budget; checker/ramp moves with frame_id.
// descriptor_id=0x54534554 in the board top identifies TEST. Host evidence must
// retain that identity and must not count these frames as camera verification.
module comms_test_source #(parameter WIDTH=1920,HEIGHT=1080,PERIOD=4166667)(
 input wire clk,reset_n,enable,frame_ready,pixel_ready,frame_done,frame_error,
 output wire frame_start,pixel_valid,pixel_last,output wire [7:0] pixel_data,
 output reg [63:0] frame_id,output reg fault,output reg [31:0] frames_done
);
 reg [1:0] state;
 localparam IDLE=0,PIXELS=1,DRAIN=2;
 reg [15:0] x,y;reg [$clog2(PERIOD)-1:0] period_left;
 assign frame_start=(state==IDLE) && enable && !fault && period_left==0;
 assign pixel_valid=(state==PIXELS);
 assign pixel_last=(x==WIDTH-1 && y==HEIGHT-1);
 assign pixel_data=(x[5]^y[5])?(x[7:0]+frame_id[7:0]):8'h20;
 always @(posedge clk or negedge reset_n)begin
  if(!reset_n)begin state<=IDLE;x<=0;y<=0;period_left<=0;frame_id<=1;fault<=0;frames_done<=0;end
  else begin
   if(period_left!=0)period_left<=period_left-1'b1;
   if(frame_error)begin fault<=1;state<=IDLE;end
   else case(state)
    IDLE:if(frame_start && frame_ready)begin state<=PIXELS;x<=0;y<=0;period_left<=PERIOD-1;end
    PIXELS:if(pixel_ready)begin
     if(pixel_last)state<=DRAIN;
     else if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
    end
    DRAIN:if(frame_done)begin
     state<=IDLE;frames_done<=frames_done+1'b1;
     // Exhaustion is fail-closed, never wrap identity within the same epoch.
     if(frame_id==64'hffffffffffffffff)fault<=1;else frame_id<=frame_id+1'b1;
    end
    default:begin fault<=1;state<=IDLE;end
   endcase
  end
 end
endmodule

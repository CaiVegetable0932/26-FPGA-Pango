// Purpose: traverse a locked 1080p RAW slot using 256-bit DDR bursts. Read
// 16+16+16+12 words per row; skip four padding words, never send them to PRAW.
// An output FIFO must reserve space for the ENTIRE requested burst before
// burst_ready. Native DDR has no mid-burst consumer backpressure guarantee.
module raw8_read_scheduler #(parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048)(
 input wire clk,reset_n,start,input wire [27:0] base,
 output wire idle,output reg request,input wire burst_ready,burst_done,
 output reg [27:0] address,output reg [4:0] length,
 output reg done
);
 reg active,outstanding;
 reg [15:0] row;
 reg [7:0] column_word;
 reg [27:0] saved_base;
 wire [7:0] remaining=WIDTH/32-column_word;
 assign idle=!active;
 always @(posedge clk or negedge reset_n)
  if(!reset_n)begin
   active<=0;outstanding<=0;row<=0;column_word<=0;saved_base<=0;
   request<=0;address<=0;length<=0;done<=0;
  end else begin
   done<=0;
   if(start && !active)begin
    active<=1;row<=0;column_word<=0;saved_base<=base;
   end
   if(active && !request && !outstanding)begin
    request<=1;address<=saved_base+row*STRIDE+column_word*32;
    length<=remaining>16 ? 16 : remaining;
   end
   if(request && burst_ready)begin request<=0;outstanding<=1;end
   if(outstanding && burst_done)begin
    outstanding<=0;
    if(column_word+length==WIDTH/32)begin
     column_word<=0;
     if(row==HEIGHT-1)begin active<=0;done<=1;end
     else row<=row+1'b1;
    end else column_word<=column_word+length;
   end
  end
endmodule

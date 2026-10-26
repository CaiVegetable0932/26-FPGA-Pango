`timescale 1ns/1ps
// Purpose: diagnostic 256-bit FIFO bursts -> installed Logos2 native DDR.
// Origin: replacement for generic AXI emulation; UG042003 pp.31-38,58.
// FIFO data appears one clock AFTER wr_data_req. Capture the complete burst
// before AW, since the controller cannot wait for WVALID. Read FIFO capacity
// is reserved by frame_fifo_read. No B channel or native read backpressure.
// Finish denotes native data completion, NOT proven global memory visibility.
module mini_ddr_native_bridge(
 input clk,input rst_n,
 input wr_req,input [9:0] wr_beats,input [24:0] wr_beat_addr,
 output wr_data_req,input [255:0] wr_data,output reg wr_finish,
 input rd_req,input [9:0] rd_beats,input [24:0] rd_beat_addr,
 output rd_data_valid,output [255:0] rd_data,output reg rd_finish,
 output [27:0] awaddr,output [3:0] awlen,output [3:0] awid,
 output awvalid,input awready,output [255:0] wdata,output [31:0] wstrb,
 input wready,input [3:0] wid,input wlast,
 output [27:0] araddr,output [3:0] arlen,output [3:0] arid,
 output arvalid,input arready,input [255:0] rdata,
 input rvalid,input [3:0] rid,input rlast,output reg fault
);
 reg [2:0] ws;
 reg [1:0] rs;
 reg wa,ra,pop_q;
 reg [4:0] wn,rn,popped,captured,wcount,rcount;
 reg [27:0] waddr_q,raddr_q;
 reg [255:0] buffer[0:15];
 // Purpose: a 32-byte FIFO beat advances eight x32 physical column addresses.
 assign awaddr=waddr_q, araddr=raddr_q;
 assign awlen=wn-1'b1,arlen=rn-1'b1,awid=0,arid=0;
 assign awvalid=(ws==2),arvalid=(rs==1);
 assign wr_data_req=(ws==1 && popped<wn);
 assign wdata=buffer[wcount];
 assign wstrb=(ws==3) ? 32'hffffffff : 32'd0;
 assign rd_data_valid=(rs==2 && rvalid && !fault);
 assign rd_data=rdata;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   ws<=0; rs<=0; wa<=1; ra<=1; pop_q<=0; fault<=0;
   wn<=1; rn<=1; popped<=0; captured<=0; wcount<=0; rcount<=0;
   waddr_q<=0; raddr_q<=0; wr_finish<=0; rd_finish<=0;
  end else begin
   wr_finish<=0; rd_finish<=0;
   if(!wr_req) wa<=1;
   if(!rd_req) ra<=1;
   pop_q<=wr_data_req;
   if(wr_data_req) popped<=popped+1'b1;
   if(pop_q) begin buffer[captured]<=wr_data; captured<=captured+1'b1; end
   case(ws)
    0: if(wr_req && wa && !fault) begin
     wa<=0;
     // Frame addresses/counts use 32-byte beats. Never truncate high bits or
     // permit a burst to wrap the controller's ten physical column bits.
     if(wr_beats==0 || wr_beats>16 ||
        {1'b0,wr_beat_addr[6:0]}+wr_beats>128) fault<=1;
     else begin
      wn<=wr_beats[4:0]; waddr_q<={wr_beat_addr,3'b0};
      popped<=0; captured<=0; wcount<=0; ws<=1;
     end
    end
    1: if(captured==wn) ws<=2;
    2: if(awready) ws<=3;
    3: if(wready) begin
     if(wid!=0 || wlast!=(wcount==wn-1'b1)) fault<=1;
     if(wcount==wn-1'b1) begin
      ws<=0;
      if(!fault && wid==0 && wlast) wr_finish<=1;
     end else wcount<=wcount+1'b1;
    end
    default: fault<=1;
   endcase
   case(rs)
    0: if(rd_req && ra && !fault) begin
     ra<=0;
     if(rd_beats==0 || rd_beats>16 || {1'b0,rd_beat_addr[6:0]}+rd_beats>128) fault<=1;
     else begin rn<=rd_beats[4:0]; raddr_q<={rd_beat_addr,3'b0}; rcount<=0; rs<=1; end
    end
    1: if(arready) rs<=2;
    2: if(rvalid) begin
     if(rid!=0 || rlast!=(rcount==rn-1'b1)) fault<=1;
     if(rcount==rn-1'b1) begin
      rs<=0;
      if(!fault && rid==0 && rlast) rd_finish<=1;
     end else rcount<=rcount+1'b1;
    end
    default: fault<=1;
   endcase
  end
 end
endmodule

`timescale 1ns/1ps
// Purpose: standard AXI only; diagnostic Top uses mini_ddr_native_bridge instead.
// Buffer synchronous FIFO reads, split at 16 beats/4 KiB, and complete on actual
// B/R handshakes. Requests use byte addresses/lengths. No fake native B allowed.
// MASTER_RST cancels between bursts after draining the current AXI transaction.
// Origin: imported MINI vendor demo; integration is not hardware validation.
module aq_axi_master_256 #(
parameter DATA_WIDTH=256, parameter MAX_BURST_BEATS=16
)(
  // Reset, Clock
  input           ARESETN,
  input           ACLK,

  // Master Write Address
  output [0:0]  M_AXI_AWID,
  output [31:0] M_AXI_AWADDR,
  output [7:0]  M_AXI_AWLEN,    // Burst Length: 0-255
  output [2:0]  M_AXI_AWSIZE,   // Burst Size: 100
  output [1:0]  M_AXI_AWBURST,  // Burst Type: Fixed 2'b01(Incremental Burst)
  output        M_AXI_AWLOCK,   // Lock: Fixed 2'b00
  output [3:0]  M_AXI_AWCACHE,  // Cache: Fiex 2'b0011
  output [2:0]  M_AXI_AWPROT,   // Protect: Fixed 2'b000
  output [3:0]  M_AXI_AWQOS,    // QoS: Fixed 2'b0000
  output [0:0]  M_AXI_AWUSER,   // User: Fixed 32'd0
  output        M_AXI_AWVALID,
  input         M_AXI_AWREADY,

  // Master Write Data
  output [DATA_WIDTH-1:0] M_AXI_WDATA,
  output [DATA_WIDTH/8-1:0]  M_AXI_WSTRB,
  output        M_AXI_WLAST,
  output [0:0]  M_AXI_WUSER,
  output        M_AXI_WVALID,
 input         M_AXI_WREADY,

  // Master Write Response
  input [0:0]   M_AXI_BID,
  input [1:0]   M_AXI_BRESP,
  input [0:0]   M_AXI_BUSER,
  input         M_AXI_BVALID,
  output        M_AXI_BREADY,
    
  // Master Read Address
  output [0:0]  M_AXI_ARID,
   output [31:0] M_AXI_ARADDR,
   output [7:0]  M_AXI_ARLEN,
   output [2:0]  M_AXI_ARSIZE,
  output [1:0]  M_AXI_ARBURST,
  output [1:0]  M_AXI_ARLOCK,//
  output [3:0]  M_AXI_ARCACHE,
  output [2:0]  M_AXI_ARPROT,
  output [3:0]  M_AXI_ARQOS,
  output [0:0]  M_AXI_ARUSER,
  output        M_AXI_ARVALID,
  input         M_AXI_ARREADY,
    
  // Master Read Data 
  input [0:0]   M_AXI_RID,
  input [DATA_WIDTH-1:0]  M_AXI_RDATA,//
  input [1:0]   M_AXI_RRESP,
  input         M_AXI_RLAST,
  input [0:0]   M_AXI_RUSER,
  input         M_AXI_RVALID,
  output        M_AXI_RREADY,
        
  // Local Bus
  input         MASTER_RST,
  
  input         WR_START,
  input [31:0]  WR_ADRS,
  input [31:0]  WR_LEN, 
  output        WR_READY,
   output        WR_FIFO_RE,
   input         WR_FIFO_EMPTY,
  input         WR_FIFO_AEMPTY,
  input [DATA_WIDTH-1:0]  WR_FIFO_DATA,
  output        WR_DONE,

  input         RD_START,
  input [31:0]  RD_ADRS,
  input [31:0]  RD_LEN, 
  output        RD_READY,
  output        RD_FIFO_WE,
  input         RD_FIFO_FULL,
  input         RD_FIFO_AFULL,
  output [DATA_WIDTH-1:0] RD_FIFO_DATA,
  output        RD_DONE,

  output WR_ERROR, output RD_ERROR,
  output [31:0] DEBUG
);


 localparam BYTES=DATA_WIDTH/8, SHIFT=$clog2(BYTES);
 localparam WI=0,WL=1,WA=2,WD=3,WB=4,WE=5;
 localparam RI=0,RA=1,RR=2,RE=3;
 reg [2:0] ws;
 reg [1:0] rs;
 reg [31:0] wa_q,ra_q,wleft,rleft,wbytes;
 reg [4:0] wn,rn,popped,captured,windex,rindex;
 reg pop_q,werr,rerr,wcancel,rcancel;
 reg [DATA_WIDTH-1:0] buffer[0:15];
 reg [31:0] planned_w,planned_r;
 integer b;
 // Purpose: keep address/LEN stable through stalls and never cross a page.
 always @* begin
  // Avoid 32-bit overflow when rounding a large legal byte count upward.
  planned_w=(wleft>>SHIFT)+((wleft&(BYTES-1))!=0);
  if(planned_w>MAX_BURST_BEATS) planned_w=MAX_BURST_BEATS;
  if(planned_w>((4096-{20'd0,wa_q[11:0]})>>SHIFT)) planned_w=(4096-{20'd0,wa_q[11:0]})>>SHIFT;
  planned_r=(rleft>>SHIFT)+((rleft&(BYTES-1))!=0);
  if(planned_r>MAX_BURST_BEATS) planned_r=MAX_BURST_BEATS;
  if(planned_r>((4096-{20'd0,ra_q[11:0]})>>SHIFT)) planned_r=(4096-{20'd0,ra_q[11:0]})>>SHIFT;
 end
 assign WR_READY=ws==WI,WR_DONE=ws==WE,WR_ERROR=werr;
 assign RD_READY=rs==RI,RD_DONE=rs==RE,RD_ERROR=rerr;
 assign WR_FIFO_RE=(ws==WL && wn!=0 && popped<wn && !WR_FIFO_EMPTY);
 assign M_AXI_AWADDR=wa_q,M_AXI_AWLEN=wn-1'b1,M_AXI_AWVALID=ws==WA;
 assign M_AXI_AWID=0,M_AXI_AWSIZE=SHIFT,M_AXI_AWBURST=1,M_AXI_AWLOCK=0;
 assign M_AXI_AWCACHE=3,M_AXI_AWPROT=0,M_AXI_AWQOS=0,M_AXI_AWUSER=0;
 assign M_AXI_WDATA=buffer[windex],M_AXI_WVALID=ws==WD,M_AXI_WLAST=windex==wn-1'b1,M_AXI_WUSER=0;
 genvar g;
 generate for(g=0;g<BYTES;g=g+1) begin: strobes
  assign M_AXI_WSTRB[g]=(ws==WD) && ((windex*BYTES+g)<wleft);
 end endgenerate
 assign M_AXI_BREADY=ws==WB;
 assign M_AXI_ARADDR=ra_q,M_AXI_ARLEN=rn-1'b1,M_AXI_ARVALID=rs==RA && rn!=0;
 assign M_AXI_ARID=0,M_AXI_ARSIZE=SHIFT,M_AXI_ARBURST=1,M_AXI_ARLOCK=0;
 assign M_AXI_ARCACHE=3,M_AXI_ARPROT=0,M_AXI_ARQOS=0,M_AXI_ARUSER=0;
 // Cancellation must drain even when the abandoned consumer FIFO is full.
 assign M_AXI_RREADY=rs==RR && (rcancel || MASTER_RST || !RD_FIFO_FULL);
 assign RD_FIFO_WE=M_AXI_RVALID && M_AXI_RREADY && !rcancel && !MASTER_RST;
 assign RD_FIFO_DATA=M_AXI_RDATA;
 assign DEBUG={22'd0,wcancel,rcancel,werr,rerr,ws,1'b0,rs};
 // Purpose: prefetch exactly wn synchronous FIFO words (one-cycle latency),
 // including after FIFO EMPTY asserts on the final pop. RD_LEN is never used
 // by write accounting. Cancellation cannot silently reset a live transaction.
 always @(posedge ACLK or negedge ARESETN) begin
  if(!ARESETN) begin
   ws<=WI;wa_q<=0;wleft<=0;wbytes<=0;wn<=1;popped<=0;captured<=0;windex<=0;
   pop_q<=0;werr<=0;wcancel<=0;
  end else begin
   pop_q<=WR_FIFO_RE;
   if(WR_FIFO_RE) popped<=popped+1'b1;
   if(pop_q) begin buffer[captured]<=WR_FIFO_DATA;captured<=captured+1'b1;end
   if(MASTER_RST && ws!=WI) begin wcancel<=1;werr<=1;end
   case(ws)
    WI: if(WR_START && !MASTER_RST) begin
     wa_q<=WR_ADRS;wleft<=WR_LEN;werr<=0;wcancel<=0;
     if(WR_LEN==0 || WR_ADRS[SHIFT-1:0]!=0 || {1'b0,WR_ADRS}+{1'b0,WR_LEN}>33'h100000000) begin werr<=1;ws<=WE;end
     else begin ws<=WL;wn<=0;popped<=0;captured<=0;windex<=0; end
    end
    WL: begin
     // First WL cycle is setup; loading starts only once wn has been computed.
     if(wn==0) begin
      wn<=planned_w[4:0];wbytes<=(wleft<planned_w*BYTES) ? wleft : planned_w*BYTES;
     end
     if(wcancel || MASTER_RST) ws<=WE;
     else if(wn!=0 && captured==wn && popped==wn && !pop_q) ws<=WA;
    end
    WA: if(M_AXI_AWREADY) ws<=WD;
    WD: if(M_AXI_WVALID && M_AXI_WREADY) begin
     if(windex==wn-1'b1) ws<=WB;else windex<=windex+1'b1;
    end
    WB: if(M_AXI_BVALID && M_AXI_BREADY) begin
     if(M_AXI_BRESP!=0 || M_AXI_BID!=0) werr<=1;
     if(wleft<=wbytes || wcancel || MASTER_RST || M_AXI_BRESP!=0 || M_AXI_BID!=0) ws<=WE;
     else begin
      wa_q<=wa_q+wbytes;wleft<=wleft-wbytes;ws<=WL;
      popped<=0;captured<=0;windex<=0;wn<=0;
     end
    end
    WE: ws<=WI;
    default: begin ws<=WE;werr<=1;end
   endcase
  end
 end
 // Purpose: reserve via RD_FIFO_AFULL before AR; standard AXI read backpressure
 // is honored. Complete only on a consumed LAST, not merely RVALID.
 always @(posedge ACLK or negedge ARESETN) begin
  if(!ARESETN) begin rs<=RI;ra_q<=0;rleft<=0;rn<=1;rindex<=0;rerr<=0;rcancel<=0;end
  else begin
   if(MASTER_RST && rs!=RI) begin rcancel<=1;rerr<=1;end
   case(rs)
    RI: if(RD_START && !MASTER_RST) begin
     ra_q<=RD_ADRS;rleft<=RD_LEN;rn<=0;rindex<=0;rerr<=0;rcancel<=0;
     if(RD_LEN==0 || RD_ADRS[SHIFT-1:0]!=0 || {1'b0,RD_ADRS}+{1'b0,RD_LEN}>33'h100000000) begin rerr<=1;rs<=RE;end
     else rs<=RA;
    end
    RA: begin
     if(rn==0) begin
      if(rcancel || MASTER_RST) rs<=RE;
      else if(!RD_FIFO_AFULL) rn<=planned_r[4:0];
     end else if(M_AXI_ARREADY) begin rs<=RR;rindex<=0;end
    end
    RR: if(M_AXI_RVALID && M_AXI_RREADY) begin
     if(M_AXI_RRESP!=0 || M_AXI_RID!=0 || M_AXI_RLAST!=(rindex==rn-1'b1)) rerr<=1;
     if(M_AXI_RLAST) begin
      if(rleft<=rn*BYTES || rcancel || MASTER_RST || rerr || M_AXI_RRESP!=0 || M_AXI_RID!=0 || rindex!=rn-1'b1) rs<=RE;
      else begin ra_q<=ra_q+rn*BYTES;rleft<=rleft-rn*BYTES;rn<=0;rs<=RA;end
     end else rindex<=rindex+1'b1;
    end
    RE: rs<=RI;
    default: begin rs<=RE;rerr<=1;end
   endcase
  end
 end
endmodule

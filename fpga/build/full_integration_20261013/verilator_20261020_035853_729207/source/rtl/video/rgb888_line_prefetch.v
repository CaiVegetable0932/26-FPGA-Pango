`timescale 1ns/1ps
// Purpose: two complete RGB888 line banks isolate non-stallable scanout from
// variable DDR service. One pixel clock domain; a lossless CDC DMA bridge is
// required at integration. BYTE addresses, 32-byte beats, at most 16 per burst.
// RGB memory order is R,G,B in increasing addresses. No RGB565 conversion.
// H_ACTIVE must be a multiple of 32, stride a multiple of 32 >= H_ACTIVE*3.
// Client completion is the ddr_native_dma done/ACK fence, NOT just r_last.
// abort preserves a stalled request and cancels/drains accepted work. rst_n
// is a joint cold reset with the DMA bridge; mode/PLL changes use abort.
module rgb888_line_prefetch #(
 parameter H_ACTIVE=1920,V_ACTIVE=1080,STRIDE=6144
)(
 input clk,rst_n,start,abort,input [31:0] base,generation,
 input line_prepare,input [11:0] scan_y,input consume,line_end,
 output pixel_valid,output [23:0] pixel,output line_missing,
 output drained,output urgent,output [1:0] ready_lines,
 output reg req_valid,input req_ready,output reg [31:0] req_addr,
 output reg [4:0] req_beats,output reg [31:0] req_tag,
 input r_valid,output r_ready,input [255:0] r_data,input r_last,
 input done,output done_ready,input cancelled,error,input [31:0] done_tag,
 output cancel,output reg fault,
 output reg [31:0] max_no_service_cycles,low_water_cycles
);
 localparam LINE_BEATS=H_ACTIVE*3/32;
 localparam AW=$clog2(LINE_BEATS);
 localparam IDLE=0,REQUEST=1,RECEIVE=2,COMPLETE=3;
 reg [1:0] state;
 reg running,aborting;
 reg [31:0] frame_base,frame_gen,row_addr;
 reg [11:0] fill_y;
 reg [AW:0] fill_beat;
 reg [4:0] received;
 reg [1:0] full;
 reg [11:0] bank_y[0:1];
 reg [255:0] bank0[0:LINE_BEATS-1],bank1[0:LINE_BEATS-1];
 reg scan_bank,scan_ok;
 reg [AW:0] read_index;
 reg ram_pending;
 reg [255:0] ram_data;
 reg [271:0] reservoir,reservoir_next;
 reg [5:0] bytes_q,bytes_next;
 reg [31:0] gap;
 integer burst_length;
 wire beat_take=r_valid && r_ready;
 wire fill_bank=fill_y[0];
 // Request with >=two remaining pixels: RAM data is appended on the following
 // edge, so a 1/2-byte residue alone cannot bridge its synchronous latency.
 wire read_issue=scan_ok && read_index<LINE_BEATS && bytes_q<=8 && !ram_pending;
 assign ready_lines=full;
 assign pixel_valid=scan_ok && bytes_q>=3;
 assign pixel={reservoir[7:0],reservoir[15:8],reservoir[23:16]};
 assign line_missing=line_prepare && (!full[scan_y[0]] || bank_y[scan_y[0]]!=scan_y);
 assign drained=state==IDLE && !req_valid && !ram_pending && !read_issue;
 assign urgent=running && full!=2'b11;
 assign r_ready=state==RECEIVE;
 assign done_ready=state==COMPLETE;
 assign cancel=(abort || aborting || fault) && (state==RECEIVE || state==COMPLETE);
 // Purpose: split at the physical 4096-byte column and row ends. Base/stride
 // alignment keeps bursts legal; padding is never requested or displayed.
 always @* begin
  burst_length=LINE_BEATS-fill_beat;
  if(burst_length>16) burst_length=16;
  if(burst_length>((4096-row_addr[11:0])/32)) burst_length=(4096-row_addr[11:0])/32;
 end
 // Purpose: append synchronous RAM data after removing exactly one RGB triplet.
 // Request at 6/7/8 bytes leaves 0/1/2 bytes when data returns. Three fixed
 // alignments replace the wide variable shifter; 34 bytes is sufficient for
 // a 32-byte beat plus its two-byte residue. Old line bytes clear at boundaries.
 always @* begin
  reservoir_next=reservoir;bytes_next=bytes_q;
  if(consume && pixel_valid) begin reservoir_next=reservoir>>24;bytes_next=bytes_q-3;end
  if(ram_pending && scan_ok && !abort && !aborting) begin
   case(bytes_next)
    0:reservoir_next=reservoir_next | {16'd0,ram_data};
    1:reservoir_next=reservoir_next | {8'd0,ram_data,8'd0};
    2:reservoir_next=reservoir_next | {ram_data,16'd0};
    default:reservoir_next=0; // Impossible healthy state; fault below fails black.
   endcase
   bytes_next=bytes_next+32;
  end
 end
 // Purpose: synchronous RAM read, one-cycle latency, separate from resettable
 // control so native block RAM inference remains possible. No RAM reset loop.
 always @(posedge clk) begin
  if(beat_take && !aborting && !abort && !fault && received<req_beats) begin
   if(fill_bank) bank1[fill_beat+received]<=r_data;
   else bank0[fill_beat+received]<=r_data;
  end
  if(read_issue) ram_data<=scan_bank ? bank1[read_index[AW-1:0]] : bank0[read_index[AW-1:0]];
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=IDLE;running<=0;aborting<=0;frame_base<=0;frame_gen<=0;row_addr<=0;
   fill_y<=0;fill_beat<=0;received<=0;full<=0;bank_y[0]<=0;bank_y[1]<=0;
   req_valid<=0;req_addr<=0;req_beats<=0;req_tag<=0;fault<=0;
   scan_bank<=0;scan_ok<=0;read_index<=0;ram_pending<=0;reservoir<=0;bytes_q<=0;
   gap<=0;max_no_service_cycles<=0;low_water_cycles<=0;
  end else begin
   ram_pending<=read_issue;
   reservoir<=reservoir_next;bytes_q<=bytes_next;
   if(read_issue) read_index<=read_index+1'b1;
   // A violated residue invariant must never silently shift future pixels.
   if(ram_pending && scan_ok && !abort && !aborting &&
      bytes_q>((consume && pixel_valid)?6'd5:6'd2))fault<=1;
   if(line_prepare) begin
    scan_bank<=scan_y[0];scan_ok<=!line_missing && running && !abort && !fault;
    read_index<=0;ram_pending<=0;reservoir<=0;bytes_q<=0;
   end
   if(line_end) begin full[scan_bank]<=0;scan_ok<=0;ram_pending<=0;reservoir<=0;bytes_q<=0;end
   if(urgent && low_water_cycles!=32'hffffffff) low_water_cycles<=low_water_cycles+1'b1;
   // Measure demand-to-response gaps, including request and done fences.
   if(running && !full[fill_bank] && fill_y<V_ACTIVE && !aborting) begin
    if(beat_take) gap<=0;
    else if(gap!=32'hffffffff) gap<=gap+1'b1;
    if(gap>max_no_service_cycles) max_no_service_cycles<=gap;
   end else gap<=0;
   if(abort) begin running<=0;aborting<=1;scan_ok<=0;full<=0;end
   // Frame restart is legal only after the old completion fence is ACKed.
   if(start && drained) begin
    running<=1;aborting<=0;fault<=0;frame_base<=base;frame_gen<=generation;
    row_addr<=base;fill_y<=0;fill_beat<=0;full<=0;scan_ok<=0;
    read_index<=0;ram_pending<=0;reservoir<=0;bytes_q<=0;gap<=0;
   end else case(state)
    IDLE: if(running && !abort && !aborting && !fault && fill_y<V_ACTIVE && !full[fill_bank]) begin
     req_addr<=row_addr;req_beats<=burst_length;req_tag<=frame_gen;
     req_valid<=1;state<=REQUEST;
    end
    // A stalled VALID is never withdrawn during abort/lock loss.
    REQUEST: if(req_ready) begin req_valid<=0;received<=0;state<=RECEIVE;end
    RECEIVE: begin
     if(beat_take) begin
      received<=received+1'b1;
      if(r_last!=(received==req_beats-1'b1)) fault<=1;
     end
     // A cancelled/errored DMA can complete without returning client beats.
     if(done) state<=COMPLETE;
    end
    COMPLETE: if(done) begin
     state<=IDLE;
     if(error || (!aborting && !abort && (cancelled || received!=req_beats || done_tag!=frame_gen))) begin
      fault<=1;running<=0;
     end
     if(!abort && !aborting && !fault && !error && !cancelled && received==req_beats && done_tag==frame_gen) begin
      if(fill_beat+req_beats==LINE_BEATS) begin
       full[fill_bank]<=1;bank_y[fill_bank]<=fill_y;fill_y<=fill_y+1'b1;fill_beat<=0;
       row_addr<=frame_base+(fill_y+1'b1)*STRIDE;
      end else begin fill_beat<=fill_beat+req_beats;row_addr<=row_addr+({27'd0,req_beats}<<5);end
     end
    end
   endcase
  end
 end
endmodule

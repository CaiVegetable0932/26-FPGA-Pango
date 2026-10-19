`timescale 1ns/1ps
// Purpose: plan only effective row bytes; preserve independent byte stride.
// Split aligned bus spans at native 1024-column boundaries and MAX_BEATS.
// Reject descriptors whose rounded bus span exceeds slot/capacity bounds.
module dma_row_plan #(
 parameter MAX_BEATS=16, parameter [31:0] CAPACITY_BYTES=32'h40000000
)(
 input clk,input rst_n,input start_valid,output start_ready,
 input [31:0] base_addr,input [31:0] row_bytes,input [31:0] stride,
 input [15:0] rows,input [31:0] slot_begin,input [31:0] slot_end,
 output req_valid,input req_ready,output [31:0] req_addr,output [4:0] req_beats,
 output [4:0] row_offset,output [31:0] effective_row_bytes,
 output row_first,output row_last,output frame_last,output reg done,output reg error
);
 reg active;
 reg [31:0] row_addr,burst_addr,remaining,saved_bytes,saved_stride;
 reg [15:0] rows_left;
 reg first;
 reg [31:0] selected_beats;
 wire [63:0] last_byte={32'd0,base_addr}+(rows-16'd1)*{32'd0,stride}+{32'd0,row_bytes};
 wire [63:0] rounded_end=(last_byte+31)&64'hffffffffffffffe0;
 wire [31:0] aligned_base=base_addr & 32'hffffffe0;
 assign start_ready=!active;
 assign req_valid=active;
 assign req_addr=burst_addr,req_beats=selected_beats[4:0];
 assign row_offset=row_addr[4:0],effective_row_bytes=saved_bytes;
 assign row_first=first,row_last=remaining==selected_beats;
 assign frame_last=row_last && rows_left==1;
 // Purpose: selection is stable under backpressure. Each request is at most
 // 16 beats and cannot invoke the native column-address wrap behavior.
 always @* begin
  selected_beats=remaining;
  if(selected_beats>MAX_BEATS) selected_beats=MAX_BEATS;
  if(selected_beats>((4096-{20'd0,burst_addr[11:0]})>>5))
   selected_beats=(4096-{20'd0,burst_addr[11:0]})>>5;
 end
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   active<=0; row_addr<=0; burst_addr<=0; remaining<=0; saved_bytes<=0;
   saved_stride<=0; rows_left<=0; first<=0; done<=0; error<=0;
  end else begin
   done<=0;
   if(start_valid && start_ready) begin
    error<=0;
    if(rows==0 || row_bytes==0 || stride<row_bytes || slot_begin[4:0]!=0 || slot_end[4:0]!=0 ||
       aligned_base<slot_begin || rounded_end>{32'd0,slot_end} ||
       rounded_end>{32'd0,CAPACITY_BYTES}) begin done<=1; error<=1; end
    else begin
     active<=1; row_addr<=base_addr; burst_addr<=aligned_base;
     remaining<=({27'd0,base_addr[4:0]}+row_bytes+31)>>5;
     saved_bytes<=row_bytes; saved_stride<=stride; rows_left<=rows; first<=1;
    end
   end
   if(req_valid && req_ready) begin
    if(row_last) begin
     if(rows_left==1) begin active<=0; done<=1; end
     else begin
      row_addr<=row_addr+saved_stride;
      burst_addr<=(row_addr+saved_stride)&32'hffffffe0;
      remaining<=(((row_addr+saved_stride)&31)+saved_bytes+31)>>5;
      rows_left<=rows_left-1'b1; first<=1;
     end
    end else begin burst_addr<=burst_addr+(selected_beats<<5); remaining<=remaining-selected_beats; first<=0; end
   end
  end
 end
endmodule

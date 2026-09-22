// Purpose: packet-preserving GMII bridge from HMIC to an independent Ethernet
// PLL. Pack 32 bytes per native 288-bit FIFO record; never backpressure GMII.
// Publish an end-record counter only after FIFO acceptance. The reader waits
// for a complete packet before asserting TX_EN, then emits one byte per clock.
module raw8_gmii_cdc(
 input wire wr_clk,wr_reset_n,input wire [7:0] in_data,input wire in_en,in_error,
 input wire rd_clk,rd_reset_n,output reg [7:0] out_data,output reg out_en,out_error,
 output reg wr_fault,rd_fault
);
 reg [255:0] assembly;reg [5:0] byte_count;
 reg [287:0] record_in;reg record_valid;wire record_ready;
 wire [287:0] record_out;wire record_out_valid,record_out_ready;
 reg [15:0] written_packets,written_gray;
 wire [15:0] next_written=written_packets+16'd1;
 raw8_native_queue #(.WIDTH(288)) u_queue(
  .wr_clk(wr_clk),.wr_reset_n(wr_reset_n),.in_data(record_in),
  .in_valid(record_valid),.in_ready(record_ready),.wr_used(),
  .rd_clk(rd_clk),.rd_reset_n(rd_reset_n),.out_data(record_out),
  .out_valid(record_out_valid),.out_ready(record_out_ready));
 // Hold a full word until the NEXT byte or TX_EN falling edge distinguishes
 // continuation from end-of-packet. Exact multiples of 32 need no empty record.
 always @(posedge wr_clk or negedge wr_reset_n)
  if(!wr_reset_n)begin assembly<=0;byte_count<=0;record_in<=0;record_valid<=0;
   written_packets<=0;written_gray<=0;wr_fault<=0;end
  else begin
   record_valid<=0;
   if(record_valid && !record_ready)wr_fault<=1;
   if(record_valid && record_ready && record_in[262])begin
    written_packets<=next_written;written_gray<=next_written^(next_written>>1);
   end
   if(!wr_fault && !(record_valid && !record_ready))begin
    if(in_en && in_error)wr_fault<=1;
    else if(in_en)begin
     if(byte_count==32)begin
      record_in<={25'b0,1'b0,6'd32,assembly};record_valid<=1;
      assembly<={248'b0,in_data};byte_count<=1;
     end else begin assembly[byte_count*8+:8]<=in_data;byte_count<=byte_count+1'b1;end
    end else if(byte_count!=0)begin
     record_in<={25'b0,1'b1,byte_count,assembly};record_valid<=1;
     byte_count<=0;assembly<=0;
    end
   end
  end
 // Only Gray completion metadata crosses outside the native FIFO. Both reset
 // inputs must assert together on either PLL loss; release is domain-local.
 (* syn_preserve=1 *) reg [15:0] done_meta,done_sync;
 reg [15:0] read_packets;
 wire [15:0] read_gray=read_packets^(read_packets>>1);
 reg [287:0] next_record,head;reg next_valid;
 reg [4:0] byte_index;reg [3:0] gap;reg [1:0] state;
 assign record_out_ready=!next_valid && !rd_fault;
 always @(posedge rd_clk or negedge rd_reset_n)
  if(!rd_reset_n)begin done_meta<=0;done_sync<=0;read_packets<=0;
   next_record<=0;head<=0;next_valid<=0;byte_index<=0;gap<=0;state<=0;
   out_data<=0;out_en<=0;out_error<=0;rd_fault<=0;end
  else begin
   done_meta<=written_gray;done_sync<=done_meta;out_en<=0;out_error<=0;
   if(record_out_valid && record_out_ready)begin next_record<=record_out;next_valid<=1;end
   case(state)
    0:if(done_sync!=read_gray && next_valid && !rd_fault)begin
     if(next_record[261:256]==0 || next_record[261:256]>32 ||
        (!next_record[262] && next_record[261:256]!=32))begin rd_fault<=1;state<=3;end
     else begin head<=next_record;next_valid<=0;byte_index<=0;state<=1;end
    end
    1:begin
     out_data<=head[byte_index*8+:8];out_en<=1;
     if({1'b0,byte_index}+6'd1==head[261:256])begin
      if(head[262])begin read_packets<=read_packets+1'b1;gap<=12;state<=2;end
      else if(next_valid && next_record[261:256]!=0 && next_record[261:256]<=32 &&
              (next_record[262] || next_record[261:256]==32))begin
       head<=next_record;next_valid<=0;byte_index<=0;
      end else begin rd_fault<=1;out_error<=1;state<=3;end
     end else byte_index<=byte_index+1'b1;
    end
    // At least twelve idle byte times; extra idle is legal, a mid-packet gap is not.
    2:if(gap==1)begin gap<=0;state<=0;end else gap<=gap-1'b1;
    default:begin out_en<=0;end
   endcase
  end
endmodule

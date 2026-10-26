`timescale 1ns/1ps
// Copy a same-source S1/result pair through ONE shared native client. Reads
// and verified writes never overlap. Source references remain held until done
// after every completion ACK. Padding bytes have no write strobe.
module snapshot_copy_dma #(parameter WIDTH=1920,HEIGHT=1080)(
 input clk,rst_n,start,output ready,input cancel,
 input [1:0] source_slot,result_slot,input [31:0] source_gen,result_gen,s1_gen,dst_gen,
 output reg done,failed,output drained,
 output req_valid,input req_ready,output req_write,output [31:0] req_addr,req_tag,
 output [2:0] req_bank,req_owner,output [1:0] req_slot,output [31:0] req_generation,
 output w_valid,input w_ready,output [255:0] w_data,output [31:0] w_strb,
 input r_valid,output r_ready,input [255:0] r_data,
 input dma_done,output dma_done_ready,input dma_error,dma_cancelled,input [31:0] done_tag,output dma_cancel
);
 localparam IDLE=0,READ_REQ=1,READ_WAIT=2,WRITE_REQ=3,WRITE_WAIT=4;
 reg [2:0] state;reg image,aborting,received,sent;
 reg [15:0] row;reg [31:0] column;
 reg [1:0] ss,rs;reg [31:0] sg,rg,dsg,drg;reg [255:0] buffer;
 wire writing=state==WRITE_REQ || state==WRITE_WAIT;
 wire [31:0] offset=row*32'd6144+column;
 wire [31:0] read_base=image ? (32'h01800000+{7'd0,rs,23'd0}):{7'd0,ss,23'd0};
 wire [31:0] write_base=image?32'h04400000:32'h03c00000;
 assign ready=state==IDLE,drained=state==IDLE;
 assign req_valid=(state==READ_REQ || state==WRITE_REQ) && !cancel && !aborting;
 assign req_write=writing,req_addr=(writing?write_base:read_base)+offset;
 assign req_bank=writing?(image?3'd4:3'd3):(image?3'd1:3'd0);
 assign req_owner=writing?3'd0:3'd4,req_slot=writing?2'd0:(image?rs:ss);
 assign req_generation=writing?(image?drg:dsg):(image?rg:sg),req_tag=req_generation;
 assign w_valid=state==WRITE_WAIT && !sent && !cancel && !aborting,w_data=buffer;
 assign w_strb=(column+32<=WIDTH*3)?32'hffffffff:(32'hffffffff>>(32-(WIDTH*3-column)));
 assign r_ready=state==READ_WAIT,dma_done_ready=state==READ_WAIT || state==WRITE_WAIT;
 assign dma_cancel=cancel || aborting;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;image<=0;aborting<=0;received<=0;sent<=0;row<=0;column<=0;
   ss<=0;rs<=0;sg<=0;rg<=0;dsg<=0;drg<=0;buffer<=0;done<=0;failed<=0;end
  else begin
   done<=0;
   if(start && ready)begin ss<=source_slot;rs<=result_slot;sg<=source_gen;rg<=result_gen;dsg<=s1_gen;drg<=dst_gen;
    image<=0;row<=0;column<=0;aborting<=0;failed<=0;received<=0;sent<=0;state<=READ_REQ;end
   if(state!=IDLE && cancel)begin aborting<=1;failed<=1;end
   if(r_valid && r_ready)begin buffer<=r_data;received<=1;end
   if(w_valid && w_ready)sent<=1;
   case(state)
    READ_REQ,WRITE_REQ:begin
     if(cancel || aborting)begin state<=IDLE;done<=1;end
     else if(req_ready)begin received<=0;sent<=0;state<=writing?WRITE_WAIT:READ_WAIT;end
    end
    READ_WAIT,WRITE_WAIT:if(dma_done)begin
     if(cancel || aborting || dma_error || dma_cancelled || done_tag!=req_tag ||
        (!writing && !received && !(r_valid && r_ready)) || (writing && !sent && !(w_valid && w_ready)))begin
      failed<=1;state<=IDLE;done<=1;
     end else if(!writing)state<=WRITE_REQ;
     else if(column+32<WIDTH*3)begin column<=column+32;state<=READ_REQ;end
     else if(row<HEIGHT-1)begin column<=0;row<=row+1'b1;state<=READ_REQ;end
     else if(!image)begin image<=1;column<=0;row<=0;state<=READ_REQ;end
     else begin state<=IDLE;done<=1;end
    end
   endcase
  end
 end
endmodule

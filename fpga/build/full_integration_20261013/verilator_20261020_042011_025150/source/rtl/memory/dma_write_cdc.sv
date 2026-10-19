`timescale 1ns/1ps
// Experimental, not instantiated by production. One transaction at a time.
// Collect a complete client burst before issuing its immutable DDR request.
// Data/strobes stay in dual-clock RAM until the native completion is drained.
// Both resets MUST assert together with the native controller, and release
// synchronously in their own domains. Held buses need bounded-data constraints.
module dma_write_cdc(
 input client_clk,client_rst_n,input req_valid,output req_ready,
 input [31:0] req_addr,req_tag,input [4:0] req_beats,input cancel,
 input w_valid,output w_ready,input [255:0] w_data,input [31:0] w_strb,
 output done,input done_ready,output reg error,cancelled,output reg [31:0] done_tag,
 input memory_clk,memory_rst_n,
 output memory_req_valid,input memory_req_ready,output reg [31:0] memory_req_addr,memory_req_tag,
 output reg [4:0] memory_req_beats,output memory_cancel,
 output memory_w_valid,input memory_w_ready,output [255:0] memory_w_data,output [31:0] memory_w_strb,
 input memory_done,output memory_done_ready,input memory_error,memory_cancelled,input [31:0] memory_done_tag
);
 localparam C_IDLE=0,C_COLLECT=1,C_WAIT=2,C_DONE=3;
 localparam M_IDLE=0,M_REQUEST=1,M_LOAD=2,M_SEND=3,M_WAIT=4,M_ACK=5;
 reg [1:0] cstate;reg [2:0] mstate;
 reg request_toggle,free_toggle,cancel_held,memory_issued;
 reg [68:0] descriptor_held;reg [4:0] client_count,client_beats,read_index;
 reg response_toggle;reg [33:0] status_held;
 (* syn_preserve=1 *) reg request_meta,request_sync,free_meta,free_sync,cancel_meta,cancel_sync;
 (* syn_preserve=1 *) reg response_meta,response_sync;
 reg [287:0] payload[0:15] /* synthesis syn_ramstyle="block_ram" */;
 reg [287:0] read_q;
 assign req_ready=cstate==C_IDLE;
 assign w_ready=cstate==C_COLLECT && !cancel && !cancel_held && client_count<client_beats;
 assign done=cstate==C_DONE;
 assign memory_req_valid=mstate==M_REQUEST;
 assign memory_w_valid=mstate==M_SEND && !cancel_sync;
 assign memory_w_data=read_q[287:32],memory_w_strb=read_q[31:0];
 assign memory_done_ready=mstate==M_LOAD || mstate==M_SEND || mstate==M_WAIT;
 assign memory_cancel=memory_done_ready && cancel_sync;
 wire [5:0] sent_after={1'b0,read_index}+(memory_w_valid && memory_w_ready);
 // No read/write collision: the request toggle follows the LAST RAM write;
 // the next client collection follows completion, consumption and free ACK.
 always @(posedge client_clk)
  if(w_valid && w_ready)payload[client_count[3:0]]<={w_data,w_strb};
 // Prefetch after every accepted beat; hold the registered beat under stalls.
 always @(posedge memory_clk)
  if(mstate==M_LOAD)read_q<=payload[0];
  else if(memory_w_valid && memory_w_ready && read_index+1'b1<memory_req_beats)
   read_q<=payload[read_index[3:0]+1'b1];
 always @(posedge client_clk or negedge client_rst_n)begin
  if(!client_rst_n)begin
   cstate<=C_IDLE;request_toggle<=0;free_toggle<=0;cancel_held<=0;memory_issued<=0;
   descriptor_held<=0;client_count<=0;client_beats<=0;
   response_meta<=0;response_sync<=0;error<=0;cancelled<=0;done_tag<=0;
  end else begin
   response_meta<=response_toggle;response_sync<=response_meta;
   if(cstate==C_COLLECT || cstate==C_WAIT)if(cancel)cancel_held<=1;
   case(cstate)
    C_IDLE:if(req_valid)begin
     descriptor_held<={req_tag,req_addr,req_beats};client_beats<=req_beats;client_count<=0;
     cancel_held<=cancel;memory_issued<=0;error<=0;cancelled<=0;done_tag<=req_tag;
     if(req_beats==0 || req_beats>16)begin error<=1;cstate<=C_DONE;end
     else if(cancel)begin cancelled<=1;cstate<=C_DONE;end
     else cstate<=C_COLLECT;
    end
    C_COLLECT:begin
     // No native transaction exists yet, so cancellation drains locally.
     if(cancel || cancel_held)begin cancelled<=1;cstate<=C_DONE;end
     else if(w_valid && w_ready)begin
      client_count<=client_count+1'b1;
      if(client_count+1'b1==client_beats)begin
       request_toggle<=!request_toggle;memory_issued<=1;cstate<=C_WAIT;
      end
     end
    end
    C_WAIT:if(response_sync==request_toggle)begin
     done_tag<=status_held[33:2];error<=status_held[1];
     cancelled<=status_held[0] || cancel_held || cancel;cstate<=C_DONE;
    end
    C_DONE:if(done_ready)begin
     if(memory_issued)free_toggle<=request_toggle;
     cstate<=C_IDLE;
    end
   endcase
  end
 end
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin
   mstate<=M_IDLE;request_meta<=0;request_sync<=0;free_meta<=0;free_sync<=0;
   cancel_meta<=0;cancel_sync<=0;response_toggle<=0;status_held<=0;
   memory_req_addr<=0;memory_req_tag<=0;memory_req_beats<=0;read_index<=0;
  end else begin
   request_meta<=request_toggle;request_sync<=request_meta;
   free_meta<=free_toggle;free_sync<=free_meta;cancel_meta<=cancel_held;cancel_sync<=cancel_meta;
   case(mstate)
    M_IDLE:if(request_sync!=response_toggle)begin
     {memory_req_tag,memory_req_addr,memory_req_beats}<=descriptor_held;
     read_index<=0;mstate<=M_REQUEST;
    end
    // Never withdraw an already presented request because of cancellation.
    M_REQUEST:if(memory_req_ready)mstate<=M_LOAD;
    M_LOAD:mstate<=cancel_sync ? M_WAIT:M_SEND;
    M_SEND:if(cancel_sync)mstate<=M_WAIT;
     else if(memory_w_valid && memory_w_ready)begin
      read_index<=read_index+1'b1;
      if(read_index+1'b1==memory_req_beats)mstate<=M_WAIT;
     end
    M_ACK:if(free_sync==response_toggle)mstate<=M_IDLE;
   endcase
   // Native errors/cancellation may complete before all data beats. A normal
   // completion must match both the immutable tag and the full accepted count.
   if(memory_done && memory_done_ready)begin
    status_held<={memory_done_tag,
     (memory_error || memory_done_tag!=memory_req_tag ||
      (!memory_cancelled && sent_after!={1'b0,memory_req_beats})),memory_cancelled};
    response_toggle<=request_sync;mstate<=M_ACK;
   end
  end
 end
endmodule

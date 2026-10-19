`timescale 1ns/1ps
// Purpose: lossless one-transaction read bridge between a video/processing
// client clock and the DDR fabric clock. Full descriptor/status buses remain
// frozen behind toggle handshakes; a dual-clock RAM holds up to 16 read beats.
// The RAM is never read while being written. Both resets MUST assert together
// with the native controller; each reset releases synchronously in its domain.
// Held buses need bundled-data max-delay constraints and synchronizer review.
module dma_read_cdc_prefetch(
 input client_clk,client_rst_n,input req_valid,output req_ready,
 input [31:0] req_addr,req_tag,input [4:0] req_beats,input cancel,
 output r_valid,input r_ready,output [255:0] r_data,output r_last,
 output done,input done_ready,output reg error,cancelled,output reg [31:0] done_tag,
 input memory_clk,memory_rst_n,
 output memory_req_valid,input memory_req_ready,output reg [31:0] memory_req_addr,memory_req_tag,
 output reg [4:0] memory_req_beats,output memory_cancel,
 input memory_r_valid,output memory_r_ready,input [255:0] memory_r_data,input memory_r_last,
 input memory_done,output memory_done_ready,input memory_error,memory_cancelled,input [31:0] memory_done_tag
);
 localparam C_IDLE=0,C_WAIT=1,C_LOAD=2,C_OUTPUT=3,C_DONE=4,C_CAPTURED=5;
 localparam M_IDLE=0,M_REQUEST=1,M_READ=2,M_ACK=3;
 reg [2:0] cstate;reg [1:0] mstate;
 reg request_toggle,free_toggle,cancel_held;
 reg [68:0] descriptor_held;
 reg response_toggle;reg [38:0] status_held;
 (* syn_preserve=1 *) reg request_meta,request_sync,free_meta,free_sync,cancel_meta,cancel_sync;
 (* syn_preserve=1 *) reg response_meta,response_sync;
 reg [4:0] write_count,read_index,read_count;
 reg last_failed;
 reg [255:0] read_q;
 reg [255:0] payload[0:15] /* synthesis syn_ramstyle="block_ram" */;
 assign req_ready=cstate==C_IDLE;
 assign r_valid=cstate==C_OUTPUT && !cancel_held && !cancel;
 assign r_data=read_q,r_last=read_index==read_count-1'b1;
 assign done=cstate==C_DONE;
 assign memory_req_valid=mstate==M_REQUEST;
 assign memory_r_ready=mstate==M_READ && write_count<16;
 assign memory_done_ready=mstate==M_READ;
 assign memory_cancel=mstate==M_READ && cancel_sync;
 // Two independent RAM ports infer native simple dual-port storage. The held
 // response toggle crosses only AFTER every write and the native drain ACK.
 always @(posedge memory_clk)if(memory_r_valid && memory_r_ready)payload[write_count[3:0]]<=memory_r_data;
 // The complete burst is immutable before client delivery. Read the
 // following word on the same edge that accepts the current registered word;
 // a stalled consumer retains read_q and its index, with no RAM collision.
 always @(posedge client_clk)
  if(cstate==C_LOAD)read_q<=payload[read_index[3:0]];
  else if(r_valid && r_ready && !r_last)read_q<=payload[read_index[3:0]+1'b1];
 always @(posedge memory_clk or negedge memory_rst_n)begin
  if(!memory_rst_n)begin
   mstate<=M_IDLE;request_meta<=0;request_sync<=0;free_meta<=0;free_sync<=0;cancel_meta<=0;cancel_sync<=0;
   response_toggle<=0;status_held<=0;memory_req_addr<=0;memory_req_tag<=0;memory_req_beats<=0;
   write_count<=0;last_failed<=0;
  end else begin
   request_meta<=request_toggle;request_sync<=request_meta;
   free_meta<=free_toggle;free_sync<=free_meta;cancel_meta<=cancel_held;cancel_sync<=cancel_meta;
   case(mstate)
    M_IDLE:if(request_sync!=response_toggle)begin
     {memory_req_tag,memory_req_addr,memory_req_beats}<=descriptor_held;
     write_count<=0;last_failed<=0;mstate<=M_REQUEST;
    end
    M_REQUEST:if(memory_req_ready)mstate<=M_READ;
    M_READ:begin
     if(memory_r_valid && memory_r_ready)begin
      write_count<=write_count+1'b1;
      if(memory_r_last!=(write_count==memory_req_beats-1'b1))last_failed<=1;
     end
     if(memory_done)begin
      // Error/cancel status skips payload; successful status requires exactly
      // the requested beat count and a matching immutable request tag.
      status_held<={memory_done_tag,
       memory_error || last_failed || memory_done_tag!=memory_req_tag ||
        (memory_r_valid && memory_r_ready && memory_r_last!=(write_count==memory_req_beats-1'b1)) ||
        (!memory_cancelled && !cancel_sync && write_count+(memory_r_valid&&memory_r_ready)!=memory_req_beats),
       memory_cancelled || cancel_sync,write_count+(memory_r_valid&&memory_r_ready)};
      response_toggle<=request_sync;mstate<=M_ACK;
     end
    end
    M_ACK:if(free_sync==response_toggle)mstate<=M_IDLE;
   endcase
  end
 end
 always @(posedge client_clk or negedge client_rst_n)begin
  if(!client_rst_n)begin
   cstate<=C_IDLE;request_toggle<=0;free_toggle<=0;cancel_held<=0;descriptor_held<=0;
   response_meta<=0;response_sync<=0;read_index<=0;read_count<=0;error<=0;cancelled<=0;done_tag<=0;
  end else begin
   response_meta<=response_toggle;response_sync<=response_meta;
   if(cancel && cstate!=C_IDLE)cancel_held<=1;
   case(cstate)
    C_IDLE:if(req_valid)begin
     descriptor_held<={req_tag,req_addr,req_beats};request_toggle<=!request_toggle;
     cancel_held<=cancel;error<=0;cancelled<=0;read_index<=0;cstate<=C_WAIT;
    end
    C_WAIT:if(response_sync==request_toggle)begin
     {done_tag,error,cancelled,read_count}<=status_held;
     cstate<=C_CAPTURED;
    end
    C_CAPTURED:begin
     // Decode only the captured client-domain status. The held memory bus
     // cannot extend through the client's state/ready combinational paths.
     if(error || cancelled || cancel_held || cancel || read_count==0)begin
      cancelled<=cancelled || cancel_held || cancel;cstate<=C_DONE;
     end else cstate<=C_LOAD;
    end
    C_LOAD:if(cancel_held || cancel)begin cancelled<=1;cstate<=C_DONE;end else cstate<=C_OUTPUT;
    C_OUTPUT:begin
     if(cancel_held || cancel)begin cancelled<=1;cstate<=C_DONE;end
     else if(r_ready)begin
      if(r_last)cstate<=C_DONE;
      else begin read_index<=read_index+1'b1;cstate<=C_OUTPUT;end
     end
    end
    C_DONE:if(done_ready)begin free_toggle<=request_toggle;cancel_held<=0;cstate<=C_IDLE;end
   endcase
  end
 end
endmodule

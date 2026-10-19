`timescale 1ns/1ps
`include "frame_manager_layout.vh"
// Purpose: actual section 03/04 integration in the DDR user clock domain.
// Each accepted client request obtains a frame token BEFORE native admission.
// A token retires only after read consumption or full masked write readback.
// Runtime cold reset must also reset the native controller and all CDC clients.
// No CDC, camera/geometry scheduling or external protocol is implied here.
module frame_memory_fabric #(parameter N=7, parameter BANK_TXNS=8, parameter CAPACITY_BYTES=32'h40000000)(
 input clk,rst_n,controller_ready,display_boundary,allow_snapshot,
 // Scheduler owns alloc/seal/cancel/acquire/release/skip, this fabric exclusively
 // owns issue/complete. Descriptors and all ownership operations are atomic.
 input [5*`FM_CMD_BITS-1:0] frame_command,
 output [5*`FM_RSP_BITS-1:0] frame_response,
 input [N-1:0] req_valid,output reg [N-1:0] req_ready,
 input [N-1:0] req_write,input [N*32-1:0] req_addr,req_tag,
 input [N*5-1:0] req_beats,input [N*3-1:0] req_bank,req_owner,
 input [N*2-1:0] req_slot,input [N*32-1:0] req_generation,
 input [N-1:0] urgent,cancel,w_valid,output [N-1:0] w_ready,
 input [N*256-1:0] w_data,input [N*32-1:0] w_strb,
 output [N-1:0] r_valid,input [N-1:0] r_ready,
 output [N*256-1:0] r_data,output [N-1:0] r_last,
 output [N-1:0] done,input [N-1:0] done_ready,
 output reg [N-1:0] error,cancelled,output [N*32-1:0] done_tag,
 output fault,
 output [27:0] awaddr,araddr,output [3:0] awlen,arlen,awid,arid,
 output awvalid,arvalid,input awready,arready,
 output [255:0] native_wdata,output [31:0] native_wstrb,
 input native_wready,native_wlast,input [3:0] native_wid,
 input [255:0] native_rdata,input native_rvalid,native_rlast,input [3:0] native_rid,
 output [N*32-1:0] bus_bytes,max_wait_cycles,useful_write_bytes
);
 localparam FREE=0,ADMIT=1,SUBMIT=2,WAIT_DRAIN=3,REPLY=4;
 reg [2:0] state[0:N-1];
 reg [2:0] bank[0:N-1],token[0:N-1],owner_saved[0:N-1];
 reg [1:0] slot_saved[0:N-1];
 reg [31:0] generation_saved[0:N-1];
 reg [63:0] ticket[0:N-1];
 reg [N*32-1:0] addr_saved,tag_saved;
 reg [N*5-1:0] beats_saved;
 reg [N-1:0] write_saved,cancel_saved;
 wire [N-1:0] dma_ready,dma_done,dma_error,dma_cancelled,verified,dma_cancel_request;
 reg [N-1:0] dma_req,dma_done_ready;
 wire [N*32-1:0] dma_tag;
 wire dma_fault;
 reg logic_fault;
 reg [5*`FM_CMD_BITS-1:0] commands;
 wire [5*`FM_RSP_BITS-1:0] responses;
 wire [14:0] issue_tokens;
 wire [319:0] issue_tickets;
 integer issue_choice[0:4],complete_choice[0:4];
 reg [2:0] rr_issue[0:4],rr_complete[0:4];
 // Register the selected bank command before evaluating slot generation/
 // consumer ownership. The client remains ADMIT until that held command is
 // accepted or rejected, so no token can be issued twice or lost on cancel.
 reg admit_valid[0:4];reg [2:0] admit_client[0:4],admit_owner[0:4];
 reg [1:0] admit_slot[0:4];reg [31:0] admit_generation[0:4];
 // Bank acceptance is an atomic commit edge. Keep its outcome/token/ticket
 // in a bank-local register before client-state and descriptor muxes consume
 // it; the selected client stays ADMIT until this held outcome is delivered.
 reg admit_result_valid[0:4],admit_result_rejected[0:4];
 reg [2:0] admit_result_client[0:4],admit_result_token[0:4];
 reg [63:0] admit_result_ticket[0:4];
 // Retire selection and its 64-bit completion descriptor are registered on
 // separate edges. Adapter done remains held until the final frame-bank ACK;
 // no completion/owner bypass is introduced by these arbitration stages.
 reg [1:0] retire_stage[0:4];reg [2:0] retire_client[0:4],retire_token[0:4];
 reg [63:0] retire_ticket[0:4];reg retire_error[0:4];
 reg retire_ack[0:4];
 wire [14:0] committed_tokens;
 wire [319:0] committed_tickets;
 integer b,c,k,off;
 reg [N-1:0] address_legal,ownership_granted,ownership_rejected;
 reg [32:0] slot_base,slot_end,span_end;
 reg [31:0] slot_bytes;
 assign frame_response=responses;
 assign fault=dma_fault || logic_fault;
 assign done_tag=tag_saved;
 genvar g;
 generate for(g=0;g<N;g=g+1) begin: client_status
  assign done[g]=state[g]==REPLY;
  // Cancellation applies only after native admission; an early client abort
  // is held until that point and cannot collide with a new descriptor edge.
  assign dma_cancel_request[g]=state[g]==WAIT_DRAIN && (cancel[g] || cancel_saved[g]);
 end endgenerate
 // Select from compact 3-bit token / 64-bit ticket banks, not the entire wide metadata
 // response bus. This avoids a huge dynamic slice during native ADS inference.
 generate for(g=0;g<5;g=g+1) begin: response_fields
  assign issue_tokens[g*3+:3]=responses[g*`FM_RSP_BITS+`FM_RSP_ISSUE_TOKEN];
  assign issue_tickets[g*64+:64]=responses[g*`FM_RSP_BITS+`FM_RSP_ISSUE_TICKET];
  assign committed_tokens[g*3+:3]=admit_result_token[g];
  assign committed_tickets[g*64+:64]=admit_result_ticket[g];
 end endgenerate

 // Requests cannot address another frame, even if a caller supplies a valid
 // token owner. Checks use 33-bit sums to reject overflow and padding overrun.
 // Invalid descriptors produce a bounded local error without issuing a token.
 always @* begin
  address_legal=0;slot_base=0;slot_end=0;span_end=0;slot_bytes=0;
  for(c=0;c<N;c=c+1) begin
   slot_bytes=req_bank[c*3+:3]==2 ? 32'h00400000 : 32'h00800000;
   case(req_bank[c*3+:3])
    0:slot_base=0;
    1:slot_base=33'h01800000;
    2:slot_base=33'h03000000;
    3:slot_base=33'h03c00000;
    4:slot_base=33'h04400000;
    default:slot_base=33'h100000000;
   endcase
   // Slot sizes are exact powers of two. Express the offsets as wiring so
   // synthesis does not create seven wide run-time multipliers for bounds.
   if(req_bank[c*3+:3]==2)slot_base=slot_base+{9'd0,req_slot[c*2+:2],22'd0};
   else slot_base=slot_base+{8'd0,req_slot[c*2+:2],23'd0};
   slot_end=slot_base+slot_bytes;
   span_end={1'b0,req_addr[c*32+:32]}+({28'd0,req_beats[c*5+:5]}<<5);
   address_legal[c]=req_bank[c*3+:3]<5 &&
    req_slot[c*2+:2]<(req_bank[c*3+:3]>=3 ? 1:3) &&
    req_owner[c*3+:3]<=4 && (req_write[c] ? req_owner[c*3+:3]==0 : req_owner[c*3+:3]!=0) &&
    req_beats[c*5+:5]!=0 && req_beats[c*5+:5]<=16 && req_addr[c*32+:5]==0 &&
    {1'b0,req_addr[c*32+:32]}>=slot_base && span_end<=slot_end && span_end<=CAPACITY_BYTES &&
    ({1'b0,req_addr[c*32+:12]}+({8'd0,req_beats[c*5+:5]}<<5))<=4096 &&
    (c!=N-1 || allow_snapshot);
  end
 end

 // Narrow client selectors bound every dynamic packed-bus address to seven
 // clients; this prevents ADS inferring 32-bit offset multipliers.
 // Independent round-robin admission and retirement per frame bank. The
 // selected valid never depends on issue_ready, avoiding a combinational loop.
 // A client retains its tag/ticket until both frame retirement and user ACK.
 always @* begin
  commands=frame_command;req_ready=0;dma_req=0;dma_done_ready=0;ownership_granted=0;ownership_rejected=0;
  for(b=0;b<5;b=b+1) begin
   commands[b*`FM_CMD_BITS+`FM_CMD_ISSUE]=0;
   commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE]=0;
   issue_choice[b]=-1;complete_choice[b]=-1;
   for(off=0;off<N;off=off+1) begin
    k=rr_issue[b]+off;if(k>=N)k=k-N;
    if(issue_choice[b]<0 && state[k[2:0]]==ADMIT && !cancel_saved[k[2:0]] && bank[k[2:0]]==b &&
       !(admit_result_valid[b] && admit_result_client[b]==k[2:0]))
     issue_choice[b]=k;
    k=rr_complete[b]+off;if(k>=N)k=k-N;
    if(complete_choice[b]<0 && state[k[2:0]]==WAIT_DRAIN && bank[k[2:0]]==b && dma_done[k[2:0]] &&
       (!write_saved[k[2:0]] || verified[k[2:0]] || dma_error[k[2:0]] || dma_cancelled[k[2:0]])) complete_choice[b]=k;
   end
   // Held bank commands need no early fault mux: frame_manager qualifies its
   // response and all state updates with fabric_ready. Keeping COMPLETE valid
   // independent of the fault tree avoids a fault -> drain-error -> ISSUE chain.
   begin
    k=admit_client[b];
    if(admit_valid[b] && state[k[2:0]]==ADMIT && !cancel_saved[k[2:0]]) begin
     commands[b*`FM_CMD_BITS+`FM_CMD_ISSUE]=1;
     commands[b*`FM_CMD_BITS+`FM_CMD_ISSUE_SLOT]=admit_slot[b];
     commands[b*`FM_CMD_BITS+`FM_CMD_ISSUE_GEN]=admit_generation[b];
     commands[b*`FM_CMD_BITS+`FM_CMD_ISSUE_OWNER]=admit_owner[b];
    end
    k=retire_client[b];
    if(retire_stage[b]==2) begin
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE]=1;
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_TOKEN]=retire_token[b];
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_TICKET]=retire_ticket[b];
     // Producer cancellation invalidates a partial frame. Read cancellation
     // merely abandons this consumer's transport; it cannot corrupt stored
     // pixels or revoke an independent snapshot/consumer of the same frame.
     commands[b*`FM_CMD_BITS+`FM_CMD_COMPLETE_ERROR]=retire_error[b];
    end
    // Registered outcomes preserve full ownership fields and reject semantics.
    // A same-edge live cancel is latched while the committed token travels;
    // the outcome has priority over cancel when delivered on the next edge.
    k=admit_result_client[b];
    if(admit_result_valid[b])begin
     ownership_granted[k[2:0]]=!admit_result_rejected[b];
     ownership_rejected[k[2:0]]=admit_result_rejected[b];
    end
    k=retire_client[b];
    if(retire_stage[b]==3 && retire_ack[b])dma_done_ready[k[2:0]]=1;
   end
  end
  for(c=0;c<N;c=c+1) begin
   dma_req[c]=state[c]==SUBMIT && !fault;
   req_ready[c]=state[c]==FREE && controller_ready && !fault;
  end
 end

 // Queue/validate the immutable descriptor before ownership arbitration.
 // Save ownership before submitting DDR work. Cancellations during admission
 // are retained and applied AFTER the native adapter accepts its descriptor.
 integer i,j;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   addr_saved<=0;tag_saved<=0;beats_saved<=0;write_saved<=0;cancel_saved<=0;
   error<=0;cancelled<=0;logic_fault<=0;
   for(i=0;i<N;i=i+1) begin state[i]<=FREE;bank[i]<=0;token[i]<=0;ticket[i]<=0;owner_saved[i]<=0;slot_saved[i]<=0;generation_saved[i]<=0;end
   for(j=0;j<5;j=j+1)begin rr_issue[j]<=0;rr_complete[j]<=0;admit_valid[j]<=0;admit_client[j]<=0;admit_owner[j]<=0;admit_slot[j]<=0;admit_generation[j]<=0;retire_stage[j]<=0;retire_client[j]<=0;retire_token[j]<=0;retire_ticket[j]<=0;retire_error[j]<=0;
    admit_result_valid[j]<=0;admit_result_rejected[j]<=0;admit_result_client[j]<=0;admit_result_token[j]<=0;admit_result_ticket[j]<=0;retire_ack[j]<=0;end
  end else begin
   for(j=0;j<5;j=j+1) begin
    admit_result_valid[j]<=0;
    if(frame_command[j*`FM_CMD_BITS+`FM_CMD_ISSUE] || frame_command[j*`FM_CMD_BITS+`FM_CMD_COMPLETE]) logic_fault<=1;
    if(retire_stage[j]==0 && complete_choice[j]>=0)begin retire_client[j]<=complete_choice[j];retire_stage[j]<=1;end
    if(retire_stage[j]==1)begin
     retire_token[j]<=token[retire_client[j]];retire_ticket[j]<=ticket[retire_client[j]];
     retire_error[j]<=dma_error[retire_client[j]] || (dma_cancelled[retire_client[j]] && write_saved[retire_client[j]]);retire_stage[j]<=2;
    end
    if(controller_ready && !fault && commands[j*`FM_CMD_BITS+`FM_CMD_COMPLETE] &&
       !responses[j*`FM_RSP_BITS+`FM_RSP_COMPLETE_OK])logic_fault<=1;
    // Static bank destinations avoid seven competing dynamic write ports on
    // the round-robin state arrays in ADS's register inference.
    if(!admit_valid[j] && issue_choice[j]>=0)begin
     admit_client[j]<=issue_choice[j][2:0];admit_slot[j]<=slot_saved[issue_choice[j][2:0]];
     admit_generation[j]<=generation_saved[issue_choice[j][2:0]];admit_owner[j]<=owner_saved[issue_choice[j][2:0]];admit_valid[j]<=1;
    end
    if(admit_valid[j] && (state[admit_client[j]]!=ADMIT || cancel_saved[admit_client[j]]))admit_valid[j]<=0;
    if(commands[j*`FM_CMD_BITS+`FM_CMD_ISSUE] &&
       (responses[j*`FM_RSP_BITS+`FM_RSP_ISSUE_READY] || responses[j*`FM_RSP_BITS+`FM_RSP_ISSUE_REJECTED]))begin
     admit_valid[j]<=0;
     admit_result_valid[j]<=1;admit_result_client[j]<=admit_client[j];
     admit_result_rejected[j]<=!responses[j*`FM_RSP_BITS+`FM_RSP_ISSUE_READY];
     admit_result_token[j]<=issue_tokens[j*3+:3];admit_result_ticket[j]<=issue_tickets[j*64+:64];
     if(responses[j*`FM_RSP_BITS+`FM_RSP_ISSUE_READY])rr_issue[j]<=(admit_client[j]==N-1)?0:admit_client[j]+1'b1;
    end
    if(commands[j*`FM_CMD_BITS+`FM_CMD_COMPLETE] && responses[j*`FM_RSP_BITS+`FM_RSP_COMPLETE_OK])begin
     // Clear COMPLETE valid after the bank commits, before delayed native ACK.
     // A freed token may be reused without repeating the old completion.
     retire_stage[j]<=3;retire_ack[j]<=1;
    end
    if(retire_stage[j]==3 && retire_ack[j])begin
     rr_complete[j]<=(retire_client[j]==N-1)?0:retire_client[j]+1'b1;retire_stage[j]<=0;retire_ack[j]<=0;
    end
   end
   for(i=0;i<N;i=i+1) begin
    if(state[i]!=FREE && cancel[i])cancel_saved[i]<=1;
    if(req_valid[i] && req_ready[i]) begin
     addr_saved[i*32+:32]<=req_addr[i*32+:32];tag_saved[i*32+:32]<=req_tag[i*32+:32];
     beats_saved[i*5+:5]<=req_beats[i*5+:5];write_saved[i]<=req_write[i];
     // Local queue admission is independent of ownership-ready. Register
     // byte bounds/context first, then arbitrate a token on a later edge; the
     // native adapter still cannot see a descriptor without that token.
     error[i]<=!address_legal[i];cancelled[i]<=0;cancel_saved[i]<=cancel[i];
     bank[i]<=req_bank[i*3+:3];slot_saved[i]<=req_slot[i*2+:2];
     generation_saved[i]<=req_generation[i*32+:32];owner_saved[i]<=req_owner[i*3+:3];
     if(!address_legal[i])state[i]<=REPLY;else state[i]<=ADMIT;
    end
    if(state[i]==ADMIT)begin
     // A live cancel may coincide with the token-acceptance edge. Accept and
     // retain that token first, latch cancel above, then drain it through DMA.
     // Only the registered cancel inhibits arbitration; a network/ISP ready
     // tree cannot propagate through every other client's issue CE path.
     if(ownership_granted[i])begin
      state[i]<=SUBMIT;token[i]<=committed_tokens[bank[i]*3+:3];ticket[i]<=committed_tickets[bank[i]*64+:64];
     end else if(cancel_saved[i])begin state[i]<=REPLY;cancelled[i]<=1;
     end else if(ownership_rejected[i])begin state[i]<=REPLY;error[i]<=1;end
    end
    if(dma_req[i] && dma_ready[i])state[i]<=WAIT_DRAIN;
    if(dma_done[i] && dma_done_ready[i])begin
     state[i]<=REPLY;error[i]<=dma_error[i];cancelled[i]<=dma_cancelled[i];
     if(dma_tag[i*32+:32]!=tag_saved[i*32+:32])logic_fault<=1;
    end
    if(done[i] && done_ready[i])state[i]<=FREE;
   end
  end
 end

 frame_manager #(.TXNS(BANK_TXNS)) frames(.clk(clk),.reset_n(rst_n),.fabric_ready(controller_ready && !fault),
  .display_boundary(display_boundary),.command(commands),.response(responses));
 ddr_native_dma #(.CLIENTS(N),.VERIFY_WRITES(1),.CAPACITY_BYTES(CAPACITY_BYTES)) dma(
  .clk(clk),.rst_n(rst_n),.controller_ready(controller_ready),.allow_snapshot(allow_snapshot),
  .req_valid(dma_req),.req_ready(dma_ready),.req_write(write_saved),.req_addr(addr_saved),
  .req_beats(beats_saved),.req_tag(tag_saved),.urgent(urgent),.cancel(dma_cancel_request),
  .w_valid(w_valid),.w_ready(w_ready),.w_data(w_data),.w_strb(w_strb),
  .r_valid(r_valid),.r_ready(r_ready),.r_data(r_data),.r_last(r_last),
  .done(dma_done),.done_ready(dma_done_ready),.error(dma_error),.cancelled(dma_cancelled),
  .done_tag(dma_tag),.write_verified(verified),.fault(dma_fault),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.awid(awid),.arid(arid),
  .awvalid(awvalid),.arvalid(arvalid),.awready(awready),.arready(arready),
  .native_wdata(native_wdata),.native_wstrb(native_wstrb),.native_wready(native_wready),
  .native_wlast(native_wlast),.native_wid(native_wid),.native_rdata(native_rdata),
  .native_rvalid(native_rvalid),.native_rlast(native_rlast),.native_rid(native_rid),
  .bus_bytes(bus_bytes),.max_wait_cycles(max_wait_cycles),.useful_write_bytes(useful_write_bytes));
endmodule

// Purpose: non-preemptive, credit-gated native HMIC read arbitration. Logical
// addresses are BYTES; HMIC columns are 32-bit words (UG042003 p36,p58), so the
// final port divides by four. One UI beat advances eight columns / 32 bytes.
// Clients reserve an entire burst before ready. No RREADY exists on this IP.
module raw8_read_arbiter(
 input wire clk,rst_n,
 input wire h_req,input wire [27:0] h_addr,input wire [4:0] h_len,
 input wire h_space,output wire h_ready,output wire h_valid,output reg h_done,
 input wire n_req,input wire [27:0] n_addr,input wire [4:0] n_len,
 input wire n_space,output wire n_ready,output wire n_valid,output reg n_done,
 input wire f_req,input wire [27:0] f_addr,output wire f_ready,f_valid,output reg f_done,
 output reg [27:0] araddr,output reg [3:0] arlen,arid,output reg arvalid,
 input wire arready,input wire rvalid,rlast,input wire [3:0] rid,
 output reg fault
);
 reg [1:0] state,owner;reg prefer_net;reg [4:0] left;
 wire choose_f=state==0 && !fault && f_req;
 wire choose_h=state==0 && !fault && !f_req && h_req && h_space &&
               (!n_req || !n_space || !prefer_net);
 wire choose_n=state==0 && !fault && !f_req && n_req && n_space && !choose_h;
 assign h_ready=choose_h,n_ready=choose_n,f_ready=choose_f;
 assign h_valid=state==2 && owner==0 && rvalid;
 assign n_valid=state==2 && owner==1 && rvalid;
 assign f_valid=state==2 && owner==2 && rvalid;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;owner<=0;prefer_net<=0;left<=0;
   araddr<=0;arlen<=0;arid<=0;arvalid<=0;fault<=0;h_done<=0;n_done<=0;f_done<=0;end
  else begin
   h_done<=0;n_done<=0;f_done<=0;
   if(choose_f || choose_h || choose_n)begin
    owner<=choose_f?2:choose_n?1:0;arid<=choose_f?2:choose_n?1:0;
    araddr<=(choose_f?f_addr:choose_n?n_addr:h_addr)>>2;
    arlen<=choose_f?0:(choose_n?n_len:h_len)-1'b1;
    left<=choose_f?1:choose_n?n_len:h_len;arvalid<=1;state<=1;
    if(!choose_f)prefer_net<=choose_h;
    if(!choose_f && ((choose_n?n_len:h_len)==0 || (choose_n?n_len:h_len)>16))fault<=1;
   end
   if(state==1 && arready)begin arvalid<=0;state<=2;end
   if(state==2 && rvalid)begin
    left<=left-1'b1;
    // A broken RID/last contract freezes new requests; never route remaining
    // beats to another owner merely because a watchdog expired.
    if(rid!={2'b0,owner} || rlast!=(left==1))fault<=1;
    if(left==1)begin
     state<=0;
     case(owner)0:h_done<=1;1:n_done<=1;2:f_done<=1;endcase
    end
   end else if(rvalid)fault<=1;
  end
endmodule

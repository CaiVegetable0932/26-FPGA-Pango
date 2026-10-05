// Purpose: native read channel shared by HDMI, UDP, geometry and capture
// fence. Reserve a whole response, retain owner through LAST, validate RID.
// HDMI/UDP/geometry round-robin prevents the random-access cache starving
// streaming readers. HMIC addresses are 32-bit columns, clients use bytes.
module geometry_read_arbiter(
 input wire clk,rst_n,
 input wire h_req,input wire [27:0] h_addr,input wire [4:0] h_len,input wire h_space,
 output wire h_ready,h_valid,output reg h_done,
 input wire n_req,input wire [27:0] n_addr,input wire [4:0] n_len,input wire n_space,
 output wire n_ready,n_valid,output reg n_done,
 input wire g_req,input wire [27:0] g_addr,input wire [4:0] g_len,
 output wire g_ready,g_valid,output reg g_done,
 input wire f_req,input wire [27:0] f_addr,output wire f_ready,f_valid,output reg f_done,
 output reg [27:0] araddr,output reg [3:0] arlen,arid,output reg arvalid,
 input wire arready,rvalid,rlast,input wire [3:0] rid,output reg fault
);
 reg [1:0] state,owner,turn;reg [4:0] left;
 reg pick_h,pick_n,pick_g;
 wire pick_f=state==0 && !fault && f_req;
 always @*begin
  pick_h=0;pick_n=0;pick_g=0;
  if(state==0 && !fault && !f_req)case(turn)
   0:if(h_req && h_space)pick_h=1;else if(n_req && n_space)pick_n=1;else if(g_req)pick_g=1;
   1:if(n_req && n_space)pick_n=1;else if(g_req)pick_g=1;else if(h_req && h_space)pick_h=1;
   default:if(g_req)pick_g=1;else if(h_req && h_space)pick_h=1;else if(n_req && n_space)pick_n=1;
  endcase
 end
 assign h_ready=pick_h,n_ready=pick_n,g_ready=pick_g,f_ready=pick_f;
 assign h_valid=state==2 && owner==0 && rvalid,n_valid=state==2 && owner==1 && rvalid;
 assign f_valid=state==2 && owner==2 && rvalid,g_valid=state==2 && owner==3 && rvalid;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   state<=0;owner<=0;turn<=0;left<=0;araddr<=0;arlen<=0;arid<=0;arvalid<=0;
   fault<=0;h_done<=0;n_done<=0;g_done<=0;f_done<=0;
  end else begin
   h_done<=0;n_done<=0;g_done<=0;f_done<=0;
   if(pick_f || pick_h || pick_n || pick_g)begin
    owner<=pick_f?2:pick_g?3:pick_n?1:0;arid<=pick_f?2:pick_g?3:pick_n?1:0;
    araddr<=(pick_f?f_addr:pick_g?g_addr:pick_n?n_addr:h_addr)>>2;
    arlen<=pick_f?0:(pick_g?g_len:pick_n?n_len:h_len)-1'b1;
    left<=pick_f?1:pick_g?g_len:pick_n?n_len:h_len;arvalid<=1;state<=1;
    if(!pick_f)turn<=pick_h?1:pick_n?2:0;
    if(!pick_f && ((pick_g?g_len:pick_n?n_len:h_len)==0 ||
       (pick_g?g_len:pick_n?n_len:h_len)>16))fault<=1;
   end
   if(state==1 && arready)begin arvalid<=0;state<=2;end
   if(state==2 && rvalid)begin
    if(rid!={2'b0,owner} || rlast!=(left==1))fault<=1;
    left<=left-1'b1;
    if(left==1)begin
     state<=0;
     case(owner)0:h_done<=1;1:n_done<=1;2:f_done<=1;3:g_done<=1;endcase
    end
   end else if(rvalid)fault<=1;
  end
endmodule

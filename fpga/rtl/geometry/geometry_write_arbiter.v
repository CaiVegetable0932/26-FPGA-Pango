// Purpose: serialize camera and correction native writes through one HMIC
// channel. Retain owner from AW through its LAST W beat, including W accepted
// together with AW. Neither client's address/data can be mixed or preempted.
module geometry_write_arbiter(
 input wire clk,rst_n,
 input wire [27:0] c_addr,g_addr,input wire [255:0] c_data,g_data,
 input wire c_valid,g_valid,output wire c_ready,g_ready,c_wready,g_wready,
 output wire [27:0] awaddr,output wire awvalid,output wire [255:0] wdata,
 input wire awready,wready,wlast,output reg fault
);
 reg [1:0] state;reg owner,prefer_geo;
 assign awaddr=owner?g_addr:c_addr,wdata=owner?g_data:c_data;
 assign awvalid=state==1 && (owner?g_valid:c_valid);
 assign c_ready=state==1 && !owner && awready;
 assign g_ready=state==1 && owner && awready;
 wire wphase=state==2 || (state==1 && awvalid && awready);
 assign c_wready=wphase && !owner && wready,g_wready=wphase && owner && wready;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;owner<=0;prefer_geo<=0;fault<=0;end
  else case(state)
   0:if(!fault && (c_valid || g_valid))begin
    owner<=g_valid && (!c_valid || prefer_geo);state<=1;
   end
   1:if(awvalid && awready)begin
    if(wready)begin
     if(!wlast)fault<=1;
     prefer_geo<=!owner;state<=0;
    end else state<=2;
   end
   2:if(wready)begin if(!wlast)fault<=1;prefer_geo<=!owner;state<=0;end
  endcase
endmodule

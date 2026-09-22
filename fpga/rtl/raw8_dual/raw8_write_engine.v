// Purpose: consume ordered capture records, feed native HMIC writes, then
// read-verify the final word as a publication fence. No invented AXI B channel.
// Single outstanding write; full data held BEFORE AW and until WREADY/WLAST.
module raw8_write_engine(
 input wire clk,rst_n,input wire [27:0] slot_base,input wire [63:0] epoch,
 input wire [287:0] record_data,input wire record_valid,output wire record_ready,
 output reg commit,output reg good,output reg [63:0] captured_id,captured_epoch,
 output reg [27:0] awaddr,output wire [3:0] awlen,output reg awvalid,
 input wire awready,wready,wlast,input wire [3:0] wid,
 output reg [255:0] wdata,output wire [31:0] wstrb,
 output wire fence_req,output reg [27:0] fence_addr,input wire fence_ready,
 input wire fence_valid,fence_done,input wire [255:0] rdata,
 output reg fault
);
 reg [2:0] state;reg active,geometry_good,fence_match;
 reg [16:0] expected_offset;reg [6:0] column_word;reg [16:0] words;
 wire [1:0] tag=record_data[287:286];
 assign record_ready=state==0 && !fault;
 assign awlen=0,wstrb=32'hffffffff;
 assign fence_req=state==3;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;active<=0;geometry_good<=0;fence_match<=0;
   expected_offset<=0;column_word<=0;words<=0;commit<=0;good<=0;
   captured_id<=0;captured_epoch<=0;awaddr<=0;awvalid<=0;wdata<=0;fence_addr<=0;fault<=0;end
  else begin
   commit<=0;
   if(record_valid && record_ready)case(tag)
    1:begin
     if(active)fault<=1;
     active<=1;captured_id<=record_data[63:0];captured_epoch<=epoch;
     expected_offset<=0;column_word<=0;words<=0;
    end
    0:begin
     if(!active || record_data[272:256]!=expected_offset || words>=64800)fault<=1;
     wdata<=record_data[255:0];fence_addr<=slot_base+{6'b0,record_data[272:256],5'b0};
     awaddr<=(slot_base+{6'b0,record_data[272:256],5'b0})>>2;
     awvalid<=1;state<=1;words<=words+1'b1;
     if(column_word==59)begin column_word<=0;expected_offset<=expected_offset+5;end
     else begin column_word<=column_word+1'b1;expected_offset<=expected_offset+1'b1;end
    end
    2:begin
     if(!active || captured_id!=record_data[63:0])fault<=1;
     geometry_good<=record_data[64] && words==64800;
     if(record_data[64] && words==64800)begin state<=3;fence_match<=0;end
     else begin commit<=1;good<=0;active<=0;end
    end
    default:fault<=1;
   endcase
   if(state==1 && awready)begin awvalid<=0;state<=2;end
   if((state==2 || (state==1 && awready)) && wready)begin
    if(!wlast || wid!=0)fault<=1;
    state<=0;
   end
   if(state==3 && fence_ready)state<=4;
   if(state==4 && fence_valid)fence_match<=rdata==wdata;
   if(state==4 && fence_done)begin
    good<=geometry_good && fence_match;commit<=1;active<=0;state<=0;
    if(!fence_match)fault<=1;
   end
  end
endmodule

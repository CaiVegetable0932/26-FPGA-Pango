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
 output reg fault,output reg [2:0] fault_code,
 output reg [95:0] fault_snapshot,output wire [7:0] debug_state
);
 reg [2:0] state;reg active,geometry_good,fence_match;
 reg [16:0] expected_offset;reg [6:0] column_word;reg [16:0] words;
 wire [1:0] tag=record_data[287:286];
 // Purpose: memory-domain live stall position; has no effect on acceptance.
 assign debug_state={active,state,awvalid,fence_req,record_ready,wready};
 assign record_ready=state==0 && !fault;
 assign awlen=0,wstrb=32'hffffffff;
 assign fence_req=state==3;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;active<=0;geometry_good<=0;fence_match<=0;
   expected_offset<=0;column_word<=0;words<=0;commit<=0;good<=0;
   captured_id<=0;captured_epoch<=0;awaddr<=0;awvalid<=0;wdata<=0;fence_addr<=0;fault<=0;fault_code<=0;fault_snapshot<=0;end
  else begin
   commit<=0;
   if(record_valid && record_ready)case(tag)
    1:begin
     // Purpose: retain the first failing native/record contract until reset;
     // this distinguishes a DDR fence failure from a capture format error.
     if(active)begin fault<=1;if(!fault)fault_code<=1;end
     active<=1;captured_id<=record_data[63:0];captured_epoch<=epoch;
     expected_offset<=0;column_word<=0;words<=0;
    end
    0:begin
     if(!active || record_data[272:256]!=expected_offset || words>=64800)begin
      fault<=1;if(!fault)fault_code<=2;
      // Purpose: freeze the FIRST malformed WORD in the memory domain. UART
      // command06 reports byte-aligned fields, never an unsynchronised DVP bus.
      // [95:88]version, [87:80]flags(valid/active/offset/count), [79:72]column,
      // [71:48]word count, [47:24]expected offset, [23:0]received offset.
      if(!fault)fault_snapshot<={8'd1,4'b0,(words>=64800),
       (record_data[272:256]!=expected_offset),active,1'b1,
       1'b0,column_word,7'b0,words,7'b0,expected_offset,7'b0,record_data[272:256]};
     end
     wdata<=record_data[255:0];fence_addr<=slot_base+{6'b0,record_data[272:256],5'b0};
     awaddr<=(slot_base+{6'b0,record_data[272:256],5'b0})>>2;
     awvalid<=1;state<=1;words<=words+1'b1;
     if(column_word==59)begin column_word<=0;expected_offset<=expected_offset+5;end
     else begin column_word<=column_word+1'b1;expected_offset<=expected_offset+1'b1;end
    end
    2:begin
     if(!active || captured_id!=record_data[63:0])begin fault<=1;if(!fault)fault_code<=3;end
     geometry_good<=record_data[64] && words==64800;
     if(record_data[64] && words==64800)begin state<=3;fence_match<=0;end
     else begin commit<=1;good<=0;active<=0;end
    end
    default:begin fault<=1;if(!fault)fault_code<=4;end
   endcase
   if(state==1 && awready)begin awvalid<=0;state<=2;end
   if((state==2 || (state==1 && awready)) && wready)begin
    if(!wlast || wid!=0)begin fault<=1;if(!fault)fault_code<=5;end
    state<=0;
   end
   if(state==3 && fence_ready)state<=4;
   if(state==4 && fence_valid)fence_match<=rdata==wdata;
   if(state==4 && fence_done)begin
    good<=geometry_good && fence_match;commit<=1;active<=0;state<=0;
    if(!fence_match)begin fault<=1;if(!fault)fault_code<=6;end
   end
  end
endmodule

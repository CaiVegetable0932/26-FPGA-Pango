// Purpose: frame-scoped RAW DDR cache, one outstanding byte request. Each
// miss reserves one entire 256-bit native response (there is no RREADY).
// Address hashing includes row bits to avoid stride-2048 row conflicts.
module geometry_byte_cache(
 input wire clk,rst_n,invalidate,
 input wire request_valid,output wire request_ready,input wire [27:0] address,
 output reg response_valid,input wire response_ready,output wire [7:0] value,
 output wire read_req,output wire [27:0] read_addr,
 input wire read_ready,read_valid,read_done,input wire [255:0] read_data,
 output reg fault,output reg [31:0] hits,misses
);
 reg [255:0] data[0:63] /* synthesis syn_ramstyle="block_ram" */;
 reg [22:0] tags[0:63];reg [63:0] valid;
 reg [2:0] state;reg [27:0] held;reg [5:0] slot;
 reg [255:0] word;reg seen;
 // Purpose: read tag/valid beside the synchronous data RAM, then compare in
 // the existing lookup cycle. Only one request is outstanding, so no fill can
 // change this slot between acceptance and lookup; hit latency is unchanged.
 reg [22:0] lookup_tag;
 reg lookup_valid;
 wire [5:0] hash=address[10:5]^address[16:11];
 assign request_ready=state==0 && !response_valid && !invalidate && !fault;
 assign value=word[held[4:0]*8+:8];
 assign read_req=state==2 && !fault;
 assign read_addr={held[27:5],5'b0};
 // Purpose: clocked RAM read; tags/valid are small registers. A frame boundary
 // occurs only while idle, so no stale fill can enter the following frame.
 always @(posedge clk)begin
  if(request_valid && request_ready)begin
   word<=data[hash];lookup_tag<=tags[hash];lookup_valid<=valid[hash];
  end
  if(state==3 && read_valid)begin data[slot]<=read_data;word<=read_data;end
 end
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;held<=0;slot<=0;valid<=0;seen<=0;response_valid<=0;fault<=0;hits<=0;misses<=0;end
  else begin
   if(response_valid && response_ready)response_valid<=0;
   if(invalidate)begin valid<=0;if(state!=0 || response_valid)fault<=1;end
   case(state)
    0:if(request_valid && request_ready)begin held<=address;slot<=hash;state<=1;end
    1:if(lookup_valid && lookup_tag==held[27:5])begin
     hits<=hits+1'b1;response_valid<=1;state<=0;
    end else begin misses<=misses+1'b1;seen<=0;state<=2;end
    2:if(read_ready)state<=3;
    3:begin
     if(read_valid)begin
      if(seen)fault<=1;
      seen<=1;tags[slot]<=held[27:5];valid[slot]<=1;
     end
     if(read_done)begin
      if(!seen && !read_valid)fault<=1;
      response_valid<=1;state<=0;
     end
    end
   endcase
  end
endmodule

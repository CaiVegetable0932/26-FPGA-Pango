// Purpose: decouple one-pixel/clock packing from native DDR AW/W latency.
// A bounded synchronous queue holds completed gray/mask words; publication
// still requires an ordered readback fence of the final mask word.
module geometry_result_stream_writer #(parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048)(
 input wire clk,rst_n,start,input wire [27:0] base,
 input wire pixel_valid,pixel_mask,input wire [7:0] pixel,output wire pixel_ready,
 output reg done,good,fault,
 output reg [27:0] awaddr,output wire [3:0] awlen,output reg awvalid,
 input wire awready,wready,wlast,input wire [3:0] wid,
 output reg [255:0] wdata,output wire [31:0] wstrb,
 output wire fence_req,output reg [27:0] fence_addr,
 input wire fence_ready,fence_valid,fence_done,input wire [255:0] fence_data
);
 reg active,input_done,mask_pending,mask_last;
 reg [27:0] held_base;reg [255:0] pack,mask_pack;
 reg [4:0] lane;reg [7:0] mask_lane;
 reg [31:0] accepted,mask_block;reg [11:0] column,row;
 reg qwrite;reg [284:0] qdata;wire [284:0] head;wire [4:0] count;
 reg [2:0] state;reg write_last,matched;
 // Purpose: break the routed 256-bit fence equality/carry chain into eight
 // parallel 32-bit checks. Payload results need neither reset nor enable;
 // resettable tokens below authorize their use. Keep this real register cut.
 (* syn_preserve=1, syn_allow_retiming=0 *) reg [7:0] fence_equal_q;
 reg fence_valid_q,fence_done_q;
 reg fault_at_done_q;
 genvar fence_group;
 generate for(fence_group=0;fence_group<8;fence_group=fence_group+1)begin: g_fence_compare
  always @(posedge clk)
   fence_equal_q[fence_group]<=fence_data[fence_group*32+:32]==wdata[fence_group*32+:32];
 end endgenerate
 always @(posedge clk)fault_at_done_q<=fault;
 // Explicit byte-address widths prevent concatenation from widening a word
 // past the queue's last/address/data layout.
 wire [27:0] gray_address=held_base+row*STRIDE+column;
 wire [27:0] mask_address=held_base+28'h280000+(mask_block<<5);
 // Purpose: leave two credits for registered gray enqueue and its mask word.
 // The single mask cycle every256pixels is independent of DDR transaction time.
 assign pixel_ready=active && !input_done && !mask_pending && count<14 && !fault;
 assign awlen=0,wstrb=32'hffffffff;
 assign fence_req=state==3;
 wire pop=(state==2 || (state==1 && awready)) && wready;
 geometry_write_packet_fifo u_words(clk,rst_n,qwrite,qdata,pop,head,count);
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   active<=0;input_done<=0;mask_pending<=0;mask_last<=0;held_base<=0;
   pack<=0;mask_pack<=0;lane<=0;mask_lane<=0;accepted<=0;mask_block<=0;column<=0;row<=0;
   qwrite<=0;qdata<=0;state<=0;write_last<=0;matched<=0;
   fence_valid_q<=0;fence_done_q<=0;
   done<=0;good<=0;fault<=0;awaddr<=0;awvalid<=0;wdata<=0;fence_addr<=0;
  end else begin
   done<=0;qwrite<=0;
   fence_valid_q<=state==4 && fence_valid;
   fence_done_q<=state==4 && fence_done;
   if(start && !active && !fault)begin
    if(count!=0 || state!=0 || qwrite)fault<=1;
    else begin
     active<=1;input_done<=0;mask_pending<=0;held_base<=base;pack<=0;mask_pack<=0;
     lane<=0;mask_lane<=0;accepted<=0;mask_block<=0;column<=0;row<=0;good<=0;
    end
   end
   if(pixel_valid && pixel_ready)begin
    pack[lane*8+:8]<=pixel;mask_pack[mask_lane]<=pixel_mask;
    accepted<=accepted+1'b1;lane<=lane+1'b1;mask_lane<=mask_lane+1'b1;
    if(accepted==WIDTH*HEIGHT-1)input_done<=1;
    if(lane==31)begin
     qwrite<=1;qdata<={1'b0,gray_address,pixel,pack[247:0]};
     if(column==WIDTH-32)begin column<=0;row<=row+1'b1;end else column<=column+12'd32;
     if(mask_lane==255)begin mask_pending<=1;mask_last<=accepted==WIDTH*HEIGHT-1;end
    end
   end
   if(mask_pending && count<15)begin
    qwrite<=1;qdata<={mask_last,mask_address,mask_pack};
    mask_block<=mask_block+1'b1;mask_pending<=0;
   end
   // Purpose: DDR owner holds address/data stable through independent AW/W
   // stalls. A queued word leaves only when its final write beat is accepted.
   if(state==0 && count!=0 && !fault)begin
    awaddr<=head[283:256]>>2;wdata<=head[255:0];write_last<=head[284];
    fence_addr<=head[283:256];awvalid<=1;state<=1;
   end
   if(state==1 && awready)begin awvalid<=0;state<=2;end
   if(pop)begin
    if(!wlast || wid!=0)fault<=1;
    if(write_last)begin state<=3;matched<=0;end else state<=0;
   end
   if(state==3 && fence_ready)state<=4;
   // Purpose: retain the previous matching beat OR the beat coincident with
   // fence_done, exactly as before. State 5 waits for the registered compare;
   // only frame publication moves one clock later, not pixel/write throughput.
   if(fence_valid_q)matched<=&fence_equal_q;
   if(state==4 && fence_done)state<=5;
   if(fence_done_q)begin
    active<=0;done<=1;state<=0;
    good<=!fault_at_done_q && (matched || (fence_valid_q && &fence_equal_q));
    if(!(matched || (fence_valid_q && &fence_equal_q)))fault<=1;
   end
  end
endmodule

// Purpose: 16 word credit queue implemented as synchronous dual-port RAM.
// Explicit forwarding handles read/write collisions; front registers are
// cached ring entries, not extra capacity. No initialized RAM content is read.
module geometry_write_packet_fifo(
 input wire clk,rst_n,write,input wire [284:0] write_data,input wire pop,
 output wire [284:0] head,output reg [4:0] count
);
 reg [284:0] storage[0:15] /* synthesis syn_ramstyle="block_ram" */;
 reg [3:0] wp,rp;reg [284:0] front,next_front;
 wire [3:0] read_next=rp+(pop?4'd2:4'd1);
 assign head=front;
 always @(posedge clk)begin
  if(write)storage[wp]<=write_data;
  if(rst_n)begin
   if(write && wp==read_next)next_front<=write_data;else next_front<=storage[read_next];
   if(write && (count==0 || (pop && count==1)))front<=write_data;
   else if(pop && count>1)front<=next_front;
  end
 end
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin count<=0;wp<=0;rp<=0;end
  else begin
   if(write)wp<=wp+1'b1;if(pop)rp<=rp+1'b1;
   case({write,pop})2'b10:count<=count+1'b1;2'b01:count<=count-1'b1;default:begin end endcase
  end
endmodule


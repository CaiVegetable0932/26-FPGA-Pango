`timescale 1ns/1ps
// Purpose: 256-pixel RGB888 tiles, 4-way associative, four-parity-bank cache.
// Hot hit path reads four synchronous banks per cycle (II=1); duplicates broadcast.
// An ordered bounded FIFO preserves tags across misses and downstream stalls.
// A single complete tile refill is outstanding. It pins all four head tiles,
// merges repeated tile requests, blocks read/write collisions, and only publishes
// a tag after exactly 256 pixels plus successful LAST. Four-pixel fills write
// one 2x2 parity quad per cycle (64 transfers), compared with the 256-transfer
// single-pixel reference. DDR adapter must
// crop/pad partial edge tiles and report ACTUAL bus bytes including alignment.
// start invalidates tags only after queue/refill/output drain; no native cancellation.
module rgb_tile_cache #(
 parameter TAG_BITS=192,parameter SET_BITS=5,parameter QUEUE_DEPTH=8,parameter FILL_PIXELS=4,
 parameter TILE_X_BITS=4,parameter TILE_Y_BITS=4,
 parameter MAX_FRAME_WIDTH=32768,parameter MAX_FRAME_HEIGHT=32768
)(
 input clk,rst_n,input frame_start,output frame_ready,input [15:0] frame_width,frame_height,
 input in_valid,output in_ready,input signed [27:0] in_u,in_v,
 input in_mask,input [TAG_BITS-1:0] in_tag,
 output out_valid,input out_ready,output [95:0] out_samples,
 output reg [11:0] out_a,out_b,output reg out_mask,output reg [TAG_BITS-1:0] out_tag,
 output fill_req_valid,input fill_req_ready,output [11:0] fill_tile_x,fill_tile_y,
 input fill_valid,output fill_ready,input [FILL_PIXELS*24-1:0] fill_rgb,input fill_last,fill_error,
 input [31:0] fill_bus_bytes,
 output reg frame_error,config_rejected,
 output reg [31:0] hit_pixels,miss_tiles,duplicate_samples,stall_cycles,max_stall_cycles,
 output reg [63:0] refill_bus_bytes,output reg [15:0] queue_peak
);
 localparam SETS=1<<SET_BITS,SLOTS=SETS*4,BANK_WORDS=SLOTS*64,FILL_WORDS=256/FILL_PIXELS;
 localparam TILE_W=1<<TILE_X_BITS,TILE_H=1<<TILE_Y_BITS;
 // Purpose: store only enough bits for every tile admitted by this instance.
 // Ceil tile counts preserve partial edge tiles; a single possible tile still
 // uses a legal one-bit vector. Full integer coordinates remain untruncated
 // for comparison, and tag_valid continues to mask uninitialized payload.
 localparam MAX_TILES_X=(MAX_FRAME_WIDTH+TILE_W-1)/TILE_W;
 localparam MAX_TILES_Y=(MAX_FRAME_HEIGHT+TILE_H-1)/TILE_H;
 localparam TAG_X_BITS=MAX_TILES_X<2 ? 1 : $clog2(MAX_TILES_X);
 localparam TAG_Y_BITS=MAX_TILES_Y<2 ? 1 : $clog2(MAX_TILES_Y);
 localparam PARAMETERS_VALID=MAX_FRAME_WIDTH>=2 && MAX_FRAME_WIDTH<=32768 &&
  MAX_FRAME_HEIGHT>=2 && MAX_FRAME_HEIGHT<=32768 &&
  TILE_X_BITS>=1 && TILE_X_BITS<=7 && TILE_Y_BITS>=1 && TILE_Y_BITS<=7 &&
  TILE_X_BITS+TILE_Y_BITS==8;
 // Four parity banks require even tile dimensions and exactly 256 pixels.
 // This check exposes historically unverified shapes; the same constant also
 // gates hardware admission if a synthesis tool ignores simulation tasks.
`ifndef SYNTHESIS
 initial if(!PARAMETERS_VALID) $fatal(1,"CACHE_PARAMETER_INVALID max/frame or tile parity shape");
`endif
 localparam QUEUE_BITS=QUEUE_DEPTH<2 ? 1 : $clog2(QUEUE_DEPTH);
 localparam LOOKUP=0,REQUEST=1,FILL=2,SELECT=3,REQUERY=4;
 reg [2:0] state;
 reg [15:0] width,height;
 reg enabled,result_valid;
 reg [SLOTS-1:0] tag_valid;
 // Tags are tiny, heavily multiported tables. Distributed RAM keeps replicas
 // near their registered comparators; reserving many sparsely used DRM blocks
 // for these tables increases routing pressure beside the four data banks.
 reg [TAG_X_BITS-1:0] tag_x[0:SLOTS-1] /* synthesis syn_ramstyle="lut_ram" */;
 reg [TAG_Y_BITS-1:0] tag_y[0:SLOTS-1] /* synthesis syn_ramstyle="lut_ram" */;
 reg [1:0] replace_way[0:SETS-1];
 wire [23:0] bank_q[0:3];
 reg [1:0] output_bank[0:3];
 reg data_valid,data_mask;
 reg [TAG_BITS-1:0] data_tag;
 reg [11:0] data_a,data_b;
 reg [1:0] data_bank[0:3];
 reg [$clog2(BANK_WORDS)-1:0] data_address[0:3];
 reg signed [27:0] qu[0:QUEUE_DEPTH-1],qv[0:QUEUE_DEPTH-1];
 reg [TAG_BITS-1:0] qt[0:QUEUE_DEPTH-1];
 reg qm[0:QUEUE_DEPTH-1];
 // FIFO occupancy is proven 0..QUEUE_DEPTH; explicit unsigned widths also
 // shorten the admission/empty path instead of timing a 32-bit signed counter.
 reg [QUEUE_BITS-1:0] head,tail;
 reg [QUEUE_BITS:0] count;
 reg lookup_valid,lookup_mask;
 reg signed [27:0] lookup_u,lookup_v;
 reg [TAG_BITS-1:0] lookup_tag;
 reg query_valid,query_mask;
 reg signed [27:0] query_u,query_v;
 reg [TAG_BITS-1:0] query_tag;
 reg [15:0] pre_sx[0:3],pre_sy[0:3];
 // Registered query payload has the same lossless width as its tag table.
 reg [TAG_X_BITS-1:0] query_x[0:3][0:3];
 reg [TAG_Y_BITS-1:0] query_y[0:3][0:3];
 reg query_hit_valid[0:3][0:3];
 reg [SET_BITS-1:0] read_set[0:3];integer read_lane;
 reg [15:0] prefix_x[0:3],prefix_y[0:3];integer prefix_index;
 reg prefix_mask;
 reg [SET_BITS+2:0] saved_slots[0:3];reg [SET_BITS-1:0] saved_set;
 // Preserve the registered public 12-bit request bus and its hold behavior.
 // Admission bounds every issued tile integer to 0..4095, so assignment from
 // full tx/ty zero-extends smaller valid coordinates without a truncation alias.
 reg [11:0] requested_x,requested_y;
 integer fill_slot,fill_index;
 reg [31:0] blocked_run;
 reg drain_fault;
 reg [15:0] sx[0:3],sy[0:3];
 integer tx[0:3],ty[0:3];reg [SET_BITS-1:0] sets[0:3];
 integer slots[0:3],banks[0:3],addresses[0:3];
 integer bank_addr[0:3];
 integer i,j,k,w,n,lane,miss_lane,victim,rr_way,candidate;
 reg all_hit,pinned,conflict;
 wire head_mask=query_mask;
 wire result_ready=!result_valid || out_ready;
 wire data_ready=!data_valid || result_ready;
 wire read_issue=data_valid && result_ready;
 wire serve=query_valid && state==LOOKUP && data_ready && (all_hit || !head_mask || frame_error);
 wire query_transfer=lookup_valid && state==LOOKUP && (!query_valid || serve);
 wire pop=count!=0 && state==LOOKUP && (!lookup_valid || query_transfer);
 wire push=in_valid && in_ready;
 wire bank_write=fill_valid && fill_ready && !drain_fault && !fill_error;
 wire [$clog2(BANK_WORDS)-1:0] write_address=fill_slot*64+(FILL_PIXELS==4 ? fill_index :
  (fill_index>>(TILE_X_BITS+1))*(TILE_W/2)+((fill_index&(TILE_W-1))>>1));
 genvar lane_index;
 generate for(lane_index=0;lane_index<4;lane_index=lane_index+1) begin: g_bank
  if(FILL_PIXELS==4) begin
   rgb_cache_bank #(.WORDS(BANK_WORDS)) u_ram(.clk(clk),.read_enable(read_issue && data_mask),
    .read_address(data_address[lane_index]),.q(bank_q[lane_index]),
    .write_enable(bank_write),.write_address(write_address),.data(fill_rgb[lane_index*24+:24]));
  end else begin
   rgb_cache_bank #(.WORDS(BANK_WORDS)) u_ram(.clk(clk),.read_enable(read_issue && data_mask),
    .read_address(data_address[lane_index]),.q(bank_q[lane_index]),
    .write_enable(bank_write && {fill_index[TILE_X_BITS],fill_index[0]}==lane_index),
    .write_address(write_address),.data(fill_rgb[23:0]));
  end
  assign out_samples[lane_index*24+:24]=out_mask ? bank_q[output_bank[lane_index]] : 24'd0;
 end endgenerate
 assign in_ready=enabled && !frame_start && count<QUEUE_DEPTH;
 assign frame_ready=count==0 && !lookup_valid && !query_valid && !data_valid && state==LOOKUP && !result_valid;
 assign out_valid=result_valid;
 assign fill_req_valid=state==REQUEST,fill_tile_x=requested_x,fill_tile_y=requested_y;
 assign fill_ready=state==FILL;
 // Parallel tag lookups and explicit duplicate-bank broadcast. In this four
 // parity scheme unequal neighbours cannot collide; assertion/test covers it.
 // Replacement skips every tile pinned by the current four-neighbour request.
 // Stage A performs coordinate bounds, neighbour clamp and parity before tag
 // search. It consumes FIFO ownership into an elastic lookup register; hits
 // can retire and reload that register every cycle, preserving II=1.
 always @* begin
  prefix_mask=count!=0 && qm[head] && qu[head]>=0 && qv[head]>=0 &&
   $signed(qu[head])<=($signed({1'b0,width})-1)*4096 && $signed(qv[head])<=($signed({1'b0,height})-1)*4096;
  for(prefix_index=0;prefix_index<4;prefix_index=prefix_index+1)begin
   // A validated positive S(28,12) coordinate has at most 15 integer bits.
   // Zero extension makes the address domain explicit; no signed floor is lost.
   prefix_x[prefix_index]=prefix_mask ? {1'b0,qu[head][26:12]} : 0;
   prefix_y[prefix_index]=prefix_mask ? {1'b0,qv[head][26:12]} : 0;
   if((prefix_index&1)!=0 && prefix_x[prefix_index]<width-1)prefix_x[prefix_index]=prefix_x[prefix_index]+1;
   if(prefix_index>=2 && prefix_y[prefix_index]<height-1)prefix_y[prefix_index]=prefix_y[prefix_index]+1;
  end
 end
 // Stage B reads tags into local registers before comparison/way selection.
 // After each successful refill, REQUERY refreshes the held oldest request from
 // the newly published tags, without resubmitting or losing its coordinates.
 always @* begin
  for(read_lane=0;read_lane<4;read_lane=read_lane+1)
   read_set[read_lane]=state==REQUERY ? ((sx[read_lane]>>TILE_X_BITS)^(sy[read_lane]>>TILE_Y_BITS)) :
    ((pre_sx[read_lane]>>TILE_X_BITS)^(pre_sy[read_lane]>>TILE_Y_BITS));
 end
 always @* begin
  all_hit=1;miss_lane=-1;conflict=0;victim=-1;pinned=0;rr_way=0;candidate=0;
  for(i=0;i<4;i=i+1) bank_addr[i]=0;
  for(i=0;i<4;i=i+1) begin
   tx[i]=sx[i]>>TILE_X_BITS;ty[i]=sy[i]>>TILE_Y_BITS;sets[i]=(tx[i]^ty[i])&(SETS-1);
   slots[i]=SLOTS;
   for(j=0;j<4;j=j+1)
    if(query_hit_valid[i][j] && query_x[i][j]==tx[i] && query_y[i][j]==ty[i]) slots[i]=sets[i]*4+j;
   if(slots[i]==SLOTS) begin all_hit=0;if(miss_lane<0) miss_lane=i;end
   // Source addresses are nonnegative after head_mask validation. Explicit
   // parity bits avoid unsupported signed-modulo operators in this PDS version.
   banks[i]=((sy[i]&1)<<1)|(sx[i]&1);
   addresses[i]=(slots[i]==SLOTS ? 0 : slots[i]*64)+((sy[i]&(TILE_H-1))>>1)*(TILE_W/2)+((sx[i]&(TILE_W-1))>>1);
   bank_addr[banks[i]]=addresses[i];
   // Detect bank-port conflicts from the source coordinates BEFORE tag lookup.
   // Equal coordinates must broadcast the same sample; distinct coordinates in
   // one bank are illegal for the clamped adjacent-neighbour contract. This
   // removes tag priority/mux results from the fault-report timing path.
   for(j=0;j<i;j=j+1)
    if(banks[i]==banks[j] && (sx[i]!=sx[j] || sy[i]!=sy[j])) conflict=1;
  end
  if(state==SELECT) begin
   for(w=0;w<4;w=w+1) begin
    rr_way=(replace_way[saved_set]+w)&3;candidate=saved_set*4+rr_way;pinned=0;
    for(k=0;k<4;k=k+1) if(saved_slots[k]==candidate) pinned=1;
    if(!pinned && victim<0) victim=candidate;
   end
  end
 end
 // A hit emits one register stage. During a miss the oldest request waits and
 // admission continues until the bounded FIFO is full; no request is discarded.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   state<=LOOKUP;enabled<=0;lookup_valid<=0;query_valid<=0;data_valid<=0;result_valid<=0;tag_valid<=0;head<=0;tail<=0;count<=0;
   frame_error<=0;config_rejected<=0;hit_pixels<=0;miss_tiles<=0;duplicate_samples<=0;
   stall_cycles<=0;max_stall_cycles<=0;blocked_run<=0;refill_bus_bytes<=0;queue_peak<=0;
   for(n=0;n<SETS;n=n+1) replace_way[n]<=0;
  end else begin
   config_rejected<=0;
   if(frame_start) begin
    // Reject oversized configurations before publishing ownership/valid tags.
    // The public refill ABI is still 12 bits: unusual generic tile shapes must
    // reject frame spans requiring more than 4096 tiles along either axis.
    // A rejected start preserves the prior drained/active context unchanged.
    if(frame_ready && PARAMETERS_VALID && frame_width>=2 && frame_height>=2 &&
       frame_width<=MAX_FRAME_WIDTH && frame_height<=MAX_FRAME_HEIGHT &&
       frame_width<=4096*TILE_W && frame_height<=4096*TILE_H) begin
     width<=frame_width;height<=frame_height;enabled<=1;tag_valid<=0;frame_error<=0;
     hit_pixels<=0;miss_tiles<=0;duplicate_samples<=0;stall_cycles<=0;max_stall_cycles<=0;
     blocked_run<=0;refill_bus_bytes<=0;queue_peak<=0;
    end else config_rejected<=1;
   end
   if(push) begin
    qu[tail]<=in_u;qv[tail]<=in_v;qm[tail]<=in_mask;qt[tail]<=in_tag;
    tail<=tail==QUEUE_DEPTH-1 ? 0 : tail+1;
    if(!pop && count+1>queue_peak) queue_peak<=count+1;
   end
   if(pop) head<=head==QUEUE_DEPTH-1 ? 0 : head+1;
   if(pop) begin
    lookup_valid<=1;lookup_mask<=prefix_mask;lookup_u<=qu[head];lookup_v<=qv[head];lookup_tag<=qt[head];
    for(lane=0;lane<4;lane=lane+1)begin pre_sx[lane]<=prefix_x[lane];pre_sy[lane]<=prefix_y[lane];end
   end else if(query_transfer) lookup_valid<=0;
   if(query_transfer)begin
    query_valid<=1;query_mask<=lookup_mask;query_u<=lookup_u;query_v<=lookup_v;query_tag<=lookup_tag;
    for(lane=0;lane<4;lane=lane+1)begin sx[lane]<=pre_sx[lane];sy[lane]<=pre_sy[lane];end
   end else if(serve)query_valid<=0;
   if(query_transfer || state==REQUERY)begin
    for(lane=0;lane<4;lane=lane+1)for(n=0;n<4;n=n+1)begin
     query_x[lane][n]<=tag_x[read_set[lane]*4+n];query_y[lane][n]<=tag_y[read_set[lane]*4+n];
     query_hit_valid[lane][n]<=tag_valid[read_set[lane]*4+n];
    end
   end
   if(state==REQUERY)state<=LOOKUP;
   case({push,pop})
    2'b10:count<=count+1;
    2'b01:count<=count-1;
    default: ;
   endcase
   // Stage B registers hit selection and bank addresses; stage C performs RAM
   // reads. The extra elastic register splits tag mux/comparison from DRM setup,
   // while both stages retire/reload each clock on a continuous hit stream.
   if(data_ready)begin
    data_valid<=serve;
    if(serve)begin
     data_tag<=query_tag;data_a<=query_u[11:0];data_b<=query_v[11:0];
     data_mask<=head_mask && !frame_error && !conflict;
     for(lane=0;lane<4;lane=lane+1)begin data_bank[lane]<=banks[lane];data_address[lane]<=bank_addr[lane];end
     if(head_mask && !frame_error) begin
      hit_pixels<=hit_pixels+1'b1;
      duplicate_samples<=duplicate_samples+((sx[0]==sx[1] && sy[0]==sy[2]) ? 3 : (sx[0]==sx[1] || sy[0]==sy[2]) ? 2 : 0);
     end
    end
   end
   if(result_ready)begin
    result_valid<=read_issue;
    if(read_issue)begin
     out_tag<=data_tag;out_a<=data_a;out_b<=data_b;out_mask<=data_mask;
     for(lane=0;lane<4;lane=lane+1)output_bank[lane]<=data_bank[lane];
    end
   end
   if((count!=0 || lookup_valid || query_valid) && !serve) begin
    stall_cycles<=stall_cycles+1'b1;blocked_run<=blocked_run+1'b1;
    if(blocked_run+1>max_stall_cycles) max_stall_cycles<=blocked_run+1'b1;
   end else blocked_run<=0;
   // Miss stage snapshots the pinned slots; victim arbitration has a separate
   // register boundary from the tag RAM/mux path and never evicts a required tile.
   if(state==LOOKUP && query_valid && head_mask && conflict)frame_error<=1;
   if(state==LOOKUP && query_valid && head_mask && !all_hit && !frame_error && !conflict && result_ready) begin
    requested_x<=tx[miss_lane];requested_y<=ty[miss_lane];saved_set<=sets[miss_lane];state<=SELECT;
    for(lane=0;lane<4;lane=lane+1)saved_slots[lane]<=slots[lane];
   end
   if(state==SELECT) begin
    if(victim<0) begin frame_error<=1;state<=LOOKUP;end
    else begin
     fill_slot<=victim;tag_valid[victim]<=0;
     state<=REQUEST;fill_index<=0;drain_fault<=0;miss_tiles<=miss_tiles+1'b1;
    end
   end
   if(fill_req_valid && fill_req_ready) state<=FILL;
   if(fill_valid && fill_ready) begin
    // Quad order: bank0 even/even, bank1 odd/even, bank2 even/odd,
    // bank3 odd/odd; quads traverse (TILE_W/2)x(TILE_H/2) in raster order.
    // TILE_X_BITS+TILE_Y_BITS must equal eight (256 pixels). Writes cannot collide
    // with lookup reads because FILL owns the banks until the response drains.
    if(fill_error || (!fill_last && fill_index==FILL_WORDS-1)) begin drain_fault<=1;frame_error<=1;end
    if(fill_last) begin
     state<=REQUERY;refill_bus_bytes<=refill_bus_bytes+fill_bus_bytes;
     if(fill_error || drain_fault || fill_index!=FILL_WORDS-1)begin frame_error<=1;state<=LOOKUP;end
     else begin
      tag_valid[fill_slot]<=1;tag_x[fill_slot]<=requested_x;tag_y[fill_slot]<=requested_y;
      replace_way[fill_slot>>2]<=fill_slot[1:0]+2'd1;
     end
    end else if(fill_index<FILL_WORDS-1) fill_index<=fill_index+1;
   end
  end
 end
endmodule

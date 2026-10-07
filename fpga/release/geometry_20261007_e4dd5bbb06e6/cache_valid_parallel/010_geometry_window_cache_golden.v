// Purpose: packed-tag cache for the board geometry sampler. Derived compact
// golden SHA256 B991CFE6D48F920ED11C4B9B2FFF3C2B45764DE022C18B9AC75B3899C9D2B7FC.
// Store each word's tag above its 256 payload bits in all three mirrors. Tag
// writes precede valid publication, but no lookup promotion overlaps a fill;
// queued A is marked stale and replayed before use. Data and tag stay one-cycle
// synchronous reads, with valid/reset/invalidation unchanged from the golden.
// Nine simultaneous synchronous byte lookups replace nine serialized
// cache transactions. Three mirrored CACHE_WORDS x 256 memories share fills
// (786432 logical data bits at the default 1024 words). Each mirror has two clocked
// read ports, one reused for writes. Data
// arrays are never reset. Tags/valid are frame scoped. A footprint retains hit
// bytes during misses, so hash conflicts cannot livelock or corrupt a window.
module geometry_window_cache_golden #(parameter STRIDE=2048,CACHE_WORDS=1024)(
 input wire clk,rst_n,invalidate,request_valid,source_valid,enhance,
 input wire [27:0] base,input wire [11:0] x0,x1,y0,y1,frac_x,frac_y,
 output wire request_ready,window_valid,input wire window_ready,
 output wire [71:0] window_bytes,output wire window_mask,window_enhance,
 output wire [11:0] window_fx,window_fy,
 output wire read_req,output wire [27:0] read_addr,output wire [4:0] read_len,
 input wire read_ready,read_valid,read_done,input wire [255:0] read_data,
 output reg fault,output reg [31:0] hits,misses
);
 localparam IDLE=0,LOOKUP=1,SELECT=2,ISSUE=3,WAIT_DATA=4,EMIT=5;
 localparam SLOT_BITS=$clog2(CACHE_WORDS);
 // Purpose: a direct slot contains the low SLOT_BITS of the 23-bit word
 // address, so a valid entry need store only the remaining high tag bits.
 // Folded/XOR slots do not determine those bits and retain the full tag.
 localparam COMPACT_TAG=(STRIDE==2048 && CACHE_WORDS>=256);
 localparam TAG_BITS=COMPACT_TAG?(23-SLOT_BITS):23;
 localparam WORD_BITS=256+TAG_BITS;
 reg [2:0] state;reg mask_q,enhance_q;reg [11:0] fx_q,fy_q;
 reg [27:0] address_q[0:8];reg [71:0] saved;
 // Purpose: one speculative RAM-read slot precedes the active window. A miss
 // blocks new requests; a queued lookup is replayed after fills because port A
 // and tags may have changed. No speculative DDR transaction is ever issued.
 reg a_valid,a_stale,a_mask,a_enhance;reg [11:0] a_fx,a_fy;
 reg [27:0] a_address[0:8];
 reg [8:0] missing;reg [27:0] fill_addr;reg seen;
 reg [CACHE_WORDS-1:0] valids;
 (* syn_preserve=1, syn_allow_retiming=0 *) reg [8:0] lane_hit;
 wire [71:0] lookup_bytes;
 wire accept=request_valid && request_ready;
 // Purpose: separate the wire transaction lifetime from its local pipeline.
 // Data/done may coincide with request grant. Done closes wire ownership at
 // once; the FSM waits for both done and saved-byte commit before proceeding.
 reg done_seen,fill_applied;
 (* syn_preserve=1, syn_allow_retiming=0 *) reg [255:0] response_data_q;
 reg response_valid_q,response_bytes_valid;
 (* syn_preserve=1, syn_allow_retiming=0 *) reg [71:0] response_bytes_q;
 reg [8:0] fill_mask;
 wire response_phase=(state==WAIT_DATA && !done_seen) || (state==ISSUE && read_ready);
 wire fill_write=response_valid_q && !fault;
 // Unconditional payload capture avoids a raw-valid enable cone on 256 FFs.
 // Only response_valid_q authorizes use, with full capacity reserved at ISSUE.
 always @(posedge clk)response_data_q<=read_data;
 // Purpose: the default stride-2048 index is exactly address[14:5]: sixteen
 // physical rows by 64 words. Exact default-fisheye full-frame replay measured
 // 66836 fills versus 375981 for 256 words (four rows). Keep smaller sizes
 // available for resource comparisons; physical DRM packing needs synthesis.
 // Direct-index tags retain every base/row alias above the slot bits; the
 // slot itself determines address[SLOT_BITS+4:5] for each valid entry. The
 // 64-word fallback preserves its previous four-row folded hash exactly;
 // other strides use a width-matched XOR hash. Supported sizes are powers
 // of two from 64 through 1024; 64, 256 and 1024 are regression baselines.
 function [SLOT_BITS-1:0] cache_slot;
  input [27:0] address;
  begin
   if(STRIDE==2048 && CACHE_WORDS>=256)cache_slot=address[SLOT_BITS+4:5];
   else if(STRIDE==2048 && CACHE_WORDS==64)
    cache_slot={address[12:11],address[8:5]^address[16:13]^address[20:17]};
   else cache_slot=address[SLOT_BITS+4:5]^address[2*SLOT_BITS+4:SLOT_BITS+5];
  end
 endfunction
 // Purpose: fill and all three mirrored tag-read paths use one encoding.
 // At a fixed direct slot, equality of these high bits is equivalent to
 // equality of address[27:5]. Full tags remain necessary for XOR indexing.
 function [TAG_BITS-1:0] cache_tag;
  input [27:0] address;
  begin
   if(COMPACT_TAG)cache_tag=address[27:SLOT_BITS+5];
   else cache_tag=address[27:5];
  end
 endfunction
 wire [SLOT_BITS-1:0] fill_slot=cache_slot(fill_addr);
 // synthesis translate_off
 initial if(CACHE_WORDS<64 || CACHE_WORDS>1024 || (CACHE_WORDS & (CACHE_WORDS-1))!=0)
  $fatal(1,"geometry_window_cache CACHE_WORDS must be a power of two in [64,1024]");
 // synthesis translate_on
 wire all_hit=&lane_hit;
 // Purpose: a two-slot elastic pipeline sustains hit II=1. Ready depends on
 // REGISTERED hit bits, never on a DRM tag output. Retiring B moves A into B
 // and accepts another A on the same edge. Backpressure freezes both slots.
 wire retire=(state==LOOKUP && all_hit && window_ready) || (state==EMIT && window_ready);
 wire stage_open=(state==IDLE) || retire;
 wire promote=a_valid && !a_stale && stage_open && !fault && !invalidate;
 wire replay=a_valid && a_stale && (state==EMIT || state==IDLE) && !fault && !invalidate;
 assign request_ready=!invalidate && !fault && stage_open && (!a_valid || promote);
 assign window_valid=!fault && ((state==LOOKUP && all_hit) || state==EMIT);
 assign window_bytes=state==LOOKUP?(mask_q?lookup_bytes:72'b0):saved;
 assign window_mask=mask_q,window_enhance=enhance_q,window_fx=fx_q,window_fy=fy_q;
 assign read_req=state==ISSUE && !fault,read_addr=fill_addr,read_len=5'd1;
 // Purpose: keep every exact scalar address, including repeated borders.
 // A normal three-column footprint spans at most two words per row. Three
 // logical mirrors with two read ports fetch those six words in parallel. A
 // registered half-word byte selection splits DRM->byte->saved/gray paths.
 // Each stage selects 16 bytes first, then just half/left/right. An unusual x1
 // producing a third word remains correct through the ordinary miss path.
 genvar lane;
 generate for(lane=0;lane<9;lane=lane+1)begin: lanes
  wire [11:0] sx=lane%3==0?(x0==0?12'd0:x0-1'b1):(lane%3==1?x0:x1);
  wire [11:0] sy=lane/3==0?(y0==0?12'd0:y0-1'b1):(lane/3==1?y0:y1);
  wire [27:0] address=base+sy*STRIDE+sx;
  always @(posedge clk)begin
   if(accept)a_address[lane]<=address;
   if(promote)address_q[lane]<=a_address[lane];
  end
 end endgenerate
 genvar row,col;
 generate for(row=0;row<3;row=row+1)begin: rows
  wire [27:0] left_address=replay?a_address[row*3]:lanes[row*3].address;
  wire [27:0] right_address=replay?a_address[row*3+2]:lanes[row*3+2].address;
  wire [SLOT_BITS-1:0] left_slot=cache_slot(left_address);
  wire [SLOT_BITS-1:0] right_slot=cache_slot(right_address);
  // Purpose: tags share unused native RAM word capacity rather than a six-read
  // standalone array. Native 256/269/279-bit probes each infer 8 TRUE_DUAL_PORT
  reg [WORD_BITS-1:0] data[0:CACHE_WORDS-1] /* synthesis syn_ramstyle="block_ram" */;
  reg [WORD_BITS-1:0] left_word_q,right_word_q;
  wire [255:0] left_word=left_word_q[255:0],right_word=right_word_q[255:0];
  wire [TAG_BITS-1:0] left_tag=left_word_q[WORD_BITS-1:256];
  wire [TAG_BITS-1:0] right_tag=right_word_q[WORD_BITS-1:256];
  reg left_valid,right_valid;
  // Purpose: port A uses ONE common address for synchronous reads and writes
  // to express two logical ports instead of three independent addresses.
  // Parent's matching old-data-read probe cache_ram_probe_20261006_224126_835
  // inferred TRUE_DUAL_PORT (8 DRM36K per 1024x256 mirror). Preserve that
  // template; resource packing for this revision still needs board synthesis.
  // PDS 2022.2-SP6.4 ADS guide 5.16 documents block_ram; the project's native
  // parameter_ram DPRAM also uses one address per port. Fill and lookup are
  // mutually exclusive. The old-data read during fill is never consumed,
  // avoiding any dependency on device read-during-write output behavior.
  wire [SLOT_BITS-1:0] port_a_addr=fill_write?fill_slot:left_slot;
  wire lookup_enable=(accept && source_valid) || (replay && a_mask);
  wire port_a_enable=fill_write || lookup_enable;
  always @(posedge clk)if(port_a_enable)begin
   if(fill_write)data[port_a_addr]<={cache_tag(fill_addr),response_data_q};
   left_word_q<=data[port_a_addr];
  end
  // Port B supplies the possible crossing payload and its tag in one read.
  always @(posedge clk)if(lookup_enable)begin
   right_word_q<=data[right_slot];
   left_valid<=valids[left_slot];right_valid<=valids[right_slot];
  end
  for(col=0;col<3;col=col+1)begin: columns
   wire use_left=a_address[row*3+col][27:5]==a_address[row*3][27:5];
   wire [TAG_BITS-1:0] chosen_tag=use_left?left_tag:right_tag;
   wire chosen_valid=use_left?left_valid:right_valid;
   // Purpose: an unusual x1 can make the middle lane's word differ from
   // BOTH port words. A full tag rejected a wrong-slot port implicitly;
   // compact tags must check that slot explicitly. use_left already proves
   // complete word identity; otherwise the selected port is the right one.
   wire chosen_slot_matches=!COMPACT_TAG || use_left ||
    cache_slot(a_address[row*3+col])==cache_slot(a_address[row*3+2]);
   // Purpose: physical register boundary splits a 64:1 combined byte mux
   // into 16:1 then 4:1, for BOTH hit output and miss snapshot. Keep tags and
   // metadata aligned; a stalled active window never observes the next A.
   (* syn_preserve=1, syn_allow_retiming=0 *) reg [15:0] left_half,right_half;
   reg choose_left;
   always @(posedge clk)if(promote)begin
    left_half<={left_word[128+a_address[row*3+col][3:0]*8+:8],left_word[a_address[row*3+col][3:0]*8+:8]};
    right_half<={right_word[128+a_address[row*3+col][3:0]*8+:8],right_word[a_address[row*3+col][3:0]*8+:8]};
    choose_left<=use_left;
    lane_hit[row*3+col]<=!a_mask || (chosen_valid && chosen_slot_matches && chosen_tag==cache_tag(a_address[row*3+col]));
   end
   wire [7:0] left_byte=address_q[row*3+col][4]?left_half[15:8]:left_half[7:0];
   wire [7:0] right_byte=address_q[row*3+col][4]?right_half[15:8]:right_half[7:0];
   assign lookup_bytes[(row*3+col)*8+:8]=choose_left?left_byte:right_byte;
  end
 end endgenerate
 integer i,k;reg [3:0] first_missing;
 // Purpose: only miss handling uses a priority selector. The all-hit path
 // accepts one whole window each clock, independently of gray latency.
 always @*begin
  first_missing=0;
  for(k=8;k>=0;k=k-1)if(missing[k])first_missing=k;
 end
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin
   state<=IDLE;mask_q<=0;enhance_q<=0;fx_q<=0;fy_q<=0;saved<=0;
   missing<=0;fill_addr<=0;seen<=0;valids<=0;fault<=0;hits<=0;misses<=0;
   a_valid<=0;a_stale<=0;done_seen<=0;fill_applied<=0;
   response_valid_q<=0;response_bytes_valid<=0;fill_mask<=0;
  end else begin
   // Invalidation is an idle-only operation; a busy invalidate never silently
   // discards an outstanding no-RREADY transaction or a pending footprint.
   if(invalidate)begin
    if(state!=IDLE || a_valid || response_valid_q || response_bytes_valid)fault<=1;else valids<=0;
   end
   if((read_valid || read_done) && !response_phase)fault<=1;
   case(state)
    LOOKUP:if(all_hit)begin
     if(window_ready)begin
      if(mask_q)hits<=hits+1'b1;
      state<=IDLE;
     end
    end else begin
     saved<=lookup_bytes;missing<=~lane_hit;state<=SELECT;
    end
    SELECT:if(missing==0)state<=EMIT;
     else begin
      fill_addr<={address_q[first_missing][27:5],5'b0};seen<=0;done_seen<=0;fill_applied<=0;state<=ISSUE;
      // Freeze the duplicate-lane mask before issuing; no long address compare
      // is left on the DDR response-to-saved write-enable path.
      for(i=0;i<9;i=i+1)fill_mask[i]<=missing[i] && address_q[i][27:5]==address_q[first_missing][27:5];
     end
    ISSUE:if(read_ready)begin misses<=misses+1'b1;state<=WAIT_DATA;end
    WAIT_DATA:if(done_seen && fill_applied && !fault)begin
     // Payload/tag was written on fill_write; only publish its existing valid
     // bit here, after the same done and saved-byte fence as the frozen cache.
     valids[fill_slot]<=1;state<=SELECT;
    end
    EMIT:if(window_ready)state<=IDLE;
   endcase
   // Purpose: raw DDR -> full beat FF -> extracted bytes FF -> saved. The
   // RAM write uses the same buffered beat. Consumer stalls cannot overflow
   // this single reserved response. Publishing tags waits for matched done.
   response_valid_q<=response_phase && read_valid && !seen && !fault;
   response_bytes_valid<=fill_write;
   if(fill_write)begin
    for(i=0;i<9;i=i+1)response_bytes_q[i*8+:8]<=response_data_q[address_q[i][4:0]*8+:8];
    if(a_valid)a_stale<=1;
   end
   if(response_bytes_valid && !fault)begin
    for(i=0;i<9;i=i+1)if(fill_mask[i])saved[i*8+:8]<=response_bytes_q[i*8+:8];
    missing<=missing & ~fill_mask;fill_applied<=1;
   end
   // Wire-level faults are checked immediately, not against delayed valid.
   // A duplicate or a late beat cannot masquerade as a later transaction.
   if(response_phase)begin
    if(read_valid)begin
     if(seen)fault<=1;
     seen<=1;
    end
    if(read_done)begin
     if(!seen && !read_valid)fault<=1;
     done_seen<=1;
    end
   end
   // Purpose: promotion retires the OLD B and captures OLD A. Acceptance
   // replaces A on that edge; replay repairs A after miss fills before it can
   // promote. All arithmetic context travels with its registered byte groups.
   if(replay)a_stale<=0;
   if(promote)begin
    a_valid<=0;mask_q<=a_mask;enhance_q<=a_enhance;fx_q<=a_fx;fy_q<=a_fy;
    state<=LOOKUP;
   end
   if(accept)begin
    a_valid<=1;a_stale<=0;a_mask<=source_valid;a_enhance<=enhance;a_fx<=frac_x;a_fy<=frac_y;
   end
  end
endmodule

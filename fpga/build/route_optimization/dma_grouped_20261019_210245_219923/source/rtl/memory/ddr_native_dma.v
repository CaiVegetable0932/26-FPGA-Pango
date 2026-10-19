`timescale 1ns/1ps
// Purpose: independent, one-entry client queues for Logos2 HMIC_S (32-bit DQ).
// Requests use aligned BYTE addresses, 1..16 32-byte beats and an opaque tag.
// Buffer ALL write beats before AW; reserve all read storage before AR because
// native WVALID/RREADY/B do not exist (UG042003 pp.31-38,58). No native cancel.
// Cancel suppresses delivery but drains the issued transaction. Write completion
// is transport-only by default. VERIFY_WRITES=1 adds full masked readback;
// successful write_verified proves each written byte was observed at readback.
// rst_n must be synchronously released and asserted with controller reset; a
// local reset while the controller still has responses outstanding is illegal.
module ddr_native_dma #(
 parameter CLIENTS=7, parameter TAG_BITS=32, parameter MAX_BEATS=16,
 parameter EMERGENCY_QUOTA=2,
 // Preserve transport-only callers; frame publication enables full readback.
 parameter VERIFY_WRITES=0,
 parameter [31:0] CAPACITY_BYTES=32'h40000000
)(
 input clk, input rst_n, input controller_ready, input allow_snapshot,
 input [CLIENTS-1:0] req_valid, output [CLIENTS-1:0] req_ready,
 input [CLIENTS-1:0] req_write, input [CLIENTS*32-1:0] req_addr,
 input [CLIENTS*5-1:0] req_beats, input [CLIENTS*TAG_BITS-1:0] req_tag,
 input [CLIENTS-1:0] urgent, input [CLIENTS-1:0] cancel,
 input [CLIENTS-1:0] w_valid, output reg [CLIENTS-1:0] w_ready,
 input [CLIENTS*256-1:0] w_data, input [CLIENTS*32-1:0] w_strb,
 output reg [CLIENTS-1:0] r_valid, input [CLIENTS-1:0] r_ready,
 output reg [CLIENTS*256-1:0] r_data, output reg [CLIENTS-1:0] r_last,
 output reg [CLIENTS-1:0] done, input [CLIENTS-1:0] done_ready,
 output reg [CLIENTS-1:0] cancelled, output reg [CLIENTS-1:0] error,
 output reg [CLIENTS*TAG_BITS-1:0] done_tag,
 output reg [CLIENTS-1:0] write_verified,
 output [27:0] awaddr, output [3:0] awlen, output [3:0] awid,
 output awvalid, input awready,
 output [255:0] native_wdata, output [31:0] native_wstrb,
 input native_wready, input [3:0] native_wid, input native_wlast,
 output [27:0] araddr, output [3:0] arlen, output [3:0] arid,
 output arvalid, input arready,
 input [255:0] native_rdata, input native_rvalid,
 input [3:0] native_rid, input native_rlast,
 output reg fault,
 output reg [CLIENTS*32-1:0] max_wait_cycles,
 output reg [CLIENTS*32-1:0] bus_bytes,
 output reg [CLIENTS*32-1:0] useful_write_bytes
);
 localparam IDLE=0, WA=1, WD=2, RA=3, RD=4, VERIFY_ADDR=5, VERIFY_DATA=6;
 localparam CLIENT_BITS=(CLIENTS>1) ? $clog2(CLIENTS) : 1;
 localparam INDEX_BITS=(MAX_BEATS>1) ? $clog2(MAX_BEATS) : 1;
 localparam QUOTA_BITS=(EMERGENCY_QUOTA>0) ? $clog2(EMERGENCY_QUOTA+1) : 1;
 reg [2:0] state;
 reg [CLIENTS-1:0] pending, is_write, aborted, returned;
 reg [31:0] addr[0:CLIENTS-1];
 reg [4:0] beats[0:CLIENTS-1], loaded[0:CLIENTS-1], consumed[0:CLIENTS-1];
 reg [TAG_BITS-1:0] tag[0:CLIENTS-1];
 wire [CLIENTS*256-1:0] bank_data;
 wire [CLIENTS*32-1:0] bank_mask;
 wire [CLIENTS-1:0] eligible;
 reg [31:0] wait_cycles[0:CLIENTS-1];
 reg [CLIENT_BITS-1:0] owner,rr;
 // Binary two-client groups localize low-order owner fanout. All copies
 // update on the existing grant edge and hold through write/readback/drain.
 // ADS 5.15 preserves only these intentionally redundant local registers.
 localparam OWNER_GROUPS=(CLIENTS+1)/2;
 localparam OWNER_GROUP_BITS=(OWNER_GROUPS>1)?$clog2(OWNER_GROUPS):1;
 reg [OWNER_GROUPS-1:0] owner_lane /* synthesis syn_preserve=1 */;
 reg [OWNER_GROUP_BITS-1:0] owner_group;
 wire [OWNER_GROUPS*256-1:0] grouped_data;
 wire [OWNER_GROUPS*32-1:0] grouped_mask;
 wire [255:0] selected_data=grouped_data[owner_group*256+:256];
 wire [31:0] selected_mask=grouped_mask[owner_group*32+:32];
 genvar owner_pair;
 generate for(owner_pair=0;owner_pair<OWNER_GROUPS;owner_pair=owner_pair+1)begin: owner_mux_group
  if(owner_pair*2+1<CLIENTS)begin: full_pair
   assign grouped_data[owner_pair*256+:256]=owner_lane[owner_pair] ?
    bank_data[(owner_pair*2+1)*256+:256] : bank_data[(owner_pair*2)*256+:256];
   assign grouped_mask[owner_pair*32+:32]=owner_lane[owner_pair] ?
    bank_mask[(owner_pair*2+1)*32+:32] : bank_mask[(owner_pair*2)*32+:32];
  end else begin: final_single
   // Preserve out-of-range selection as unknown rather than inventing an
   // additional legal client. Reachable grants always select an actual bank.
   assign grouped_data[owner_pair*256+:256]=owner_lane[owner_pair] ?
    256'bx : bank_data[(owner_pair*2)*256+:256];
   assign grouped_mask[owner_pair*32+:32]=owner_lane[owner_pair] ?
    32'bx : bank_mask[(owner_pair*2)*32+:32];
  end
 end endgenerate
 reg [QUOTA_BITS-1:0] emergency_run;
 integer chosen, normal_choice, urgent_choice;
 integer i, j, k, byte_count;
 reg verify_failed, verify_mismatch;
 integer verify_byte;
 reg [4:0] beat_index;
 wire [31:0] selected_addr=addr[owner];
 // Sole byte -> physical x32 word conversion. Column rollover is forbidden;
 // planner splits at 4096 byte boundaries (1024 physical column addresses).
 assign awaddr=selected_addr[29:2];
 assign araddr=selected_addr[29:2];
 assign awlen=beats[owner]-1'b1, arlen=beats[owner]-1'b1;
 assign awid=4'd0, arid=4'd0;
 assign awvalid=(state==WA), arvalid=(state==RA || state==VERIFY_ADDR);
 assign native_wdata=selected_data;
 assign native_wstrb=(state==WD) ? selected_mask : 32'd0;
 assign req_ready=~pending & {CLIENTS{controller_ready && !fault}};

 // Compare every enabled byte against the reserved write bank. A last-word
 // comparison alone cannot prove earlier writes visible without an ordering
 // guarantee. Failed readback quarantines the fabric until joint cold reset.
 always @* begin
  verify_mismatch=0;
  for(verify_byte=0;verify_byte<32;verify_byte=verify_byte+1)
   if(selected_mask[verify_byte] &&
      native_rdata[verify_byte*8+:8]!=selected_data[verify_byte*8+:8])
    verify_mismatch=1;
 end

 // Purpose: prefetch the post-edge native cursor into synchronous block RAM.
 // This duplicates only the small address next-state expression, not payload
 // storage. WD and readback still consume one beat per native handshake.
 reg [4:0] next_beat_index;
 always @* begin
  next_beat_index=beat_index;
  if(!rst_n) next_beat_index=0;
  // No write/readback payload is consumed in IDLE. Keep all write-bank
  // prefetches at beat zero even before an owner wins arbitration, removing
  // eligible/loaded -> arbiter -> RAM address from the synchronous read path.
  // Accepted ownership already resets beat_index to zero; read-client cursors
  // use next_consumed independently and preserve their stalled output data.
  else if(state==IDLE) next_beat_index=0;
  else if(state==WD && native_wready) begin
   if(beat_index==beats[owner]-1'b1) begin
    if(VERIFY_WRITES) next_beat_index=0;
   end else next_beat_index=beat_index+1'b1;
  end else if((state==RD || state==VERIFY_DATA) && native_rvalid &&
              beat_index!=beats[owner]-1'b1) next_beat_index=beat_index+1'b1;
 end

 // Each client retains its own complete reservation. Payload uses dedicated
 // block RAM; the much smaller masks retain asynchronous distributed reads.
 // Read outputs are exposed only after one settling edge following returned.
 // Thus a one-beat read cannot expose old RAM data on its final write edge;
 // no device-dependent mixed-port read-during-write mode is assumed.
 reg [CLIENTS-1:0] returned_settled;
 genvar g;
 generate for(g=0;g<CLIENTS;g=g+1) begin: client_bank
  assign eligible[g]=pending[g] && !done[g] && !aborted[g] && !returned[g] &&
   (!is_write[g] || loaded[g]==beats[g]);
  reg [255:0] payload[0:MAX_BEATS-1] /* synthesis syn_ramstyle="block_ram" */;
  reg [31:0] masks[0:MAX_BEATS-1] /* synthesis syn_ramstyle="lut_ram" */;
  reg [255:0] payload_q;
  reg [INDEX_BITS-1:0] prefetch_index;
  reg next_is_write;
  reg [4:0] next_consumed;
  always @* begin
   next_is_write=is_write[g]; next_consumed=consumed[g];
   if(!rst_n) begin next_is_write=0; next_consumed=0; end
   else begin
    if(req_valid[g] && req_ready[g]) begin
     next_is_write=req_write[g]; next_consumed=0;
    end
    if(r_valid[g] && r_ready[g]) next_consumed=consumed[g]+1'b1;
   end
   prefetch_index=next_is_write ? next_beat_index[INDEX_BITS-1:0] :
                                  next_consumed[INDEX_BITS-1:0];
  end
  // A single write port and synchronous read infer the official simple
  // dual-port template. Payload and output registers intentionally have no
  // reset; descriptor/control reset prevents access before a complete fill.
  always @(posedge clk) begin
   if(w_valid[g] && w_ready[g]) begin
    payload[loaded[g][INDEX_BITS-1:0]]<=w_data[g*256+:256];
    masks[loaded[g][INDEX_BITS-1:0]]<=w_strb[g*32+:32];
   end else if(state==RD && native_rvalid && owner==g)
    payload[beat_index[INDEX_BITS-1:0]]<=native_rdata;
   payload_q<=payload[prefetch_index];
  end
  assign bank_data[g*256+:256]=payload_q;
  assign bank_mask[g*32+:32]=masks[beat_index[INDEX_BITS-1:0]];
 end endgenerate

 // Purpose: quota-limited urgent selection; every third selection is normal
 // round robin. A continuously eligible client is served within
 // CLIENTS*(EMERGENCY_QUOTA+1) grants, assuming controller service progresses.
 // Incomplete write buffers are not eligible and cannot block ready clients.
 always @* begin
  w_ready=0; r_valid=0; r_data=0; r_last=0;
  normal_choice=-1; urgent_choice=-1;
  for(j=0;j<CLIENTS;j=j+1) begin
   k=rr+j; if(k>=CLIENTS) k=k-CLIENTS;
   // rr+j is reduced into 0..CLIENTS-1 before the narrow array selection.
   if(eligible[k[CLIENT_BITS-1:0]]) begin
    if(normal_choice<0) normal_choice=k;
    if(urgent[k[CLIENT_BITS-1:0]] && urgent_choice<0) urgent_choice=k;
   end
   w_ready[j]=pending[j] && is_write[j] && !done[j] && !aborted[j] && loaded[j]<beats[j];
   r_valid[j]=returned[j] && returned_settled[j] && !aborted[j] && !cancel[j] && consumed[j]<beats[j];
   r_data[j*256+:256]=bank_data[j*256+:256];
   r_last[j]=r_valid[j] && consumed[j]==beats[j]-1'b1;
  end
  chosen=normal_choice;
  if(urgent_choice>=0 && emergency_run<EMERGENCY_QUOTA) chosen=urgent_choice;
 end

 // Purpose: descriptor ownership persists until completion ACK. Reads complete
 // only after every buffered response is consumed (or discarded by cancellation).
 // Protocol faults stop admission/issuance; only joint controller reset recovers.
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   returned_settled<=0;
   state<=IDLE; pending<=0; is_write<=0; aborted<=0; returned<=0;
   done<=0; cancelled<=0; error<=0; done_tag<=0; fault<=0;
   write_verified<=0; verify_failed<=0;
   owner<=0; owner_lane<=0; owner_group<=0; rr<=0; emergency_run<=0; beat_index<=0;
   max_wait_cycles<=0; bus_bytes<=0; useful_write_bytes<=0;
   for(i=0;i<CLIENTS;i=i+1) begin
    addr[i]<=0; beats[i]<=1; loaded[i]<=0; consumed[i]<=0; tag[i]<=0; wait_cycles[i]<=0;
   end
  end else begin
   // One complete read-port edge precedes client visibility.
   returned_settled<=returned;
   if(!controller_ready && (pending!=0 || state!=IDLE)) fault<=1;
   for(i=0;i<CLIENTS;i=i+1) begin
    if(done[i] && done_ready[i]) begin
     pending[i]<=0; done[i]<=0; returned[i]<=0;
    end
    if(req_valid[i] && req_ready[i]) begin
     pending[i]<=1; is_write[i]<=req_write[i]; aborted[i]<=0; returned[i]<=0;
     addr[i]<=req_addr[i*32+:32]; beats[i]<=req_beats[i*5+:5];
     tag[i]<=req_tag[i*TAG_BITS+:TAG_BITS]; done_tag[i*TAG_BITS+:TAG_BITS]<=req_tag[i*TAG_BITS+:TAG_BITS];
     loaded[i]<=0; consumed[i]<=0; wait_cycles[i]<=0; error[i]<=0; cancelled[i]<=0;
     write_verified[i]<=0;
     // Full bus span must stay in configured capacity and physical column.
     if(req_beats[i*5+:5]==0 || req_beats[i*5+:5]>MAX_BEATS ||
        req_addr[i*32+:5]!=0 ||
        {1'b0,req_addr[i*32+:32]}+({28'd0,req_beats[i*5+:5]}<<5)>{1'b0,CAPACITY_BYTES} ||
        {1'b0,req_addr[i*32+:12]}+({8'd0,req_beats[i*5+:5]}<<5)>13'd4096 ||
        (i==CLIENTS-1 && !allow_snapshot)) begin
      done[i]<=1; error[i]<=1;
     end
    end
    if(w_valid[i] && w_ready[i]) begin
     loaded[i]<=loaded[i]+1'b1;
    end
    if(pending[i] && !done[i] && !returned[i] && !(state!=IDLE && owner==i)) begin
     if(wait_cycles[i]!=32'hffffffff) wait_cycles[i]<=wait_cycles[i]+1'b1;
    end
    // Do not withdraw a VALID address, even if cancelled before acceptance.
    if(cancel[i] && pending[i] && !done[i]) begin
     aborted[i]<=1; cancelled[i]<=1;
     if(!(state!=IDLE && owner==i)) begin done[i]<=1; returned[i]<=0; end
    end
    if(r_valid[i] && r_ready[i]) begin
     consumed[i]<=consumed[i]+1'b1;
     if(consumed[i]==beats[i]-1'b1) begin done[i]<=1; returned[i]<=0; end
    end
   end
   case(state)
    IDLE: if(chosen>=0 && !fault && controller_ready && !cancel[chosen[CLIENT_BITS-1:0]]) begin
     // The same accepted grant installs all group-local selectors, with
     // no new arbitration edge or native beat of latency.
     owner_lane<={OWNER_GROUPS{chosen[0]}};
     owner_group<=chosen[CLIENT_BITS-1:0]>>1;
     owner<=chosen[CLIENT_BITS-1:0]; beat_index<=0; state<=is_write[chosen[CLIENT_BITS-1:0]] ? WA : RA;
     if(wait_cycles[chosen[CLIENT_BITS-1:0]]>max_wait_cycles[chosen[CLIENT_BITS-1:0]*32+:32])
      max_wait_cycles[chosen[CLIENT_BITS-1:0]*32+:32]<=wait_cycles[chosen[CLIENT_BITS-1:0]];
     // Urgent grants must not move the NORMAL cursor; doing so could repeatedly
     // skip the same ordinary clients even with a finite emergency quota.
     if(chosen==urgent_choice && emergency_run<EMERGENCY_QUOTA) emergency_run<=emergency_run+1;
     else begin emergency_run<=0; rr<=(chosen==CLIENTS-1) ? 0 : chosen+1; end
    end
    WA: if(awready) state<=WD;
    WD: if(native_wready) begin
     bus_bytes[owner*32+:32]<=bus_bytes[owner*32+:32]+32;
     byte_count=0;
     for(i=0;i<32;i=i+1) byte_count=byte_count+selected_mask[i];
     useful_write_bytes[owner*32+:32]<=useful_write_bytes[owner*32+:32]+byte_count;
     if(native_wid!=0 || native_wlast!=(beat_index==beats[owner]-1'b1)) begin
      error[owner]<=1; fault<=1;
     end
     if(beat_index==beats[owner]-1'b1) begin
      if(VERIFY_WRITES) begin
       state<=VERIFY_ADDR; beat_index<=0; verify_failed<=0;
      end else begin
       state<=IDLE; done[owner]<=1; cancelled[owner]<=aborted[owner] || cancel[owner];
      end
     end else beat_index<=beat_index+1'b1;
    end
    // Readback remains internal: no client read VALID or backpressure is used.
    // Even a cancelled write drains this fence before its slot can be recycled.
    VERIFY_ADDR: if(arready) state<=VERIFY_DATA;
    VERIFY_DATA: if(native_rvalid) begin
     bus_bytes[owner*32+:32]<=bus_bytes[owner*32+:32]+32;
     if(verify_mismatch || native_rid!=0 || native_rlast!=(beat_index==beats[owner]-1'b1)) begin
      verify_failed<=1; error[owner]<=1; fault<=1;
     end
     if(beat_index==beats[owner]-1'b1) begin
      state<=IDLE; done[owner]<=1; cancelled[owner]<=aborted[owner] || cancel[owner];
      write_verified[owner]<=!verify_failed && !verify_mismatch && !error[owner] &&
       native_rid==0 && native_rlast;
     end else beat_index<=beat_index+1'b1;
    end
    RA: if(arready) state<=RD;
    RD: if(native_rvalid) begin
     bus_bytes[owner*32+:32]<=bus_bytes[owner*32+:32]+32;
     if(native_rid!=0 || native_rlast!=(beat_index==beats[owner]-1'b1)) begin
      error[owner]<=1; fault<=1;
     end
     if(beat_index==beats[owner]-1'b1) begin
      state<=IDLE;
      if(aborted[owner] || cancel[owner] || error[owner] || native_rid!=0 || !native_rlast) begin
       done[owner]<=1; returned[owner]<=0; cancelled[owner]<=aborted[owner] || cancel[owner];
      end else returned[owner]<=1;
     end else beat_index<=beat_index+1'b1;
    end
    default: begin state<=IDLE; fault<=1; end
   endcase
  end
 end
endmodule

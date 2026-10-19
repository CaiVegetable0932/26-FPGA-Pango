`timescale 1ns/1ps
// Keep 32 complete validated STATE snapshots, newest replaces oldest on full.
// Select latest sample not later than exposure reference; no cross-source/boot
// interpolation is attempted. Invalid latest pose is explicit degradation,
// never concealed by searching farther back for a good old angle.
// Whole source-frame result remains stable until ACK. Geometry mapping and
// camera extrinsics are external; this module never calls yaw image-plane roll.
module pose_frame_selector #(parameter DEPTH=32,MAX_AGE_US=20000,MAX_ERROR_US=1000,MAX_DRIFT_PPM=200)(
 input clk,input rst_n,input clear,input state_valid,input [767:0] state_payload,
 input [63:0] receive_us,input mapping_valid,input signed [63:0] clock_offset_us,
 input [31:0] clock_error_us,
 input [63:0] sync_received_us,
 input frame_valid,output frame_ready,input [63:0] epoch,frame_id,exposure_us,
 output reg result_valid,input result_ready,output reg [63:0] result_epoch,result_frame,
 output reg [767:0] result_state,output reg [63:0] result_receive_us,
 output reg [31:0] age_us,error_us,output reg [2:0] status,
 output reg [31:0] invalid_states,overwrites,degraded_frames
);
 // status: 0 usable approximate mapping, 1 no samples, 2 unmapped,
 // 3 stale/uncertain, 4 invalid angles/config/source. No status means q_wc.
 reg [767:0] samples [0:DEPTH-1];reg [63:0] arrival [0:DEPTH-1];
 integer wr,count,scan,left;
 reg busy;reg [1:0] row_stage;reg [63:0] mapped_tick;reg candidate_valid;
 reg [767:0] q,best;reg [63:0] qt,best_arrival,target,best_tick;
 reg found,map_ok;reg signed [63:0] offset_q;reg [31:0] error_q;
 reg [1:0] timing_step;reg [63:0] sync_anchor,timing_delta;
 reg [31:0] error_base;reg map_requested;
 localparam DRIFT_PER_4096_US=(MAX_DRIFT_PPM*4096+999999)/1000000;
 wire [32:0] bounded_error={1'b0,error_base}+
  ((({12'd0,timing_delta[20:0]}+4095)>>12)*DRIFT_PER_4096_US);
 // An invalid new snapshot blocks reuse of older valid angles at its arrival
 // time. Arrival is a degradation boundary only, never a measurement timestamp.
 wire angles_valid=q[163+:2]==2'b11;
 wire [63:0] tick=angles_valid ? ($signed(q[480+:64])+offset_q) : qt;
 wire [31:0] flags=state_payload[160+:32];
 wire layout_ok=state_payload[544+:96]==0 && flags[31:12]==0 &&
  state_payload[704+:8]<=31 && state_payload[712+:8]<=31 &&
  state_payload[720+:8]<64 && state_payload[728+:8]<16 &&
  state_payload[736+:8]!=4 && state_payload[736+:8]<=5 && state_payload[744+:8]<=3 &&
  state_payload[752+:16]<=11;
 integer i;reg source_ok;
 // Check every valid field, including normalized XYZ range and source enums.
 always @* begin
  source_ok=layout_ok;
  for(i=0;i<3;i=i+1) if(state_payload[720+i*2+:2]==3 || flags[i] &&
    ($signed(state_payload[320+i*32+:32])<0 || $signed(state_payload[320+i*32+:32])>100000000 ||
     state_payload[720+i*2+:2]==0 || state_payload[720+i*2+:2]==3)) source_ok=0;
  for(i=0;i<2;i=i+1) if(state_payload[728+i*2+:2]==3 || flags[i+3] &&
    (!flags[6] || state_payload[480+:64]==0 || state_payload[728+i*2+:2]==0 ||
     state_payload[728+i*2+:2]==3)) source_ok=0;
 end
 assign frame_ready=!busy && !result_valid;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) begin
   wr<=0;count<=0;scan<=0;left<=0;busy<=0;row_stage<=0;mapped_tick<=0;candidate_valid<=0;q<=0;qt<=0;best<=0;
   best_arrival<=0;target<=0;best_tick<=0;found<=0;map_ok<=0;offset_q<=0;error_q<=0;
   result_valid<=0;result_epoch<=0;result_frame<=0;result_state<=0;result_receive_us<=0;
   timing_step<=0;sync_anchor<=0;timing_delta<=0;error_base<=0;map_requested<=0;
   age_us<=0;error_us<=0;status<=1;invalid_states<=0;overwrites<=0;degraded_frames<=0;
  end else if(clear) begin
   wr<=0;count<=0;busy<=0;result_valid<=0; // revoke pending result on boot/session change.
  end else begin
   if(result_valid && result_ready) result_valid<=0;
   // Selection freezes the queue briefly (<=99 cycles), STATE byte parsing is
   // independent. Collision explicitly counts dropped snapshot; never stalls RX.
   if(state_valid) begin
    if(!source_ok || busy) invalid_states<=invalid_states+1;
    else begin
     samples[wr]<=state_payload;arrival[wr]<=receive_us;
     wr<=(wr==DEPTH-1)?0:wr+1;
     if(count<DEPTH) count<=count+1;else overwrites<=overwrites+1;
    end
   end
   if(frame_valid && frame_ready) begin
    result_epoch<=epoch;result_frame<=frame_id;target<=exposure_us;
    offset_q<=clock_offset_us;map_requested<=mapping_valid;error_base<=clock_error_us;
    sync_anchor<=sync_received_us;timing_step<=2;
    busy<=1;row_stage<=0;left<=count;scan<=0;found<=0;best<=0;best_tick<=0;best_arrival<=0;
   end else if(busy) begin
    if(timing_step==2) begin
     timing_delta<=target>=sync_anchor ? target-sync_anchor : sync_anchor-target;
     timing_step<=1;
    end else if(timing_step==1) begin
     // Use a conservative power-of-two drift envelope instead of a large
     // combinational divider. Default 200ppm is bounded by 1us per 4096us.
     // Absolute sync age covers historical frame exposures too; saturate errors.
     map_ok<=map_requested && timing_delta<=2000000;
     error_q<=bounded_error[32]?32'hffffffff:bounded_error[31:0];timing_step<=0;
    end else if(left==0) begin
     busy<=0;result_valid<=1;result_state<=best;result_receive_us<=best_arrival;
     error_us<=error_q;
     age_us<=found && target-best_tick<=32'hffffffff ? target-best_tick : 32'hffffffff;
     if(!map_ok) begin status<=2;degraded_frames<=degraded_frames+1;end
     else if(!found) begin status<=1;degraded_frames<=degraded_frames+1;end
     else if(target-best_tick+error_q>MAX_AGE_US || error_q>MAX_ERROR_US) begin status<=3;degraded_frames<=degraded_frames+1;end
     else if(best[163+:2]!=2'b11 || !best[166] || !best[167] ||
             best[728+:2]==0 || best[730+:2]==0 || best[744+:8]<2) begin status<=4;degraded_frames<=degraded_frames+1;end
     else status<=0;
    end else case(row_stage)
     0: begin q<=samples[scan];qt<=arrival[scan];row_stage<=1;end
     // Register mapped time after synchronous RAM read. Keep the whole q/tag
     // unchanged through comparison, isolating 64-bit mapping from lookup mux.
     1: begin mapped_tick<=tick;candidate_valid<=!angles_valid || q[480+:64]!=0;row_stage<=2;end
     2: begin
      if(candidate_valid && mapped_tick<=target && (!found || mapped_tick>=best_tick)) begin
       found<=1;best<=q;best_tick<=mapped_tick;best_arrival<=qt;
      end
      scan<=scan+1;left<=left-1;row_stage<=0;
     end
     default: row_stage<=0;
    endcase
   end
  end
 end
endmodule

`timescale 1ns/1ps
// CAMERA_CONFIG schema1: fixed, stopped AE, or continuous group AE candidate.
// First admission after register readback is a configuration association;
// optical exposure-frame timing remains explicitly unverified in every mode.
// A manual-only build rejects automatic modes explicitly; stopped, verified
// exposure/gain writes and their source-version association remain available.
module camera_brightness_control #(parameter DRAIN_TIMEOUT=125000000,SUPPORT_AUTO=1,PIPELINED_VALIDATION=0)(
 input clk,rst_n,submit_valid,input [383:0] body,input [31:0] version,entity_id,
 output reg [7:0] submit_code,output reg [2303:0] status,
 input source_quiesced,output pause_capture,
 output apply_valid,output continuous,input apply_ready,output [19:0] exposure,output [9:0] gain,
 input apply_done,input [2:0] apply_error,
 input capture_boundary,input [63:0] capture_epoch,capture_frame,
 input statistics_valid,input [47:0] luminance_sum,input [31:0] samples,
 output [31:0] capture_camera_version,output auto_stable
);
 localparam IDLE=0,DRAIN=1,SEND=2,WAIT=3,BOUNDARY=4,FAILED=5;
 reg [2:0] state;reg [383:0] active,queued;
 reg [31:0] av,aid,qv,qid,deadline;reg [63:0] applied_epoch,applied_frame;
 reg [7:0] error_code;reg [15:0] held,settled;
 reg legal,period_min_ok,period_max_ok,period_exp_ok;integer i;
 wire [31:0] period=body[288+:32];wire [31:0] line_ns=body[256+:32];
 wire timing_valid,timing_legal;
 generate if(!PIPELINED_VALIDATION)begin:combinational_validation
  // Preserve the legacy immediate interface for existing standalone users.
  // Upper raw bits are rejected by the format checks before any acceptance.
  wire [34:0] period_lines=period[14:0]*line_ns[19:0];
  wire [42:0] period_product=period_lines*8'd150;
  wire [27:0] period_tolerance=line_ns[19:0]*8'd150;
  assign timing_valid=1'b1;
  assign timing_legal=period_product+period_tolerance>=43'd16000000000 &&
                      period_product<=43'd16000000000+period_tolerance;
 end else begin:sequential_validation
  // Bind the expensive arithmetic to its exact 64 raw input bits. Other body
  // fields, version and consumer state remain checked live below; changing
  // either arithmetic input immediately revokes a cached result. No UART
  // pacing assumption or full-body snapshot is needed for this proof.
  reg [31:0] frozen_period,frozen_line;
  reg busy,cached,accepted;reg [2:0] phase;
  reg [27:0] tolerance_lo,tolerance;reg [22:0] tolerance_hi;
  reg [30:0] product_lo;reg [26:0] product_hi;
  reg [42:0] product;
  reg signed [43:0] residual;
  // Reassociate exact integer multiplication: line*150 is two registered
  // shift/add levels; period*(line*150) uses one shared 15x16 multiplier in
  // two cycles, followed by a registered partial-product sum. There is never
  // more than one APM multiplication between registers.
  wire [15:0] multiplier_b=phase==3?tolerance[15:0]:{4'd0,tolerance[27:16]};
  wire [30:0] partial=frozen_period[14:0]*multiplier_b;
  wire residual_fits29=residual[43:28]=={16{residual[28]}};
  wire signed [28:0] signed_tolerance=$signed({1'b0,tolerance});
  assign timing_valid=cached && frozen_period==period && frozen_line==line_ns;
  assign timing_legal=timing_valid && accepted;
  // Seven arithmetic cycles plus capture; a newly stable input completes in
  // at most 15 clocks including an older calculation already in flight.
  // Tolerance is <2^28 even for all truncated 20-bit inputs, so narrowing
  // the final signed interval comparison to 29 bits is exact after sign-fit.
  always @(posedge clk or negedge rst_n)begin
   if(!rst_n)begin
    frozen_period<=0;frozen_line<=0;busy<=0;cached<=0;accepted<=0;phase<=0;
    tolerance_lo<=0;tolerance_hi<=0;tolerance<=0;product_lo<=0;product_hi<=0;product<=0;residual<=0;
   end else if(!busy)begin
    if(!cached || frozen_period!=period || frozen_line!=line_ns)begin
     frozen_period<=period;frozen_line<=line_ns;busy<=1;cached<=0;phase<=1;
    end
   end else case(phase)
    1:begin
     tolerance_lo<={1'b0,frozen_line[19:0],7'd0}+{4'd0,frozen_line[19:0],4'd0};
     tolerance_hi<={1'b0,frozen_line[19:0],2'd0}+{2'd0,frozen_line[19:0],1'b0};phase<=2;
    end
    2:begin tolerance<=tolerance_lo+{5'd0,tolerance_hi};phase<=3;end
    3:begin product_lo<=partial;phase<=4;end
    4:begin product_hi<=partial[26:0];phase<=5;end
    5:begin product<={12'd0,product_lo}+{product_hi,16'd0};phase<=6;end
    6:begin residual<=$signed({1'b0,product})-44'sd16000000000;phase<=7;end
    7:begin
     accepted<=residual_fits29 && $signed(residual[28:0])>=-signed_tolerance &&
               $signed(residual[28:0])<=signed_tolerance;
     cached<=1;busy<=0;
    end
   endcase
  end
 end endgenerate
 // Multiples are explicitly sized before comparison; the legal domain below
 // rejects values above 17856, and four 15-bit periods cannot overflow 17 bits.
 wire [16:0] period_multiple[1:4];
 assign period_multiple[1]={2'd0,period[14:0]};
 assign period_multiple[2]={1'd0,period[14:0],1'd0};
 assign period_multiple[3]=period_multiple[1]+period_multiple[2];
 assign period_multiple[4]={period[14:0],2'd0};
 reg [383:0] canonical_body;
 always @*begin
  canonical_body=body;canonical_body[7:2]=0;canonical_body[15:9]=0;
  // The validator rejects automatic modes in a manual-only build. Literal
  // mode storage also eliminates unreachable group/automatic state muxes.
  if(!SUPPORT_AUTO)canonical_body[7:0]=0;
  canonical_body[63:47]=0;canonical_body[79:74]=0;canonical_body[95:90]=0;canonical_body[111:106]=0;canonical_body[127:119]=0;
  canonical_body[159:143]=0;canonical_body[191:175]=0;canonical_body[223:207]=0;canonical_body[383:352]=0;
 end
 always @*begin
  legal=body[7:0]<=2 && body[15:8]<=1 && body[23:16]<body[31:24] && body[352+:32]==0 &&
   body[32+:32]>=16 && body[32+:32]<=17856 && body[64+:16]>=16 && body[64+:16]<=1023 &&
   body[80+:16]>=16 && body[96+:16]>=body[80+:16] && body[96+:16]<=1023 &&
   body[112+:16]>=1 && body[112+:16]<=64 && body[128+:32]>=16 &&
   body[160+:32]>=body[128+:32] && body[160+:32]<=17856 &&
   body[32+:32]>=body[128+:32] && body[32+:32]<=body[160+:32] &&
   body[64+:16]>=body[80+:16] && body[64+:16]<=body[96+:16] &&
   body[192+:32]>=1 && body[192+:32]<=17856 && body[224+:16]>=1 && body[240+:16]>=2;
  // Up to four 150 Hz periods fit the fixed 30-fps exposure envelope. Validate
  // all endpoints with comparisons, without synthesizing a variable divider.
  period_min_ok=0;period_max_ok=0;period_exp_ok=0;
  for(i=1;i<=4;i=i+1)begin
   if(body[128+:32]==period_multiple[i])period_min_ok=1;
   if(body[160+:32]==period_multiple[i])period_max_ok=1;
   if(body[32+:32]==period_multiple[i])period_exp_ok=1;
  end
  if(body[15:8]==1 && (period==0 || period>17856 || line_ns==0 || line_ns>1000000 || body[320+:32]==0 ||
   !period_min_ok || !period_max_ok || !period_exp_ok || (timing_valid && !timing_legal)))legal=0;
  if(!SUPPORT_AUTO && body[7:0]!=0)legal=0;
  submit_code=!legal || (state==FAILED && body[7:0]==2) || version<=av || version[31] || entity_id==0 || entity_id[31]?11:
   (body[15:8]==1 && !timing_valid)?8'hff:
   (state!=IDLE && (state!=FAILED || !apply_ready || queued[7:0]==2))?4:0;
  status=0;status[15:0]=1;status[31:16]=7;status[32+:32]=av;status[64+:32]=aid;status[96+:16]=48;
  // Flag2 states that exposure-frame association is unverified. Header source
  // identity is first admission after readback, never measured integration time.
  status[112+:8]={5'd0,1'b1,(state!=IDLE && state!=FAILED),1'b1};status[120+:8]=error_code;
  status[128+:64]=applied_epoch;status[192+:64]=applied_frame;status[256+:384]=active;
 end
 assign continuous=SUPPORT_AUTO && queued[7:0]==2;
 // Uncertain failed groups quarantine capture; live retries are forbidden.
 assign pause_capture=state==FAILED || (!continuous && (state==DRAIN || state==SEND || state==WAIT));
 assign apply_valid=state==SEND,exposure=queued[32+:20],gain=queued[64+:10];
 assign capture_camera_version=state==BOUNDARY?qv:av;
 // Other automatic loops run only after settling and while AE has no
 // pending correction, so they cannot race an exposure step on the same frame.
 assign auto_stable=state==IDLE && settled>=active[240+:16] &&
  (!SUPPORT_AUTO || active[7:0]==0 || (next_exposure==active[32+:15] && next_gain==active[64+:10]));
 reg [14:0] next_exposure,step;reg [9:0] next_gain;
 wire [15:0] exposure_plus_step={1'b0,active[32+:15]}+{1'b0,step};
 wire [15:0] minimum_plus_step={1'b0,active[128+:15]}+{1'b0,step};
 wire [10:0] gain_plus_step={1'b0,active[64+:10]}+{4'd0,active[112+:7]};
 wire [10:0] gain_minimum_plus_step={1'b0,active[80+:10]}+{4'd0,active[112+:7]};
 always @*begin
  next_exposure=active[32+:15];next_gain=active[64+:10];step=active[15:8]==1?active[288+:15]:active[192+:15];
  // Exposure changes before analog gain; bright scenes shed gain first.
  if(samples!=0 && luminance_sum<active[23:16]*{16'd0,samples})begin
   if(next_exposure<active[160+:15])next_exposure=exposure_plus_step>{1'b0,active[160+:15]}?active[160+:15]:exposure_plus_step[14:0];
   else if(next_gain<active[96+:10])next_gain=gain_plus_step>{1'b0,active[96+:10]}?active[96+:10]:gain_plus_step[9:0];
  end else if(samples!=0 && luminance_sum>active[31:24]*{16'd0,samples})begin
   if(next_gain>active[80+:10])next_gain={1'b0,next_gain}<gain_minimum_plus_step?active[80+:10]:next_gain-active[112+:7];
   else if(next_exposure>active[128+:15])next_exposure={1'b0,next_exposure}<minimum_plus_step?active[128+:15]:next_exposure-step;
  end
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   state<=IDLE;active<=0;active[23:16]<=96;active[31:24]<=144;active[32+:32]<=10752;active[64+:16]<=16;
   active[80+:16]<=16;active[96+:16]<=64;active[112+:16]<=1;active[128+:32]<=16;active[160+:32]<=17856;
   active[192+:32]<=256;active[224+:16]<=16;active[240+:16]<=10;
   queued<=0;av<=1;aid<=1;qv<=0;qid<=0;deadline<=0;applied_epoch<=0;applied_frame<=0;error_code<=0;held<=0;settled<=0;
  end else begin
   if(state==DRAIN || state==SEND || state==WAIT)deadline<=deadline+1'b1;else deadline<=0;
   if((state==DRAIN || state==SEND || state==WAIT) && deadline>=DRAIN_TIMEOUT-1)begin state<=FAILED;error_code<=2;end
   else case(state)
    DRAIN:if(source_quiesced)state<=SEND;
    SEND:if(apply_ready)state<=WAIT;
    WAIT:if(apply_done)begin
     if(apply_error!=0)begin state<=FAILED;error_code<={5'd0,apply_error};end
     else begin state<=BOUNDARY;error_code<=0;end
    end
    BOUNDARY:if(capture_boundary)begin active<=queued;av<=qv;aid<=qid;applied_epoch<=capture_epoch;applied_frame<=capture_frame;held<=0;settled<=0;state<=IDLE;end
    default:;
   endcase
   if(submit_valid && submit_code==0)begin queued<=canonical_body;qv<=version;qid<=entity_id;state<=SUPPORT_AUTO && body[7:0]==2?SEND:DRAIN;error_code<=0;deadline<=0;end
   // Discard a configurable number of legal completed frames after each
   // restart, then enforce a deadband and bounded hold between AE steps.
   if(statistics_valid && state==IDLE && !submit_valid && samples!=0 && av<32'h7fffffff)begin
    if(settled<active[240+:16])settled<=settled+1'b1;
    else if(SUPPORT_AUTO && active[7:0]!=0 && held<active[224+:16])held<=held+1'b1;
    else if(SUPPORT_AUTO && active[7:0]!=0 && (next_exposure!=active[32+:32] || next_gain!=active[64+:16]))begin
     queued<=active;queued[32+:32]<=next_exposure;queued[64+:16]<=next_gain;qv<=av+1'b1;qid<=aid;state<=active[7:0]==2?SEND:DRAIN;held<=0;
    end
   end
  end
 end
endmodule

`timescale 1ns/1ps
// PC raw-pose transaction owner. Configuration is static installation data;
// A7 carries encoder millidegrees unchanged. ACK follows solver success and
// enqueue into the existing frame-atomic geometry bank, never a live mux.
module pc_raw_pose_control(input clk,rst_n,
 input config_submit,input [1023:0] config_body,input [31:0] config_version,config_id,
 output [7:0] config_code,output reg [2303:0] config_status,
 input request_valid,input [15:0] request_sequence,input [415:0] request_body,
 output reg response_valid,output reg [7:0] response_code,output reg [767:0] pose_status,
 input [767:0] geometry_status,reference_status,affine_status,
 output geometry_valid,input geometry_ready,output [543:0] geometry,
 output [31:0] geometry_version,geometry_id);
 localparam IDLE=0,GUARD=1,GUARD_WAIT=2,SOLVE=3,SOLVE_WAIT=4,ENQUEUE=5,FINISH=6,HOLD=7;
 reg [2:0] state;reg cfg_valid,last_valid;reg [31:0] cv,cid;
 reg [1023:0] cfg,checked;reg layout_ok;reg [415:0] raw,last_raw;
 reg [15:0] sequence_saved,last_sequence;reg [7:0] last_code;
 reg [543:0] held_geometry;reg [191:0] held_reference;reg [15:0] width,height;
 reg [31:0] solved_version,solved_sample;reg [15:0] watchdog;
 wire guard_ready,guard_valid,guard_ok;wire [383:0] guarded;
 reg [383:0] lo,hi;integer i;
 wire solver_ready,solver_valid,solver_ok;wire [287:0] solved;
 // Preserve LUT-sized comparison boundaries. A 1024-bit equality otherwise
 // becomes a 512-cell ADS carry chain. These are combinational comparisons:
 // every changed staging bit still revokes a cached result in the same cycle.
 wire config_matches,retry_matches;
 raw_pose_exact_match #(.WIDTH(1024)) config_match(checked,config_body,config_matches);
 raw_pose_exact_match #(.WIDTH(416)) retry_match(last_raw,request_body,retry_matches);
 wire same_sequence=last_valid && last_sequence==request_sequence;
 wire duplicate=same_sequence && retry_matches;
 assign config_code=!config_matches?8'hff:!layout_ok || config_version==0 || config_version[31] ||
  config_version<=cv || config_id==0 || config_id[31]?8'd11:state!=IDLE?8'd4:8'd0;
 // Layout/range checks are cached, so static upload data never feeds a long
 // same-cycle CRC-consumer-ACK chain. Numeric orthonormality is checked by
 // the shared solver before any resulting geometry can be enqueued.
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin checked<=0;layout_ok<=0;end
  else begin
   checked<=config_body;
   layout_ok<=config_body[31:0]==32'h00030001 && config_body[63:32]!=0 &&
    config_body[1023:928]==0 && config_body[416+:32]>=12 && config_body[416+:32]<=1000 &&
    $signed(config_body[192+:32])>=-90000 && $signed(config_body[224+:32])<=90000 &&
    $signed(config_body[256+:32])>=-90000 && $signed(config_body[288+:32])<=90000 &&
    $signed(config_body[192+:32])<=$signed(config_body[224+:32]) &&
    $signed(config_body[256+:32])<=$signed(config_body[288+:32]) &&
    $signed(config_body[128+:32])>=$signed(config_body[192+:32]) &&
    $signed(config_body[128+:32])<=$signed(config_body[224+:32]) &&
    $signed(config_body[160+:32])>=$signed(config_body[256+:32]) &&
    $signed(config_body[160+:32])<=$signed(config_body[288+:32]) &&
    $signed(config_body[64+:32])>=-90000 && $signed(config_body[64+:32])<=90000 &&
    $signed(config_body[96+:32])>=-90000 && $signed(config_body[96+:32])<=90000 &&
    config_body[320+:32]<=100000000 && config_body[352+:32]<=100000000 && config_body[384+:32]<=100000000;
   for(i=0;i<15;i=i+1)if($signed(config_body[448+i*32+:32])< -67108864 ||
                                      $signed(config_body[448+i*32+:32])>67108864)layout_ok<=0;
  end
 end
 always @*begin
  // Signed all-bit bounds for sequence; strict positive versions, normalized
  // positions and exact quality flags. Never reinterpret normalized XYZ as mm.
  lo=0;hi={12{32'h7fffffff}};
  lo[0+:32]=1;lo[32+:32]=1;lo[64+:32]=cfg[192+:32];hi[64+:32]=cfg[224+:32];
  lo[96+:32]=cfg[256+:32];hi[96+:32]=cfg[288+:32];
  for(i=4;i<=6;i=i+1)hi[i*32+:32]=100000000;
  lo[224+:32]=32'h80000000;hi[224+:32]=32'h7fffffff;
  lo[256+:32]=31;hi[256+:32]=31;hi[288+:32]=989;
 end
 parameter_entity_guard #(.WORDS(12)) guard(.clk(clk),.rst_n(rst_n),.submit_valid(state==GUARD),.submit_ready(guard_ready),
  .entity(raw[383:0]),.lower_bounds(lo),.upper_bounds(hi),.expected_crc(raw[384+:32]),
  .format_supported(cfg_valid && raw[32+:32]==cv && raw[128+:96]==cfg[320+:96] &&
    raw[288+:32]+32'd11<=cfg[416+:32]),.result_valid(guard_valid),.result_ready(state==GUARD_WAIT),
  .validated(guard_ok),.result_entity(guarded),.reject_reason());
 raw_pose_solver solver(.clk(clk),.rst_n(rst_n),.request_valid(state==SOLVE),.request_ready(solver_ready),
  .calibration(cfg),.reference_matrix(held_reference),.pitch_mdeg(raw[64+:32]),.yaw_mdeg(raw[96+:32]),
  .width(width),.height(height),.result_valid(solver_valid),.result_ready(state==SOLVE_WAIT),.result_ok(solver_ok),.matrix(solved));
 assign geometry_valid=state==ENQUEUE;
 assign geometry=held_geometry;assign geometry_version=raw[31:0],geometry_id=cid;
 always @*begin
  config_status=0;config_status[15:0]=1;config_status[31:16]=13;
  config_status[32+:32]=cv;config_status[64+:32]=cid;config_status[96+:16]=128;
  config_status[112]=cfg_valid;config_status[256+:1024]=cfg;
  // Readback distinguishes last request/response, queued matrix version and
  // actual geometry-bank source application; failure never masquerades as ON.
  pose_status=0;pose_status[31:0]=32'h31505352;pose_status[32+:32]=cv;
  pose_status[64+:32]=cid;pose_status[96+:32]=solved_version;pose_status[128+:32]=solved_sample;
  pose_status[160+:160]=last_valid?last_raw[64+:160]:160'd0;pose_status[320+:8]=last_code;
  pose_status[328]=state!=IDLE;pose_status[352+:32]=geometry_status[576+:32];
  pose_status[384+:64]=geometry_status[608+:64];pose_status[448+:64]=geometry_status[672+:64];
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;cfg_valid<=0;cv<=0;cid<=0;last_valid<=0;last_sequence<=0;
   response_valid<=0;response_code<=0;last_code<=0;solved_version<=0;solved_sample<=0;watchdog<=0;end
  else begin
   if(config_submit && config_code==0)begin cfg<=config_body;cv<=config_version;cid<=config_id;cfg_valid<=1;end
   if(state!=IDLE && state!=HOLD)watchdog<=watchdog+1'b1;
   // The <4096-cycle calculation bounds computation age to <1 ms at 125 MHz.
   // The 11 ms admission margin also covers a 52B request at 115200 baud.
   if(watchdog==4095 && state!=IDLE && state!=HOLD && state!=FINISH)begin response_code<=4;state<=FINISH;end
   else case(state)
    IDLE:if(request_valid)begin
     watchdog<=0;raw<=request_body;sequence_saved<=request_sequence;response_code<=0;
     if(duplicate)begin response_code<=last_code;state<=HOLD;response_valid<=1;end
     else if(same_sequence)begin response_code<=11;state<=FINISH;end
     else if(!cfg_valid || request_body[31:0]!=geometry_status[576+:32]+1 || request_body[31] ||
       request_body[352+:32]!=geometry_status[576+:32] || request_body[320+:32]!=reference_status[512+:32] ||
       !affine_status[33])begin response_code<=11;state<=FINISH;end
     else if(geometry_status[736] || reference_status[704] || affine_status[34] || !geometry_ready)begin response_code<=4;state<=FINISH;end
     else begin
      held_geometry<=geometry_status[543:0];held_reference<=reference_status[128+:192];
      width<=reference_status[320+:16];height<=reference_status[336+:16];state<=GUARD;
     end
    end
    GUARD:if(guard_ready)state<=GUARD_WAIT;
    GUARD_WAIT:if(guard_valid)begin if(!guard_ok)begin response_code<=11;state<=FINISH;end else state<=SOLVE;end
    SOLVE:if(solver_ready)state<=SOLVE_WAIT;
    SOLVE_WAIT:if(solver_valid)begin
     // Solver shares its work/result bank; solved may change while !valid.
     // Capture only this complete valid result before allowing another solve.
     if(!solver_ok)begin response_code<=11;state<=FINISH;end
     else begin held_geometry[191:0]<=solved[191:0];held_geometry[543:448]<=solved[287:192];state<=ENQUEUE;end
    end
    ENQUEUE:if(geometry_ready)begin solved_version<=raw[31:0];solved_sample<=raw[224+:32];state<=FINISH;end
    FINISH:begin
     // A conflicting retry must not overwrite the last successful transaction.
     if(!last_valid || sequence_saved!=last_sequence)begin
      last_raw<=raw;last_sequence<=sequence_saved;last_valid<=1;last_code<=response_code;
     end
     response_valid<=1;state<=HOLD;
    end
    HOLD:if(!request_valid)begin response_valid<=0;state<=IDLE;end
   endcase
  end
 end
endmodule

// Exact balanced equality for UART calibration/retry stamps. Each three-bit
// leaf fits one LUT6; retained six-way reductions prevent ADS re-concatenation
// into a wide carry comparator. Padding compares zero with zero or ANDs ones.
// syn_keep semantics: installed ADS Synthesis User Guide PDF pages 84-85.
module raw_pose_exact_match #(parameter WIDTH=1024)(input [WIDTH-1:0] a,b,output equal);
 localparam N0=(WIDTH+2)/3,N1=(N0+5)/6,N2=(N1+5)/6,N3=(N2+5)/6;
 wire [N0*3-1:0] pa={{(N0*3-WIDTH){1'b0}},a},pb={{(N0*3-WIDTH){1'b0}},b};
 wire [N0-1:0] leaf;wire [N1-1:0] group1;wire [N2-1:0] group2;wire [N3-1:0] group3;
 wire [N1*6-1:0] pad0={{(N1*6-N0){1'b1}},leaf};
 wire [N2*6-1:0] pad1={{(N2*6-N1){1'b1}},group1};
 wire [N3*6-1:0] pad2={{(N3*6-N2){1'b1}},group2};
 for(genvar n=0;n<N0;n=n+1)begin:triplet
  (* syn_keep=1 *) wire match;assign match=pa[n*3+:3]==pb[n*3+:3];assign leaf[n]=match;
 end
 for(genvar n=0;n<N1;n=n+1)begin:first_reduce
  (* syn_keep=1 *) wire match;assign match=&pad0[n*6+:6];assign group1[n]=match;
 end
 for(genvar n=0;n<N2;n=n+1)begin:second_reduce
  (* syn_keep=1 *) wire match;assign match=&pad1[n*6+:6];assign group2[n]=match;
 end
 for(genvar n=0;n<N3;n=n+1)begin:third_reduce
  (* syn_keep=1 *) wire match;assign match=&pad2[n*6+:6];assign group3[n]=match;
 end
 assign equal=&group3;
endmodule

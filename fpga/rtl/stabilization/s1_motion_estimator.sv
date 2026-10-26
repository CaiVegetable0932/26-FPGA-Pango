`timescale 1ns/1ps
// Passive low-pass S1 observer and bounded three-region SAD matcher. It never
// backpressures capture. A frame is eligible only after its real writer fence.
// Two thumbnail pages hold observations, not resampled or completed pictures.
// Coordinates are RAW S1 pixel coordinates; the consumer must prove its lens
// domain conversion (nonzero distortion is explicitly rejected by integration).
module s1_motion_estimator #(
 parameter WIDTH=1920,HEIGHT=1080,TW=64,TH=36,PATCH=8,
 parameter DX=WIDTH/TW,DY=HEIGHT/TH
)(
 input clk,rst_n,clear,input frame_start,input [63:0] epoch,frame_id,
 input [31:0] colour_version,camera_version,input [255:0] config_entity,
 input pixel_valid,input [15:0] x,y,input [23:0] rgb,input pixel_mask,
 input frame_complete,frame_legal,
 output reg result_valid,output reg [63:0] result_epoch,result_frame,
 output reg signed [31:0] translation_x_q16,translation_y_q16,rotation_q26,scale_delta_q26,
 output reg [15:0] confidence,output reg [3:0] status,output reg [31:0] dropped,cycles
);
 reg [7:0] page0[0:TW*TH-1],page1[0:TW*TH-1];
 localparam SUM_BITS=$clog2(DX*DY*256),ROW_BITS=$clog2(DX*256);
 // First row of EACH low-pass block overwrites this small accumulator RAM.
 // It needs no asynchronous reset or whole-array clear, permitting RAM inference.
 reg [SUM_BITS-1:0] column_sum[0:TW-1] /* synthesis syn_ramstyle="lut_ram" */;
 reg [ROW_BITS-1:0] row_sum;
 localparam signed [31:0] ROTATION_STEP_Q26=(64'sd134217728*DY+WIDTH/2)/WIDTH;
 localparam signed [31:0] SCALE_STEP_Q26=(64'sd134217728*DX+WIDTH/2)/WIDTH;
 wire signed [8:0] rotation_cells=$signed(motion_y[2])-$signed(motion_y[0]);
 wire signed [8:0] scale_cells=$signed(motion_x[2])-$signed(motion_x[0]);
 reg page,have_previous,live,bad,busy;reg [63:0] held_epoch,held_frame,previous_epoch;
 reg [31:0] held_colour,held_camera,previous_colour,previous_camera;
 reg [255:0] cfg;reg [7:0] radius;reg [15:0] min_texture,min_conf;
 reg [31:0] max_sad;reg [1:0] region,phase;
 // Search/raster counters are bounded by the checked configuration. Truncate
 // only addresses already proven within the thumbnail, rather than synthesizing
 // 32-bit integer range muxes for every small RAM read and write.
 localparam ADDRESS_BITS=$clog2(TW*TH),SAD_BITS=$clog2(PATCH*PATCH*256)+1;
 reg signed [4:0] sx,sy;reg [$clog2(PATCH)-1:0] px,py;integer cx,cy;
 reg [ADDRESS_BITS-1:0] addr_cur,addr_prev,write_address;reg [$clog2(TW)-1:0] tc;
 reg [$clog2(DX+1)-1:0] block_x;reg [$clog2(DY+1)-1:0] block_y;
 reg [7:0] qcur,qprev;reg [SAD_BITS-1:0] sad,best,second;
 reg [7:0] lo,hi;reg signed [7:0] best_x,best_y;
 reg signed [7:0] motion_x[0:2],motion_y[0:2];reg [15:0] region_conf[0:2];
 reg match_bad;integer i;
 wire [9:0] weighted={2'b0,rgb[23:16]}+{1'b0,rgb[15:8],1'b0}+{2'b0,rgb[7:0]};
 wire [7:0] luma=weighted[9:2];
 wire [SAD_BITS-1:0] candidate_sad=sad+(qcur>=qprev?qcur-qprev:qprev-qcur);
 wire [SAD_BITS-1:0] margin=second>=best?second-best:0;
 // Address calculation uses constant thumbnail dimensions and bounded signed
 // search indices. PATCH/radius centres keep every candidate inside the page.
 always @*begin
  cx=(region==0?TW/4:region==1?TW/2:3*TW/4)-PATCH/2;cy=TH/2-PATCH/2;
  // Keep offsets signed after narrowing counters: an unsigned patch index
  // would zero-extend negative sx/sy and silently search the wrong row.
  addr_cur=(cy+$signed({1'b0,py}))*TW+cx+$signed({1'b0,px});
  addr_prev=(cy+$signed({1'b0,py})+sy)*TW+cx+$signed({1'b0,px})+sx;
  tc=x/DX;block_x=x%DX;block_y=y%DY;
  write_address=(y/DY)*TW+tc;
 end
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin
   page<=0;have_previous<=0;live<=0;bad<=0;busy<=0;row_sum<=0;
   held_epoch<=0;held_frame<=0;previous_epoch<=0;held_colour<=0;held_camera<=0;
   previous_colour<=0;previous_camera<=0;cfg<=0;radius<=1;min_texture<=0;min_conf<=0;max_sad<=0;
   region<=0;phase<=0;sx<=0;sy<=0;px<=0;py<=0;qcur<=0;qprev<=0;
   sad<=0;best<={SAD_BITS{1'b1}};second<={SAD_BITS{1'b1}};lo<=255;hi<=0;best_x<=0;best_y<=0;match_bad<=0;
   result_valid<=0;result_epoch<=0;result_frame<=0;translation_x_q16<=0;translation_y_q16<=0;
   rotation_q26<=0;scale_delta_q26<=0;confidence<=0;status<=1;dropped<=0;cycles<=0;
   for(i=0;i<3;i=i+1)begin motion_x[i]<=0;motion_y[i]<=0;region_conf[i]<=0;end
  end else if(clear)begin
   have_previous<=0;live<=0;busy<=0;result_valid<=0;row_sum<=0;status<=1;
  end else begin
   result_valid<=0;
   if(frame_start)begin
    // If work overruns, discard the estimator job; capture remains autonomous.
    if(busy)begin dropped<=dropped+1;busy<=0;have_previous<=0;end
    page<=!page;live<=1;bad<=0;row_sum<=0;held_epoch<=epoch;held_frame<=frame_id;
    held_colour<=colour_version;held_camera<=camera_version;cfg<=config_entity;
   end
   if(pixel_valid && live && x<WIDTH && y<HEIGHT)begin
    // Demosaic borders are allowed to be invalid; all matching support must be
    // valid. Border darkness is never classified as a bad whole input frame.
    if(!pixel_mask && x>=WIDTH/8 && x<7*WIDTH/8 && y>=HEIGHT/4 && y<3*HEIGHT/4)bad<=1;
    if(block_x==DX-1)begin
     row_sum<=0;
     if(block_y==DY-1)begin
      if(page)page1[write_address]<=((DY==1?0:column_sum[tc])+row_sum+luma+(DX*DY)/2)/(DX*DY);
      else page0[write_address]<=((DY==1?0:column_sum[tc])+row_sum+luma+(DX*DY)/2)/(DX*DY);
     end else column_sum[tc]<=(block_y==0?0:column_sum[tc])+row_sum+luma;
    end else row_sum<=row_sum+luma;
   end
   if(frame_complete && live)begin
    live<=0;result_epoch<=held_epoch;result_frame<=held_frame;cycles<=0;
    translation_x_q16<=0;translation_y_q16<=0;rotation_q26<=0;scale_delta_q26<=0;confidence<=0;
    if(!frame_legal || bad)begin status<=2;result_valid<=1;have_previous<=0;end
    else begin
     previous_epoch<=held_epoch;previous_colour<=held_colour;previous_camera<=held_camera;have_previous<=1;
     if(!cfg[0] || !have_previous || previous_epoch!=held_epoch || previous_colour!=held_colour || previous_camera!=held_camera)begin
      status<=1;result_valid<=1;
     end else begin
      busy<=1;phase<=0;region<=0;radius<=cfg[23:16];sx<=-$signed({1'b0,cfg[23:16]});sy<=-$signed({1'b0,cfg[23:16]});
      min_texture<=cfg[47:32];min_conf<=cfg[63:48];max_sad<=cfg[223:192];
      px<=0;py<=0;sad<=0;best<={SAD_BITS{1'b1}};second<={SAD_BITS{1'b1}};lo<=255;hi<=0;match_bad<=0;
     end
    end
   end else if(busy && !frame_start)begin
    cycles<=cycles+1;
    case(phase)
     0:begin
      qcur<=page?page1[addr_cur]:page0[addr_cur];qprev<=page?page0[addr_prev]:page1[addr_prev];phase<=1;
     end
     1:begin
      if(qcur<lo)lo<=qcur;if(qcur>hi)hi<=qcur;
      if(px==PATCH-1 && py==PATCH-1)begin
       if(candidate_sad<best)begin second<=best;best<=candidate_sad;best_x<=sx;best_y<=sy;end
       else if(candidate_sad<second)second<=candidate_sad;
       px<=0;py<=0;sad<=0;
       if(sx==$signed({1'b0,radius}) && sy==$signed({1'b0,radius}))phase<=2;
       else begin
        if(sx==$signed({1'b0,radius}))begin sx<=-$signed({1'b0,radius});sy<=sy+1;end else sx<=sx+1;
        phase<=0;
       end
      end else begin
       sad<=candidate_sad;if(px==PATCH-1)begin px<=0;py<=py+1;end else px<=px+1;phase<=0;
      end
     end
     2:begin
      motion_x[region]<=-best_x;motion_y[region]<=-best_y;region_conf[region]<=margin>65535?65535:margin;
      if(hi-lo<min_texture || margin<min_conf || best>max_sad)match_bad<=1;
      if(region==2)phase<=3;
      else begin region<=region+1;phase<=0;sx<=-$signed({1'b0,radius});sy<=-$signed({1'b0,radius});
       best<={SAD_BITS{1'b1}};second<={SAD_BITS{1'b1}};lo<=255;hi<=0;end
     end
     3:begin
      busy<=0;result_valid<=1;
      // Reject non-rigid centre motion: a foreground patch must not steer the
      // background trajectory. This is a bounded residual, not an occlusion map.
      if(match_bad || (2*$signed(motion_x[1])-$signed(motion_x[0])-$signed(motion_x[2]))>2 ||
       (2*$signed(motion_x[1])-$signed(motion_x[0])-$signed(motion_x[2]))< -2 ||
       (2*$signed(motion_y[1])-$signed(motion_y[0])-$signed(motion_y[2]))>2 ||
       (2*$signed(motion_y[1])-$signed(motion_y[0])-$signed(motion_y[2]))< -2)status<=3;
      else begin
       status<=0;translation_x_q16<=($signed(motion_x[0])+$signed(motion_x[2]))*DX*32768;
       translation_y_q16<=($signed(motion_y[0])+$signed(motion_y[2]))*DY*32768;
       // Compile-time ratios eliminate unsupported runtime signed division.
       // At the 1920x1080/64x36 target both steps are exact powers of two.
       rotation_q26<=rotation_cells*ROTATION_STEP_Q26;
       scale_delta_q26<=scale_cells*SCALE_STEP_Q26;
       confidence<=region_conf[0]<region_conf[1]?(region_conf[0]<region_conf[2]?region_conf[0]:region_conf[2]):(region_conf[1]<region_conf[2]?region_conf[1]:region_conf[2]);
      end
     end
    endcase
   end
  end
 end
endmodule

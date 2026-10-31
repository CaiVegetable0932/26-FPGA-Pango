`timescale 1ns/1ps
// Compute B^T Rp(-p) Ry(yr-y) Rp(pr) B A using one reused 32x32
// multiplier and iterative CORDIC. Axes and B are static installation data;
// all live-angle subtraction, trig, Rodrigues and matrix products run here.
// No pixel stream passes through this low-rate transaction engine.
// Experimental local mount operand selection: retain atomic local calibration
// capture, but read mount/B^T directly for the first/last product. The Rodrigues
// left bank therefore needs no request-time or stage-3 mount copies.
module raw_pose_solver(input clk,rst_n,input request_valid,output request_ready,
 input [1023:0] calibration,input [191:0] reference_matrix,
 input signed [31:0] pitch_mdeg,yaw_mdeg,input [15:0] width,height,
 output reg result_valid,input result_ready,output reg result_ok,
 output wire [287:0] matrix);
 localparam signed [31:0] ONE=32'sd67108864;
 localparam IDLE=0,VAL_LOAD=1,MULT_WAIT=2,VAL_SUM=3,MM_LOAD=4,MM_SUM=5,
  MM_COPY=6,TRIG=7,TRIG_WAIT=8,ROD_AXES=9,ROD_SCALE=10,ROD_BASE=11,
  ROD_SKEW=12,ROD_NEXT=13,VIEW_LOAD=14,VIEW_SUM=15,VIEW_CHECK=16,DONE=17;
 reg [4:0] state,return_state;reg [2:0] wait_count;
 // One local enable per coefficient replaces the simultaneous 288-bit copy.
 // The source bank stays frozen during MM_COPY; no variable data mux is needed.
 reg [8:0] copy_select;
 reg signed [31:0] pa[0:2],ya[0:2],mount[0:8],left[0:8],work[0:8],next_matrix[0:8];
 reg signed [31:0] pc,pr,dy,angle,sn,cs,base_term;
 reg [15:0] w,h;reg [2:0] stage,validation;reg [1:0] row,col,k,corner;
 reg signed [31:0] ma,mb;wire signed [63:0] product;
 reg signed [63:0] raw_product,acc;wire signed [63:0] total=acc+raw_product;
 wire signed [63:0] rounded=(total+64'sd33554432)>>>26;
 wire signed [63:0] rounded_product=(raw_product+64'sd33554432)>>>26;
 reg signed [63:0] view[0:2];reg failed;integer i;
 wire trig_ready,trig_valid;wire signed [31:0] trig_s,trig_c;
 signed_mult32_pipe multiplier(clk,1'b1,ma,mb,product);
 pose_sincos trig(.clk(clk),.rst_n(rst_n),.request_valid(state==TRIG),.request_ready(trig_ready),
  .angle_mdeg(angle),.result_valid(trig_valid),.result_ready(state==TRIG_WAIT),.sine(trig_s),.cosine(trig_c));
 assign request_ready=state==IDLE && !result_valid;
 // The final work bank also owns the published result. IDLE cannot accept a
 // new request while result_valid is held, so all nine words stay stable under
 // backpressure. This removes the redundant 288-bit DONE capture bank and its
 // common enable/reset network. Matrix is meaningful only with result_valid;
 // before completion (including reset) it may contain intermediate/unknown data.
 for(genvar word_index=0;word_index<9;word_index=word_index+1)begin:result_words
  assign matrix[word_index*32+:32]=work[word_index];
 end
 // Dot products validate both unit axes and orthonormal installation columns.
 // Static handedness/calibration provenance is additionally checked by host
 // upload validation; neither side claims to measure a physical installation.
 function signed [31:0] validation_a(input [2:0] n,input [1:0] j);
  begin case(n)
   0:validation_a=pa[j];1:validation_a=ya[j];
   2,5,6:validation_a=mount[j*3];3,7:validation_a=mount[j*3+1];
   default:validation_a=mount[j*3+2];endcase end
 endfunction
 function signed [31:0] validation_b(input [2:0] n,input [1:0] j);
  begin case(n)
   0:validation_b=pa[j];1:validation_b=ya[j];2:validation_b=mount[j*3];
   3,5:validation_b=mount[j*3+1];default:validation_b=mount[j*3+2];endcase end
 endfunction
 // Select the mount address before one 9-word read mux. Reading both normal
 // and transposed banks separately would duplicate a wide mux unnecessarily.
 // The extra bank select sits before ma and requires native timing evaluation.
 wire [3:0] left_index=row*4'd3+k;
 wire [3:0] mount_index=stage==4?k*4'd3+row:left_index;
 wire signed [31:0] matrix_left=(stage==0 || stage==4)?mount[mount_index]:left[left_index];
 wire signed [31:0] axis_r=stage==2?ya[row]:pa[row];
 wire signed [31:0] axis_c=stage==2?ya[col]:pa[col];
 wire signed [31:0] axis_other=stage==2?ya[3-row-col]:pa[3-row-col];
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin state<=IDLE;result_valid<=0;result_ok<=0;failed<=0;
   stage<=0;validation<=0;row<=0;col<=0;k<=0;corner<=0;wait_count<=0;return_state<=IDLE;copy_select<=0;end
  else begin
   if(result_valid && result_ready)result_valid<=0;
   case(state)
    IDLE:if(request_valid && request_ready)begin
     // Frozen request words isolate all arithmetic from UART staging changes.
     for(i=0;i<3;i=i+1)begin pa[i]<=calibration[448+i*32+:32];ya[i]<=calibration[544+i*32+:32];end
     for(i=0;i<9;i=i+1)begin mount[i]<=calibration[640+i*32+:32];
      // Retain four guard bits in slope columns through all five
      // matrix products; round once to Q26 to avoid 1920-pixel accumulation.
      work[i]<=i<6?(i%3==2?$signed(reference_matrix[i*32+:32]):($signed(reference_matrix[i*32+:32])<<<4)):i==8?ONE:0;end
     pc<=pitch_mdeg-$signed(calibration[64+:32]);pr<=$signed(calibration[128+:32])-$signed(calibration[64+:32]);
     dy<=$signed(calibration[160+:32])-yaw_mdeg;
     w<=width;h<=height;failed<=0;validation<=0;k<=0;acc<=0;stage<=0;row<=0;col<=0;state<=VAL_LOAD;
    end
    MULT_WAIT:if(wait_count!=0)wait_count<=wait_count-1'b1;
     else begin raw_product<=product;state<=return_state;end
    VAL_LOAD:begin ma<=validation_a(validation,k);mb<=validation_b(validation,k);wait_count<=3;return_state<=VAL_SUM;state<=MULT_WAIT;end
    VAL_SUM:begin
     if(k==2)begin
      if(rounded<(validation<5?ONE:0)-6711 || rounded>(validation<5?ONE:0)+6711)begin failed<=1;state<=DONE;end
      else begin k<=0;acc<=0;if(validation==7)state<=MM_LOAD;else begin validation<=validation+1'b1;state<=VAL_LOAD;end end
     end else begin acc<=total;k<=k+1'b1;state<=VAL_LOAD;end
    end
    MM_LOAD:begin ma<=matrix_left;mb<=work[k*3+col];wait_count<=3;return_state<=MM_SUM;state<=MULT_WAIT;end
    MM_SUM:begin
     if(k==2)begin
      next_matrix[row*3+col]<=rounded[31:0];k<=0;acc<=0;
      if(rounded>2147483647 || rounded< -64'sd2147483648)begin failed<=1;state<=DONE;end
      else if(row==2 && col==2)begin copy_select<=9'b1;state<=MM_COPY;end
      else begin if(col==2)begin col<=0;row<=row+1'b1;end else col<=col+1'b1;state<=MM_LOAD;end
     end else begin acc<=total;k<=k+1'b1;state<=MM_LOAD;end
    end
    MM_COPY:begin
     // Static per-word connections and a walking enable limit each copy strobe
     // to one 32-bit work coefficient; the mount bank is read in place.
     // Five nine-cycle copies add 40 clocks, below the existing request timeout.
     // Preserve signed rounding and atomic request/result handshakes exactly.
     for(i=0;i<9;i=i+1)if(copy_select[i])begin
      work[i]<=(stage==4 && i%3!=2)?($signed(next_matrix[i])+32'sd8)>>>4:next_matrix[i];
     end
     copy_select<=copy_select<<1;
     if(copy_select[8])begin
      row<=0;col<=0;k<=0;acc<=0;
      if(stage==4)begin corner<=0;state<=VIEW_LOAD;end
      else if(stage==3)begin stage<=4;state<=MM_LOAD;end
      else begin
       stage<=stage+1'b1;angle<=stage==0?pr:stage==1?dy:-pc;state<=TRIG;
      end
     end
    end
    TRIG:if(trig_ready)state<=TRIG_WAIT;
    TRIG_WAIT:if(trig_valid)begin sn<=trig_s;cs<=trig_c;state<=ROD_AXES;end
    ROD_AXES:begin ma<=axis_r;mb<=axis_c;wait_count<=3;return_state<=ROD_SCALE;state<=MULT_WAIT;end
    ROD_SCALE:begin ma<=rounded_product[31:0];mb<=ONE-cs;wait_count<=3;return_state<=ROD_BASE;state<=MULT_WAIT;end
    ROD_BASE:begin
     base_term<=rounded_product[31:0];
     if(row==col)begin left[row*3+col]<=rounded_product[31:0]+cs;state<=ROD_NEXT;end
     else begin ma<=sn;mb<=axis_other;wait_count<=3;return_state<=ROD_SKEW;state<=MULT_WAIT;end
    end
    ROD_SKEW:begin
     left[row*3+col]<=((row==0 && col==1)||(row==1 && col==2)||(row==2 && col==0))?
        base_term-rounded_product[31:0]:base_term+rounded_product[31:0];state<=ROD_NEXT;
    end
    ROD_NEXT:begin
     if(row==2 && col==2)begin row<=0;col<=0;state<=MM_LOAD;end
     else begin if(col==2)begin col<=0;row<=row+1'b1;end else col<=col+1'b1;state<=ROD_AXES;end
    end
    VIEW_LOAD:begin
     // Exact Q26 numerator/depth corner bounds require integer pixel products,
     // not Q26 pixels (which cannot fit 32 bits at 1080p).
     ma<=work[row*3+k];mb<=k==0?(corner[0]?w-1:0):k==1?(corner[1]?h-1:0):1;
     wait_count<=3;return_state<=VIEW_SUM;state<=MULT_WAIT;
    end
    VIEW_SUM:begin
     if(k==2)begin view[row]<=total;k<=0;acc<=0;
      if(total<=-530160025 || total>=530160025)failed<=1;
      if(row==2)state<=VIEW_CHECK;else begin row<=row+1'b1;state<=VIEW_LOAD;end
     end else begin acc<=total;k<=k+1'b1;state<=VIEW_LOAD;end
    end
    VIEW_CHECK:begin
     if(view[2]<=16384 || view[0]<=-(view[2]<<<3) || view[0]>=(view[2]<<<3) ||
        view[1]<=-(view[2]<<<3) || view[1]>=(view[2]<<<3))failed<=1;
     if(corner==3)state<=DONE;else begin corner<=corner+1'b1;row<=0;state<=VIEW_LOAD;end
    end
    DONE:begin
     // Publish only after computation/validation finishes. Do not copy data:
     // work remains owned by this result until the valid/ready handshake.
     result_ok<=!failed;result_valid<=1;state<=IDLE;
    end
   endcase
  end
 end
endmodule

`timescale 1ns/1ps
module span_tb;
 reg [96:0] controls=0;
 wire [31:0] frame_base,frame_stride;
 wire [15:0] frame_height,frame_width;wire frame_rgb888;
 assign {frame_base,frame_stride,frame_height,frame_width,frame_rgb888}=controls;
 wire [63:0] original_span={32'd0,frame_base}+({48'd0,frame_height}-1)*{32'd0,frame_stride}+
  {48'd0,frame_width}*(frame_rgb888 ? 64'd3 : 64'd1);
 wire signed [16:0] candidate_preceding_rows=$signed({1'b0,frame_height})-17'sd1;
 wire signed [49:0] candidate_row_span=candidate_preceding_rows*$signed({1'b0,frame_stride});
 wire [63:0] candidate_span={32'd0,frame_base}+{{14{candidate_row_span[49]}},candidate_row_span}+
  {48'd0,frame_width}*(frame_rgb888 ? 64'd3 : 64'd1);
 reg [31:0] strides[0:5];reg [31:0] base_value;reg [96:0] known;
 integer h,j,k,checks=0,seed=177;
 task check;begin #1;
  checks=checks+1;
  if(original_span !== candidate_span)
   $fatal(1,"SPAN_MATH_DIFF controls=%h reference=%h candidate=%h",controls,original_span,candidate_span);
 end endtask
 initial begin
  strides[0]=0;strides[1]=1;strides[2]=31;strides[3]=32;strides[4]=6144;strides[5]=32'hffffffff;
  for(h=0;h<65536;h=h+1)for(j=0;j<6;j=j+1)begin
   base_value=(j==0)?0:((j==5)?32'hffffffff:$random(seed));
   controls={base_value,strides[j],16'(h),16'(h*17),1'(h&1)};check;
  end
  for(k=0;k<20000;k=k+1)begin
   controls={$random(seed),$random(seed),16'($random(seed)),16'($random(seed)),1'($random(seed))};check;
  end
  for(j=0;j<3;j=j+1)begin
   known=(j==0)?97'd0:((j==1)?{97{1'b1}}:{32'hfffff000,32'd6144,16'd1080,16'd1920,1'b1});
   for(k=0;k<97;k=k+1)begin
    controls=known;controls[k]=1'bx;check;
    controls=known;controls[k]=1'bz;check;
   end
  end
  $display("SPAN_MATH_PASS checks=%0d",checks);$finish;
 end
endmodule

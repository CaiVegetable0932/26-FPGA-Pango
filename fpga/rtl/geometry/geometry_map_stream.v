// Purpose: feed-forward, one-coordinate-per-clock inverse map. Every product
// is a spatial DSP pipeline; there is no per-pixel multiplier-sharing FSM.
// Frame parameters/LUT bank must remain stable until all accepted tokens drain.
// A reserved-credit output queue absorbs arbitrary sampler backpressure.
module geometry_map_stream #(parameter WIDTH=1920,HEIGHT=1080)(
 input wire clk,rst_n,input wire [1:0] model,input wire [447:0] words,
 input wire request_valid,output wire request_ready,input wire [11:0] ox,oy,
 output wire result_valid,input wire result_ready,output wire source_valid,
 output wire [11:0] x0,x1,y0,y1,frac_x,frac_y,
 output wire [10:0] lut_index,input wire signed [31:0] scale0,scale1
);
 wire signed [31:0] a00=words[31:0],a01=words[63:32],a02=words[95:64];
 wire signed [31:0] a10=words[127:96],a11=words[159:128],a12=words[191:160];
 wire signed [31:0] p1=words[287:256],p2=words[319:288];
 wire signed [31:0] fx=words[351:320],fy=words[383:352],cx=words[415:384],cy=words[447:416];
 reg [6:0] reserved;
 wire accept=request_valid && request_ready,consume=result_valid && result_ready;
 assign request_ready=reserved<64;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)reserved<=0;
  else case({accept,consume})2'b10:reserved<=reserved+1'b1;2'b01:reserved<=reserved-1'b1;default:begin end endcase
 // Purpose: affine products, sum and domain clamp are separate register stages.
 reg v0,v1,v2;reg [25:0] t0,t1,t2;
 reg signed [47:0] tx0,tx1,ty0,ty1,xwide,ywide;
 reg signed [31:0] xq,yq;reg domain;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin v0<=0;v1<=0;v2<=0;end
  else begin v0<=accept;v1<=v0;v2<=v1;end
 always @(posedge clk)begin
  if(accept)begin
   tx0<=a00*$signed({1'b0,ox});tx1<=a01*$signed({1'b0,oy});
   ty0<=a10*$signed({1'b0,ox});ty1<=a11*$signed({1'b0,oy});t0<={model,oy,ox};
  end
  if(v0)begin xwide<=tx0+tx1+a02;ywide<=ty0+ty1+a12;t1<=t0;end
  if(v1)begin
   domain<=xwide>=-48'sd268435456 && xwide<=48'sd268435456 &&
           ywide>=-48'sd268435456 && ywide<=48'sd268435456;
   xq<=xwide>=-48'sd268435456 && xwide<=48'sd268435456 ? xwide[31:0]:32'sd0;
   yq<=ywide>=-48'sd268435456 && ywide<=48'sd268435456 ? ywide[31:0]:32'sd0;t2<=t1;
  end
 end
 wire sqv;wire signed [63:0] xx,yy,xy;
 geometry_mul_pipe #(.A_WIDTH(32),.B_WIDTH(32)) mx(clk,rst_n,v2,xq,xq,sqv,xx);
 geometry_mul_pipe #(.A_WIDTH(32),.B_WIDTH(32)) my(clk,rst_n,v2,yq,yq,,yy);
 geometry_mul_pipe #(.A_WIDTH(32),.B_WIDTH(32)) mxy(clk,rst_n,v2,xq,yq,,xy);
 wire [90:0] sqmeta;
 geometry_token_delay #(.WIDTH(91),.LATENCY(4)) dsq(clk,{domain,t2,xq,yq},sqmeta);
 reg rv,lv;reg signed [33:0] rsq;reg signed [35:0] bx,by;
 reg signed [33:0] crossq;
 reg [90:0] rm,lm;reg [20:0] lf;reg signed [35:0] lbx,lby;reg signed [33:0] lxy;
 wire signed [33:0] sumsq=(xx>>>26)+(yy>>>26);
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin rv<=0;lv<=0;end else begin rv<=sqv;lv<=rv;end
 always @(posedge clk)begin
  if(sqv)begin
   rsq<=sumsq;bx<=sumsq+(xx>>>25);by<=sumsq+(yy>>>25);crossq<=xy>>>26;
   rm<={sqmeta[90] && sumsq>=0 && sumsq<34'sd2147483648,sqmeta[89:0]};
  end
  if(rv)begin lm<=rm;lf<=rsq[20:0];lbx<=bx;lby<=by;lxy<=crossq;end
 end
 // The LUT has one synchronous read edge. Metadata receives that same edge.
 assign lut_index=rsq>=0 && rsq<34'sd2147483648 ? rsq[31:21]:11'd0;
 wire iv;wire signed [53:0] delta;
 wire signed [31:0] scale_delta=scale1-scale0;
 geometry_mul_pipe #(.A_WIDTH(32),.B_WIDTH(22)) mi(clk,rst_n,lv,scale_delta,$signed({1'b0,lf}),iv,delta);
 wire [228:0] im;
 geometry_token_delay #(.WIDTH(229),.LATENCY(4)) di(clk,{lm,lbx,lby,lxy,scale0},im);
 reg pv;reg signed [31:0] sc;reg [196:0] pm;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)pv<=0;else pv<=iv;
 always @(posedge clk)if(iv)begin sc<=$signed(im[31:0])+(delta>>>21);pm<=im[228:32];end
 wire [90:0] pt=pm[196:106];
 wire signed [31:0] px=pt[63:32],py=pt[31:0];
 wire signed [35:0] pbx=pm[105:70],pby=pm[69:34];
 wire signed [33:0] pxy=pm[33:0];
 wire av;wire signed [67:0] rx,ry,crossx,crossy,tanx,tany;
 geometry_mul_pipe mr0(clk,rst_n,pv,px,{{4{sc[31]}},sc},av,rx);
 geometry_mul_pipe mr1(clk,rst_n,pv,py,{{4{sc[31]}},sc},,ry);
 geometry_mul_pipe mt0(clk,rst_n,pv,p1,{{2{pxy[33]}},pxy},,crossx);
 geometry_mul_pipe mt1(clk,rst_n,pv,p2,pbx,,tanx);
 geometry_mul_pipe mt2(clk,rst_n,pv,p1,pby,,tany);
 geometry_mul_pipe mt3(clk,rst_n,pv,p2,{{2{pxy[33]}},pxy},,crossy);
 wire [26:0] am;
 geometry_token_delay #(.WIDTH(27),.LATENCY(5)) da(clk,pt[90:64],am);
 reg qv;reg signed [35:0] sx,sy;reg [26:0] qm;
 // Purpose: match old 36-bit radial/tangential truncation before projection.
 wire signed [35:0] radialx=rx>>>26,radialy=ry>>>26;
 wire signed [35:0] brownx=(crossx>>>25)+(tanx>>>26);
 wire signed [35:0] browny=(crossy>>>25)+(tany>>>26);
 always @(posedge clk or negedge rst_n)if(!rst_n)qv<=0;else qv<=av;
 always @(posedge clk)if(av)begin
  sx<=radialx+(am[25:24]==1?brownx:36'sd0);
  sy<=radialy+(am[25:24]==1?browny:36'sd0);qm<=am;
 end
 wire uv;wire signed [67:0] up,vp;
 geometry_mul_pipe mu(clk,rst_n,qv,fx,sx,uv,up);
 geometry_mul_pipe mv(clk,rst_n,qv,fy,sy,,vp);
 wire [26:0] um;geometry_token_delay #(.WIDTH(27),.LATENCY(5)) du(clk,qm,um);
 reg ov;reg signed [47:0] uq,vq;reg [26:0] om;
 always @(posedge clk or negedge rst_n)if(!rst_n)ov<=0;else ov<=uv;
 always @(posedge clk)if(uv)begin uq<=(up>>>30)+(cx>>>4);vq<=(vp>>>30)+(cy>>>4);om<=um;end
 reg [72:0] packed_result;
 reg [11:0] ax,ay;
 // Purpose: invalid rays produce zero coordinates and no sample reads. Bypass
 // keeps source integer centers including duplicated final row/column.
 always @*begin
  packed_result=0;ax=0;ay=0;
  if(om[25:24]==0)begin
   ax=om[11:0];ay=om[23:12];
   packed_result={1'b1,ax,ax==WIDTH-1?ax:ax+12'd1,ay,ay==HEIGHT-1?ay:ay+12'd1,24'b0};
  end else if(om[26] && uq>=0 && vq>=0 && uq<=(WIDTH-1)*48'sd4096 && vq<=(HEIGHT-1)*48'sd4096)begin
   ax=uq[23:12];ay=vq[23:12];
   packed_result={1'b1,ax,ax==WIDTH-1?ax:ax+12'd1,ay,ay==HEIGHT-1?ay:ay+12'd1,uq[11:0],vq[11:0]};
  end
 end
 wire [72:0] head;wire [6:0] count;
 geometry_coordinate_fifo u_results(clk,rst_n,ov,packed_result,consume,head,count);
 assign result_valid=count!=0;
 assign {source_valid,x0,x1,y0,y1,frac_x,frac_y}=head;
endmodule

// Purpose: align payload with the documented geometry_mul_pipe latency. Only
// the separate valid pipeline has reset; uninitialized payload is never consumed.
module geometry_token_delay #(parameter WIDTH=1,LATENCY=1)(
 input wire clk,input wire [WIDTH-1:0] data,output wire [WIDTH-1:0] delayed
);
 reg [WIDTH-1:0] pipe[0:LATENCY-1];integer i;
 always @(posedge clk)begin pipe[0]<=data;for(i=1;i<LATENCY;i=i+1)pipe[i]<=pipe[i-1];end
 assign delayed=pipe[LATENCY-1];
endmodule

// Purpose: 64 reserved result slots, synchronous DRM read, two-register
// lookahead. Pop/push collision forwarding supports one output each clock.
// Capacity includes front/lookahead (copies of ring words, not extra slots).
module geometry_coordinate_fifo(
 input wire clk,rst_n,write,input wire [72:0] write_data,input wire pop,
 output wire [72:0] head,output reg [6:0] count
);
 reg [72:0] storage[0:63] /* synthesis syn_ramstyle="block_ram" */;
 reg [5:0] wp,rp;reg [72:0] front,next_front;
 wire [5:0] read_next=rp+(pop?6'd2:6'd1);
 assign head=front;
 always @(posedge clk)begin
  if(write)storage[wp]<=write_data;
  if(rst_n)begin
   if(write && wp==read_next)next_front<=write_data;
   else next_front<=storage[read_next];
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


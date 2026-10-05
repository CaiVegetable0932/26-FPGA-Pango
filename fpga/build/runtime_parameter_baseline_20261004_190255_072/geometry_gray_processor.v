// Purpose: complete frame-scoped gray correction: atomic K/D -> FPGA radial
// LUT -> inverse coordinates -> coherent source-cache/gray ISP -> bilinear ->
// result + mask DDR writes -> read fence. All ports belong to mem_clk.
module geometry_gray_processor #(parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048)(
 input wire clk,rst_n,start,input wire [27:0] source_base,result_base,
 input wire [63:0] source_id,epoch,input wire context_valid,input wire [31:0] session_id,
 input wire cmd_valid,input wire [7:0] cmd,input wire [255:0] payload,
 output wire [7:0] code,output wire [95:0] reply,
 output reg busy,output wire done,good,fault,
 output wire [27:0] awaddr,output wire [3:0] awlen,output wire awvalid,
 input wire awready,wready,wlast,input wire [3:0] wid,
 output wire [255:0] wdata,output wire [31:0] wstrb,
 output wire read_req,output wire [27:0] read_addr,output wire [4:0] read_len,
 input wire read_ready,read_valid,read_done,input wire [255:0] read_data,
 output wire [31:0] active_version,output reg [31:0] frame_version,
 output reg [31:0] frame_cycles,output wire [31:0] cache_hits,cache_misses,
 output wire [63:0] applied_frame_id
);
 wire [447:0] words;wire [1:0] model,build_model;
 wire enhance,bank,build_start,build_bank,build_busy,build_failed,pending;
 wire lut_busy,lut_done,lut_failed;
 wire signed [31:0] k1,k2,k3,k4,s0,s1;wire [10:0] li;
 wire [7:0] config_code;wire [95:0] config_reply;
 // Purpose: expose actual processing time/cache counters separately from
 // camera/network FPS; higher diagnostic indices never mutate parameters.
 wire diagnostic=cmd==8'h34 && payload[159:128]==1 &&
                 payload[127:96]>=18 && payload[127:96]<=20;
 assign code=diagnostic?8'd0:config_code;
 assign reply=diagnostic?{frame_version,
  payload[127:96]==18?frame_cycles:payload[127:96]==19?cache_hits:cache_misses,
  payload[127:96]}:config_reply;
 geometry_config_bank #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_config(
  .clk(clk),.rst_n(rst_n),.context_valid(context_valid),.epoch(epoch),.session_id(session_id),
  .cmd_valid(cmd_valid),.cmd(cmd),.payload(payload),.code(config_code),.reply(config_reply),
  .frame_start(start && !busy),.source_frame_id(source_id),.active_words(words),.active_model(model),
  .active_enhance(enhance),.active_bank(bank),.active_version(active_version),.applied_frame_id(applied_frame_id),
  .build_busy(build_busy),.build_failed(build_failed),.pending(pending),.build_start(build_start),
  .build_bank(build_bank),.build_model(build_model),.k1(k1),.k2(k2),.k3(k3),.k4(k4),
  .build_done(lut_done),.lut_failed(lut_failed));
 geometry_lens_lut u_lut(.clk(clk),.rst_n(rst_n),.start(build_start),.build_bank(build_bank),
  .model(build_model),.k1(k1),.k2(k2),.k3(k3),.k4(k4),.busy(lut_busy),.done(lut_done),.failed(lut_failed),
  .read_bank(bank),.read_index(li),.scale0(s0),.scale1(s1));
 reg [2:0] state;reg [11:0] x,y;
 reg [27:0] src,dst;reg writer_start;
 wire map_ready,map_valid,map_source,sample_ready,sample_valid,sample_mask,writer_ready;
 wire [11:0] x0,x1,y0,y1,fx,fy;wire [7:0] sample;
 geometry_map_engine #(.WIDTH(WIDTH),.HEIGHT(HEIGHT)) u_map(.clk(clk),.rst_n(rst_n),
  .model(model),.words(words),.request_valid(state==1),.request_ready(map_ready),.ox(x),.oy(y),
  .result_valid(map_valid),.result_ready(state==2 && sample_ready),.source_valid(map_source),
  .x0(x0),.x1(x1),.y0(y0),.y1(y1),.frac_x(fx),.frac_y(fy),.lut_index(li),.scale0(s0),.scale1(s1));
 wire byte_req,byte_ready,byte_valid,byte_consume;wire [27:0] byte_addr;wire [7:0] byte_value;
 geometry_gray_sampler #(.STRIDE(STRIDE)) u_sampler(.clk(clk),.rst_n(rst_n),
  .start(state==2 && map_valid && sample_ready),.source_valid(map_source),.enhance(enhance),.base(src),
  .x0(x0),.x1(x1),.y0(y0),.y1(y1),.frac_x(fx),.frac_y(fy),.ready(sample_ready),
  .valid(sample_valid),.pixel_ready(writer_ready && state==3),.pixel(sample),.mask_valid(sample_mask),
  .cache_req(byte_req),.cache_ready(byte_ready),.cache_addr(byte_addr),
  .cache_valid(byte_valid),.cache_response_ready(byte_consume),.cache_value(byte_value));
 wire cache_req,cache_rready,cache_valid,cache_done,cache_fault;
 wire [27:0] cache_addr;
 geometry_byte_cache u_cache(.clk(clk),.rst_n(rst_n),.invalidate(start && !busy),
  .request_valid(byte_req),.request_ready(byte_ready),.address(byte_addr),
  .response_valid(byte_valid),.response_ready(byte_consume),.value(byte_value),
  .read_req(cache_req),.read_addr(cache_addr),.read_ready(cache_rready),.read_valid(cache_valid),
  .read_done(cache_done),.read_data(read_data),.fault(cache_fault),.hits(cache_hits),.misses(cache_misses));
 wire fence_req,fence_ready,fence_valid,fence_done,writer_fault;
 wire [27:0] fence_addr;
 geometry_result_writer #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.STRIDE(STRIDE)) u_writer(
  .clk(clk),.rst_n(rst_n),.start(writer_start),.base(dst),
  .pixel_valid(sample_valid && state==3),.pixel_mask(sample_mask),.pixel(sample),.pixel_ready(writer_ready),
  .done(done),.good(good),.fault(writer_fault),.awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),
  .awready(awready),.wready(wready),.wlast(wlast),.wid(wid),.wdata(wdata),.wstrb(wstrb),
  .fence_req(fence_req),.fence_addr(fence_addr),.fence_ready(fence_ready),.fence_valid(fence_valid),
  .fence_done(fence_done),.fence_data(read_data));
 // Purpose: the final fence cannot overlap any cache transaction; completion
 // waits for every output pixel and write. External arbiter retains ownership.
 assign read_req=fence_req || cache_req,read_addr=fence_req?fence_addr:cache_addr,read_len=1;
 assign cache_rready=read_ready && !fence_req,cache_valid=read_valid && state!=4,
        cache_done=read_done && state!=4;
 assign fence_ready=read_ready && fence_req,fence_valid=read_valid && state==4,
        fence_done=read_done && state==4;
 assign fault=cache_fault || writer_fault;
 always @(posedge clk or negedge rst_n)
  if(!rst_n)begin state<=0;busy<=0;x<=0;y<=0;src<=0;dst<=0;writer_start<=0;frame_cycles<=0;frame_version<=0;end
  else begin
   writer_start<=0;
   if(busy)frame_cycles<=frame_cycles+1'b1;
   case(state)
    0:if(start && !busy && !fault)begin
     src<=source_base;dst<=result_base;busy<=1;x<=0;y<=0;frame_cycles<=0;state<=5;
    end
    5:begin frame_version<=active_version;writer_start<=1;state<=1;end
    1:if(map_ready)state<=2;
    2:if(map_valid && sample_ready)state<=3;
    3:if(sample_valid && writer_ready)begin
     if(x==WIDTH-1)begin x<=0;y<=y+1'b1;end else x<=x+1'b1;
     state<=(x==WIDTH-1 && y==HEIGHT-1)?4:1;
    end
    4:if(done)begin state<=0;busy<=0;end
   endcase
  end
endmodule

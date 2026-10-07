`timescale 1ns/1ps
// Purpose: independently obtain old FSM coordinates, then stream exactly the
// same requests through the spatial pipeline with bursts and random backpressure.
// Check all bits, invalid masks, bypass, Brown, fish-eye, and held output tokens.
module tb_geometry_map_stream;
 parameter KIND=2;
 reg clk=0,rst=0,build=0;always #4 clk=~clk;
 reg [31:0] params[0:13];reg [447:0] words;wire done,failed;
 wire [10:0] old_index,new_index;wire signed [31:0] os0,os1,ns0,ns1;
 geometry_lens_lut lo(.clk(clk),.rst_n(rst),.start(build),.build_bank(1'b1),.model(KIND[1:0]),
 .k1(words[223:192]),.k2(words[255:224]),.k3(words[287:256]),.k4(words[319:288]),
 .busy(),.done(done),.failed(failed),.read_bank(1'b1),.read_index(old_index),.scale0(os0),.scale1(os1));
 geometry_lens_lut ln(.clk(clk),.rst_n(rst),.start(build),.build_bank(1'b1),.model(KIND[1:0]),
 .k1(words[223:192]),.k2(words[255:224]),.k3(words[287:256]),.k4(words[319:288]),
 .busy(),.done(),.failed(),.read_bank(1'b1),.read_index(new_index),.scale0(ns0),.scale1(ns1));
 reg old_req=0,old_pop=0;reg [11:0] ox=0,oy=0;wire old_ready,old_valid;wire [72:0] old_result;
 geometry_map_engine oldmap(.clk(clk),.rst_n(rst),.model(KIND[1:0]),.words(words),
 .request_valid(old_req),.request_ready(old_ready),.ox(ox),.oy(oy),.result_valid(old_valid),.result_ready(old_pop),
 .source_valid(old_result[72]),.x0(old_result[71:60]),.x1(old_result[59:48]),.y0(old_result[47:36]),
 .y1(old_result[35:24]),.frac_x(old_result[23:12]),.frac_y(old_result[11:0]),
 .lut_index(old_index),.scale0(os0),.scale1(os1));
 reg req=0,pop=0;reg [11:0] nx=0,ny=0;wire ready,valid;wire [72:0] result;
 geometry_map_stream newmap(.clk(clk),.rst_n(rst),.model(KIND[1:0]),.words(words),
 .request_valid(req),.request_ready(ready),.ox(nx),.oy(ny),.result_valid(valid),.result_ready(pop),
 .source_valid(result[72]),.x0(result[71:60]),.x1(result[59:48]),.y0(result[47:36]),
 .y1(result[35:24]),.frac_x(result[23:12]),.frac_y(result[11:0]),
 .lut_index(new_index),.scale0(ns0),.scale1(ns1));
 localparam N=2048;
 reg [72:0] expected[0:N-1];reg [11:0] xs[0:N-1],ys[0:N-1];
 integer i,sent=0,received=0,cycles=0,old_cycles=0,run_count=0,max_run=0;
 reg running=0,stalled=0;reg [72:0] held;reg [31:0] rng=32'h71625198;
 always @(posedge clk)if(running)begin
  cycles=cycles+1;
  if(stalled && (!valid || result!==held))$fatal(1,"MAP_STREAM_FAIL unstable");
  stalled=valid && !pop;held=result;
  if(req && ready)begin sent=sent+1;run_count=run_count+1;if(run_count>max_run)max_run=run_count;end else run_count=0;
  if(valid && pop)begin
   if(received>=sent || result!==expected[received])
    $fatal(1,"MAP_STREAM_FAIL kind=%0d i=%0d got=%h expected=%h",KIND,received,result,expected[received]);
   received=received+1;
  end
 end else if(rst && !done)old_cycles=old_cycles+1;
 initial begin
  $readmemh(KIND==1?"brown_parameters.hex":"parameters.hex",params);
  for(i=0;i<14;i=i+1)words[i*32+:32]=params[i];
  for(i=0;i<N;i=i+1)begin xs[i]=(i*193+17)%1920;ys[i]=(i*97+13)%1080;end
  xs[0]=0;ys[0]=0;xs[1]=1919;ys[1]=1079;xs[2]=960;ys[2]=540;
  repeat(4)@(negedge clk);rst=1;@(negedge clk);build=1;@(negedge clk);build=0;
  wait(done);if(failed)$fatal(1,"MAP_STREAM_FAIL LUT");@(negedge clk);
  for(i=0;i<N;i=i+1)begin
   wait(old_ready);@(negedge clk);ox=xs[i];oy=ys[i];old_req=1;
   @(negedge clk);old_req=0;wait(old_valid);@(negedge clk);
   expected[i]=old_result;old_pop=1;@(negedge clk);old_pop=0;
  end
  running=1;
  while(received<N)begin
   @(negedge clk);rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   pop=(cycles<100 || cycles>260) && rng[2:0]!=0;
   req=sent<N;if(sent<N)begin nx=xs[sent];ny=ys[sent];end
  end
  req=0;pop=0;running=0;
  if(max_run<32 || cycles>N*2)$fatal(1,"MAP_STREAM_FAIL throughput");
  $display("MAP_STREAM_PASS model=%0d vectors=%0d cycles=%0d longest_burst=%0d",KIND,N,cycles,max_run);$finish;
 end
 initial begin #6000000;$fatal(1,"MAP_STREAM_TIMEOUT");end
endmodule


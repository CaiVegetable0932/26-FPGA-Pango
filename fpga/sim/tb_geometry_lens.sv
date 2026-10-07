`timescale 1ns/1ps
// Purpose: compare actual FPGA CORDIC/root/divider-derived table and 1080p
// fish-eye coordinates with an independent analytic reference; test stalls.
module tb_geometry_lens;
 parameter KIND=2;
 reg clk=0,rst=0,start=0;always #4 clk=~clk;
 reg [31:0] params[0:13],expected[0:1024];reg [447:0] words;
 reg [10:0] index=0;wire signed [31:0] s0,s1;wire busy,done,failed;
 geometry_lens_lut lut(.clk(clk),.rst_n(rst),.start(start),.build_bank(1'b1),.model(KIND[1:0]),
  .k1(words[223:192]),.k2(words[255:224]),.k3(words[287:256]),.k4(words[319:288]),
  .busy(busy),.done(done),.failed(failed),.read_bank(1'b1),.read_index(index),.scale0(s0),.scale1(s1));
 reg req=0,consume=0;reg [11:0] ox=0,oy=0;
 wire req_ready,valid,source_valid;wire [11:0] x0,x1,y0,y1,fx,fy;wire [10:0] map_index;
 // The same table is selected by the mapper after the explicit table audit.
 reg audit=1;
 geometry_map_engine map(.clk(clk),.rst_n(rst),.model(KIND[1:0]),.words(words),
  .request_valid(req),.request_ready(req_ready),.ox(ox),.oy(oy),
  .result_valid(valid),.result_ready(consume),.source_valid(source_valid),
  .x0(x0),.x1(x1),.y0(y0),.y1(y1),.frac_x(fx),.frac_y(fy),
  .lut_index(map_index),.scale0(s0),.scale1(s1));
 always @*if(!audit)index=map_index;
 integer i,fd,n,x,y,v,u,vy,error_u,error_v,max_error=0,vectors=0;
 reg [95:0] held;
 initial begin
  // Purpose: same mapper tested independently with fish-eye and Brown data.
  $readmemh(KIND==1?"brown_parameters.hex":"parameters.hex",params);
  $readmemh(KIND==1?"brown_lut.hex":"expected_lut.hex",expected);
  for(i=0;i<14;i=i+1)words[i*32+:32]=params[i];
  repeat(4)@(negedge clk);rst=1;@(negedge clk);start=1;@(negedge clk);start=0;
  wait(done);if(failed)$fatal(1,"GEOMETRY_LENS_FAIL builder");
  for(i=0;i<1024;i=i+1)begin
   @(negedge clk);index=i;repeat(2)@(negedge clk);
   if($signed(s0)-$signed(expected[i])>128 || $signed(expected[i])-$signed(s0)>128)
    $fatal(1,"GEOMETRY_LENS_FAIL table i=%0d got=%0d expected=%0d",i,s0,expected[i]);
  end
  audit=0;fd=$fopen(KIND==1?"brown_coordinates.txt":"coordinates.txt","r");if(!fd)$fatal(1,"GEOMETRY_LENS_FAIL vectors");
  while(!$feof(fd))begin
   n=$fscanf(fd,"%d %d %d %d %d\n",x,y,v,u,vy);
   if(n==5)begin
    wait(req_ready);@(negedge clk);ox=x;oy=y;req=1;@(negedge clk);req=0;
    wait(valid);@(negedge clk);
    if(source_valid!==v[0])$fatal(1,"GEOMETRY_LENS_FAIL bounds x=%0d y=%0d",x,y);
    if(source_valid)begin
     error_u=($unsigned(x0)*4096+$unsigned(fx))-u;
     error_v=($unsigned(y0)*4096+$unsigned(fy))-vy;
     if(error_u<0)error_u=-error_u;if(error_v<0)error_v=-error_v;
     if(error_u>1024 || error_v>1024)$fatal(1,"GEOMETRY_LENS_FAIL coordinate %0d %0d",error_u,error_v);
     if(error_u>max_error)max_error=error_u;if(error_v>max_error)max_error=error_v;
    end
    held={x0,x1,y0,y1,fx,fy,source_valid};
    repeat(3)begin @(negedge clk);if(!valid || held!={x0,x1,y0,y1,fx,fy,source_valid})$fatal(1,"GEOMETRY_LENS_FAIL hold");end
    consume=1;@(negedge clk);consume=0;vectors=vectors+1;
   end
  end
  $display("GEOMETRY_LENS_PASS model=%0d vectors=%0d max_error_q12=%0d",KIND,vectors,max_error);$finish;
 end
 initial begin #3000000;$fatal(1,"GEOMETRY_LENS_TIMEOUT");end
endmodule

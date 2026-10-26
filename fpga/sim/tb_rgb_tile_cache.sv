`timescale 1ns/1ps
// Purpose: cache scoreboard with randomized ordered DDR wait and consumer stalls.
module tb_rgb_tile_cache #(parameter FILL_PIXELS=1,TILE_X_BITS=4,TILE_Y_BITS=4);
 localparam TILE_W=1<<TILE_X_BITS,TILE_H=1<<TILE_Y_BITS;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,start=0,iv=0,ready=1,im=1;
 reg [15:0] width=64,height=48;reg signed [27:0] u,v;
 reg [63:0] tag;wire frame_ready,ir,ov,mask,error,rejected;
 wire [95:0] samples;wire [11:0] a,b;wire [63:0] out_tag;
 wire req;reg req_ready=0;wire [11:0] tx,ty;
 reg fv=0,fl=0,fe=0;wire fr;reg [FILL_PIXELS*24-1:0] fill_rgb;reg [31:0] bus_bytes;
 wire [31:0] hits,misses,duplicates,stalls,max_stall;wire [63:0] bytes_count;wire [15:0] peak;
 reg signed [27:0] gu[0:1499],gv[0:1499];
 integer count=1200,sent,received=0,fill_n=0,fill_x=0,fill_y=0,cycles=0,requests=0;
 integer previous_output_cycle=0,hot_ii_checks=0;
 reg fill_active=0,fault_mode=0,checking=1;
 integer tail_delay=0;
 reg long_fill_mode=0;
 rgb_tile_cache #(.TAG_BITS(64),.SET_BITS(1),.FILL_PIXELS(FILL_PIXELS),.TILE_X_BITS(TILE_X_BITS),.TILE_Y_BITS(TILE_Y_BITS)) dut(.clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(frame_ready),
  .frame_width(width),.frame_height(height),.in_valid(iv),.in_ready(ir),.in_u(u),.in_v(v),.in_mask(im),.in_tag(tag),
  .out_valid(ov),.out_ready(ready),.out_samples(samples),.out_a(a),.out_b(b),.out_mask(mask),.out_tag(out_tag),
  .fill_req_valid(req),.fill_req_ready(req_ready),.fill_tile_x(tx),.fill_tile_y(ty),.fill_valid(fv),.fill_ready(fr),
  .fill_rgb(fill_rgb),.fill_last(fl),.fill_error(fe),.fill_bus_bytes(bus_bytes),.frame_error(error),.config_rejected(rejected),
  .hit_pixels(hits),.miss_tiles(misses),.duplicate_samples(duplicates),.stall_cycles(stalls),.max_stall_cycles(max_stall),
  .refill_bus_bytes(bytes_count),.queue_peak(peak));
 function [23:0] pixel(input integer x,y);
  begin pixel={8'((x*17+y*3)&255),8'((x*5+y*11)&255),8'((x*29+y*7)&255)};end
 endfunction
 function [31:0] actual_bus(input integer tx0,ty0);
  integer addr,cols,total;
  begin
   cols=width-tx0*TILE_W;if(cols>TILE_W)cols=TILE_W;total=0;
   for(integer row=ty0*TILE_H;row<(ty0+1)*TILE_H && row<height;row=row+1) begin
    addr=row*width*3+tx0*TILE_W*3;total=total+((addr%32+cols*3+31)/32)*32;
   end
   actual_bus=total;
  end
 endfunction
 always @(negedge clk) begin
  ready=received<200 ? 1 : $urandom_range(0,5)!=0;req_ready=$urandom_range(0,3)!=0;
  fv=fill_active && $urandom_range(0,4)!=0;
  fl=fault_mode ? fill_n==3 : long_fill_mode ? fill_n==256/FILL_PIXELS+3 : fill_n==256/FILL_PIXELS-1;fe=0;
  if(FILL_PIXELS==1)
   fill_rgb=fill_x*TILE_W+(fill_n%TILE_W)>=width || fill_y*TILE_H+(fill_n/TILE_W)>=height ? 24'd0 : pixel(fill_x*TILE_W+(fill_n%TILE_W),fill_y*TILE_H+(fill_n/TILE_W));
  else for(integer lane=0;lane<4;lane=lane+1) begin
   integer xx,yy;
   xx=fill_x*TILE_W+(fill_n%(TILE_W/2))*2+lane%2;yy=fill_y*TILE_H+(fill_n/(TILE_W/2))*2+lane/2;
   fill_rgb[lane*24+:24]=xx>=width || yy>=height ? 24'd0 : pixel(xx,yy);
  end
  bus_bytes=actual_bus(fill_x,fill_y);
 end
 always @(posedge clk) if(rst_n) begin
  cycles=cycles+1;
  if(req && req_ready) begin
   if(fill_active)$fatal(1,"CACHE_FAIL overlapping refill");
   fill_active=1;fill_x=tx;fill_y=ty;fill_n=0;requests=requests+1;
  end
  if(fv && fr) begin if(fl) fill_active=0;else fill_n=fill_n+1;end
  if(ov && ready) begin
   if(checking && received>20 && received<190) begin
    if(cycles-previous_output_cycle!=1)$fatal(1,"CACHE_FAIL hot-hit II");hot_ii_checks=hot_ii_checks+1;
   end
   previous_output_cycle=cycles;
   if(checking) begin
    if(out_tag!==received || a!==gu[received][11:0] || b!==gv[received][11:0])$fatal(1,"CACHE_FAIL tag/fractions n=%0d",received);
    if(gu[received]<0 || gv[received]<0 || gu[received]>(width-1)*4096 || gv[received]>(height-1)*4096) begin
     if(mask || samples!==0)$fatal(1,"CACHE_FAIL invalid-domain read");
    end else begin
     if(!mask)$fatal(1,"CACHE_FAIL unexpected invalid n=%0d",received);
     for(integer p=0;p<4;p=p+1) begin
      integer xx,yy;
      xx=gu[received]>>>12;yy=gv[received]>>>12;
      if(p%2 && xx<width-1)xx=xx+1;if(p>=2 && yy<height-1)yy=yy+1;
      if(samples[p*24+:24]!==pixel(xx,yy))$fatal(1,"CACHE_FAIL n=%0d lane=%0d rgb=%h expected=%h",received,p,samples[p*24+:24],pixel(xx,yy));
     end
    end
   end else if(mask) $fatal(1,"CACHE_FAIL malformed fill published valid");
   received=received+1;
  end
 end
 initial begin
  // Partial edge tiles, same-set four-tile corners, hot hits and full replacement.
  width=35;height=33;
  for(integer p=0;p<count;p=p+1) begin
   if(p<200) begin gu[p]=(TILE_W-1)*4096+300;gv[p]=(TILE_H-1)*4096+700;end
   else if(p%13==0) begin gu[p]=(width-1)*4096;gv[p]=(height-1)*4096;end
   else if(p%17==0) begin gu[p]=-1;gv[p]=0;end
   else begin gu[p]=$urandom_range(0,(width-1)*4096);gv[p]=$urandom_range(0,(height-1)*4096);end
  end
  repeat(4)@(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
  for(sent=0;sent<count;sent=sent+1) begin
   @(negedge clk);iv=1;u=gu[sent];v=gv[sent];tag=sent;
   do @(posedge clk);while(!ir);
  end
  @(negedge clk);iv=0;wait(received==count);wait(frame_ready);@(negedge clk);
  if(error || misses!=requests || bytes_count==0 || peak!=8 || duplicates==0)$fatal(1,"CACHE_FAIL counters error=%b miss=%0d req=%0d peak=%0d",error,misses,requests,peak);
  $display("CACHE_METRICS fill_pixels=%0d pixels=%0d cycles=%0d misses=%0d bus_bytes=%0d queue_peak=%0d max_stall=%0d duplicates=%0d hot_II_checks=%0d",FILL_PIXELS,count,cycles,misses,bytes_count,peak,max_stall,duplicates,hot_ii_checks);
  // Frame invalidation and early LAST: no partial cache line may become a hit.
  checking=0;fault_mode=1;received=0;
  @(negedge clk);start=1;@(negedge clk);start=0;
  @(negedge clk);iv=1;u=0;v=0;tag=0;do @(posedge clk);while(!ir);
  @(negedge clk);iv=0;wait(received==1);wait(frame_ready);@(negedge clk);
  if(!error || misses!=1)$fatal(1,"CACHE_FAIL malformed refill not recorded");
  // An overlong refill must keep the bank invalid and drain through actual LAST.
  fault_mode=0;long_fill_mode=1;received=0;
  @(negedge clk);start=1;@(negedge clk);start=0;
  @(negedge clk);iv=1;u=0;v=0;tag=0;do @(posedge clk);while(!ir);
  @(negedge clk);iv=0;wait(fill_n==256/FILL_PIXELS);
  if(frame_ready)$fatal(1,"CACHE_FAIL undrained long response");
  wait(received==1);wait(frame_ready);if(!error)$fatal(1,"CACHE_FAIL long refill not recorded");
  $display("CACHE_PASS ordered_random_wait duplicates replacement partial_edges fault");$finish;
 end
 initial begin #20000000;$fatal(1,"CACHE_TIMEOUT");end
endmodule

// Same requests and DDR random seed as the reference, with four-bank quad refill.
module tb_rgb_tile_cache_quad;
 tb_rgb_tile_cache #(.FILL_PIXELS(4)) comparison();
endmodule

module tb_rgb_tile_cache_32x8;
 tb_rgb_tile_cache #(.FILL_PIXELS(4),.TILE_X_BITS(5),.TILE_Y_BITS(3)) candidate();
endmodule

module tb_affine_statistics;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,start=0,ready=1;wire sr,ov,ok,last,rejected;wire signed [23:0] x,y;wire [15:0] u,v;wire [63:0] tag;
 integer received=0;
 affine_ray_stepper #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.start_valid(start),.start_ready(sr),
  .start_u(16'd0),.start_v(16'd0),.region_width(16'd64),.region_height(16'd48),
  .a00(32'sd2097152),.a01(32'sd0),.a02(-32'sd67108864),
  .a10(32'sd0),.a11(32'sd2097152),.a12(-32'sd50331648),.region_tag(64'd123),
  .out_valid(ov),.out_ready(ready),.out_x(x),.out_y(y),.out_u(u),.out_v(v),.out_ok(ok),.out_last(last),.out_tag(tag),.rejected(rejected));
 reg stats_start=0,pv=0,pm=1,pl=0,stats_ready=0;reg [15:0] px,py;reg [23:0] rgb;
 wire stats_valid,stats_rejected;wire [47:0] sum;wire [31:0] samples,dark,sat;wire [63:0] stats_tag;
 rgb_frame_statistics #(.TAG_BITS(64)) statistics(.clk(clk),.rst_n(rst_n),.frame_start(stats_start),.frame_tag(64'd432),
  .roi_x(16'd0),.roi_y(16'd0),.roi_width(16'd5),.roi_height(16'd5),.pixel_valid(pv),.pixel_ready(1'b1),
  .pixel_mask(pm),.pixel_last(pl),.pixel_x(px),.pixel_y(py),.pixel_rgb(rgb),.result_valid(stats_valid),.result_ready(stats_ready),
  .result_tag(stats_tag),.luminance_sum(sum),.samples(samples),.dark(dark),.saturated(sat),.rejected(stats_rejected));
 always @(negedge clk)ready=$urandom_range(0,4)!=0;
 always @(posedge clk)if(rst_n && ov && ready)begin
  if(u!==received%64 || v!==received/64 || x!==($signed({1'b0,u})-32)*32768 || y!==($signed({1'b0,v})-24)*32768 ||
     !ok || last!==(received==3071) || tag!==123)$fatal(1,"AFFINE_FAIL n=%0d",received);
  received=received+1;
 end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;@(negedge clk);start=1;@(negedge clk);start=0;
  wait(received==3072);wait(sr);
  @(negedge clk);stats_start=1;@(negedge clk);stats_start=0;
  for(integer p=0;p<25;p=p+1)begin
   @(negedge clk);pv=1;px=p%5;py=p/5;rgb=p==24 ? 24'hffffff : 24'h000000;pl=p==24;
  end
  @(negedge clk);pv=0;wait(stats_valid);@(negedge clk);
  if(samples!==4 || sum!==255 || dark!==3 || sat!==1 || stats_tag!==432)$fatal(1,"STATS_FAIL last-pixel snapshot");
  repeat(5)@(negedge clk);
  if(!stats_valid || sum!==255)$fatal(1,"STATS_FAIL unstable snapshot");
  stats_start=1;@(negedge clk);stats_start=0;if(!stats_rejected)$fatal(1,"STATS_FAIL overwrite snapshot");
  stats_ready=1;@(negedge clk);stats_ready=0;
  // Next-frame reset, RGB order and invalid ROI samples are independently checked.
  @(negedge clk);stats_start=1;@(negedge clk);stats_start=0;
  for(integer p=0;p<25;p=p+1)begin
   @(negedge clk);pv=1;px=p%5;py=p/5;rgb=24'hff0000;pm=p!=0;pl=p==24;
  end
  @(negedge clk);pv=0;wait(stats_valid);@(negedge clk);
  if(samples!==3 || sum!==231 || dark!==0 || sat!==0)$fatal(1,"STATS_FAIL new-frame/reset/mask/RGB order");
  $display("AFFINE_STATS_PASS affine_pixels=3072 ROI_last_snapshot");$finish;
 end
 initial begin #2000000;$fatal(1,"AFFINE_STATS_TIMEOUT");end
endmodule

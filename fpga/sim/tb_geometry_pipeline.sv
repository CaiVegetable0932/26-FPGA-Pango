`timescale 1ns/1ps
// Purpose: complete frame inverse-map/cache/three-mode result, source identity locked.
module tb_geometry_rgb_pipeline #(parameter WIDTH=64,HEIGHT=48,FRAMES=3,SET_BITS=2,SERVICE_SLOTS=10,TILE_X_BITS=5,TILE_Y_BITS=3);
 localparam TILE_W=1<<TILE_X_BITS,TILE_H=1<<TILE_Y_BITS;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,start=0,ready=1;wire frame_ready,ov,mask,done,failed,rejected;
 reg [447:0] coeff;reg [63:0] frame_tag;reg [1:0] mode;
 wire [23:0] rgb;wire [15:0] u,v;wire [63:0] out_tag;
 wire req,fr;reg req_ready=0,fv=0,fl=0;wire [11:0] tx,ty;
 reg [95:0] fill_rgb;reg fill_active=0;integer fill_n=0,fill_x,fill_y;
 reg write_lut=0,commit=0;reg [7:0] addr,data,lut[0:255];
 wire [31:0] version,misses,stalls;wire [63:0] bytes_count;wire [15:0] peak;
 integer received=0,frame_no,cycles=0,frame_cycles,expected_x=0,expected_y=0,block_x=0,block_y=0;string root;
 localparam FOCAL=WIDTH>64 ? 1024 : 32;
 geometry_rgb_pipeline #(.FRAME_TAG_BITS(64),.SET_BITS(SET_BITS),.TILE_X_BITS(TILE_X_BITS),.TILE_Y_BITS(TILE_Y_BITS)) dut(.clk(clk),.rst_n(rst_n),.frame_valid(start),.frame_ready(frame_ready),
  .frame_width(16'(WIDTH)),.frame_height(16'(HEIGHT)),.frame_coefficients(coeff),.frame_tag(frame_tag),.frame_enhancement(mode),.frame_lut_version(32'd91),
  .lut_write(write_lut),.lut_addr(addr),.lut_data(data),.lut_commit(commit),.lut_version(32'd91),
  .out_valid(ov),.out_ready(ready),.out_rgb(rgb),.out_mask(mask),.out_u(u),.out_v(v),.out_frame_tag(out_tag),
  .fill_req_valid(req),.fill_req_ready(req_ready),.fill_tile_x(tx),.fill_tile_y(ty),.fill_valid(fv),.fill_ready(fr),
  .fill_rgb(fill_rgb),.fill_last(fl),.fill_error(1'b0),.fill_bus_bytes(32'(3*TILE_W*(fill_y*TILE_H+TILE_H>HEIGHT ? HEIGHT-fill_y*TILE_H : TILE_H))),
  .frame_done(done),.frame_failed(failed),.config_rejected(rejected),.active_lut_version(version),.cache_misses(misses),.cache_stalls(stalls),
  .cache_bus_bytes(bytes_count),.queue_peak(peak));
 function [23:0] pixel(input integer x,y);
  begin pixel={8'((x*17+y*3)&255),8'((x*5+y*11)&255),8'((x*29+y*7)&255)};end
 endfunction
 always @(negedge clk) begin
  ready=$urandom_range(0,5)!=0;req_ready=$urandom_range(0,4)!=0;
  // Explicit synthetic sharing contract: SERVICE_SLOTS out of each ten clocks
  // are available to source fills; the remainder models competing DMA traffic.
  // This is a transaction-service stress model, not a real DDR arbiter result.
  fv=fill_active && cycles%10<SERVICE_SLOTS && $urandom_range(0,4)!=0;fl=fill_n==63;
  for(integer p=0;p<4;p=p+1)fill_rgb[p*24+:24]=pixel(fill_x*TILE_W+(fill_n%(TILE_W/2))*2+p%2,fill_y*TILE_H+(fill_n/(TILE_W/2))*2+p/2);
 end
 always @(posedge clk) if(rst_n) begin
  cycles=cycles+1;
  if(req && req_ready)begin if(fill_active)$fatal(1,"PIPELINE_FAIL overlapping fill");fill_active=1;fill_n=0;fill_x=tx;fill_y=ty;end
  if(fv && fr)begin if(fl)fill_active=0;else fill_n=fill_n+1;end
  if(ov && ready)begin
   reg [23:0] expected_rgb;
   expected_rgb=pixel(expected_x,expected_y);
   if(frame_no!=0)for(integer c=0;c<3;c=c+1)expected_rgb[c*8+:8]=lut[expected_rgb[c*8+:8]];
   if(rgb!==expected_rgb || !mask || u!==expected_x || v!==expected_y || out_tag!==64'hacdc000000000000+frame_no)
    $fatal(1,"PIPELINE_FAIL frame=%0d n=%0d rgb=%h expected=%h uv=%0d/%0d tag=%h",frame_no,received,rgb,expected_rgb,u,v,out_tag);
   received=received+1;
   if(expected_x==WIDTH-1 || expected_x==block_x+TILE_W-1)begin
    expected_x=block_x;
    if(expected_y==HEIGHT-1 || expected_y==block_y+TILE_H-1)begin
     if(block_x+TILE_W>=WIDTH)begin block_x=0;block_y=block_y+TILE_H;end
     else block_x=block_x+TILE_W;
     expected_x=block_x;expected_y=block_y;
    end else expected_y=expected_y+1;
   end else expected_x=expected_x+1;
  end
 end
 initial begin
  if(!$value$plusargs("VECTORS=%s",root))$fatal(1,"PIPELINE_FAIL missing LUT");$readmemh({root,"/gamma.hex"},lut);
  coeff=0;coeff[0+:32]=67108864/FOCAL;coeff[64+:32]=-(WIDTH/2)*(67108864/FOCAL);
  coeff[128+:32]=67108864/FOCAL;coeff[160+:32]=-(HEIGHT/2)*(67108864/FOCAL);
  coeff[320+:32]=FOCAL*65536;coeff[352+:32]=FOCAL*65536;coeff[384+:32]=(WIDTH/2)*65536;coeff[416+:32]=(HEIGHT/2)*65536;
  repeat(4)@(negedge clk);rst_n=1;
  for(integer i=0;i<256;i=i+1)begin @(negedge clk);write_lut=1;addr=i;data=lut[i];end
  @(negedge clk);write_lut=0;commit=1;@(negedge clk);commit=0;
  for(frame_no=0;frame_no<FRAMES;frame_no=frame_no+1)begin
   received=0;expected_x=0;expected_y=0;block_x=0;block_y=0;
   mode=frame_no;frame_tag=64'hacdc000000000000+frame_no;
   wait(frame_ready);@(negedge clk);start=1;frame_cycles=cycles;@(negedge clk);start=0;
   // Change external parameter wires during active processing: locked copies
   // must continue to produce the original frame; mid-frame START is rejected.
   repeat(30)@(negedge clk);coeff[384+:32]=0;frame_tag=0;start=1;
   @(negedge clk);start=0;if(!rejected)$fatal(1,"PIPELINE_FAIL midframe start");
   wait(done);@(negedge clk);
   if(received!=WIDTH*HEIGHT || failed)$fatal(1,"PIPELINE_FAIL incomplete frame");
   $display("PIPELINE_CASE_PASS mode=%0d pixels=%0d cycles=%0d misses=%0d bytes=%0d modeled_ms_150MHz=%f g=%f service_slots=%0d",mode,received,cycles-frame_cycles,misses,bytes_count,(cycles-frame_cycles)/150000.0,bytes_count/(3.0*received),SERVICE_SLOTS);
   if(WIDTH==1920 && cycles-frame_cycles>5000000)$fatal(1,"PIPELINE_FAIL synthetic 30fps deadline");
   coeff[384+:32]=(WIDTH/2)*65536;
  end
  $display("PIPELINE_PASS frames=%0d frame_identity_locked",FRAMES);$finish;
 end
 initial begin #100000000;$fatal(1,"PIPELINE_TIMEOUT");end
endmodule

module tb_geometry_rgb_pipeline_1080p;
 tb_geometry_rgb_pipeline #(.WIDTH(1920),.HEIGHT(1080),.FRAMES(1),.SET_BITS(5),.SERVICE_SLOTS(4)) full_frame();
endmodule

module tb_geometry_rgb_pipeline_partial;
 tb_geometry_rgb_pipeline #(.WIDTH(35),.HEIGHT(33),.FRAMES(1),.SET_BITS(3)) partial_frame();
endmodule

// A full 1080p RAW stream is a synthetic service/flush test, not real sensor fps.
module tb_raw8_isp_1080p;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,start=0,iv=0,sof=0,eol=0;reg [7:0] raw;
 wire frame_ready,ir,ov,os,oe,ol,mask,error;wire [23:0] rgb;wire [15:0] x,y;wire [63:0] tag;
 integer sent,received=0,cycles=0,begin_cycle;
 raw8_isp #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.frame_start(start),.frame_ready(frame_ready),
  .frame_width(16'd1920),.frame_height(16'd1080),.frame_bayer(2'd0),.black_levels(32'd0),.colour_gains(64'h1000100010001000),
  .frame_tag(64'hff01020304050607),.frame_abort(1'b0),.in_valid(iv),.in_ready(ir),.in_raw(raw),.in_sof(sof),.in_eol(eol),
  .out_valid(ov),.out_ready(1'b1),.out_rgb(rgb),.out_x(x),.out_y(y),.out_sof(os),.out_eol(oe),.out_last(ol),.out_mask(mask),.out_tag(tag),.frame_error(error));
 always @(posedge clk)if(rst_n)begin
  cycles=cycles+1;
  if(ov)begin
   if(rgb!==24'h1159e7 || !mask || x!==received%1920 || y!==received/1920 || os!==(received==0) ||
      oe!==(received%1920==1919) || ol!==(received==2073599) || tag!==64'hff01020304050607)$fatal(1,"ISP1080_FAIL n=%0d",received);
   received=received+1;
  end
 end
 initial begin
  repeat(4)@(negedge clk);rst_n=1;@(negedge clk);start=1;begin_cycle=cycles;@(negedge clk);start=0;
  for(sent=0;sent<2073600;sent=sent+1)begin
   @(negedge clk);iv=1;sof=sent==0;eol=sent%1920==1919;
   case({1'((sent/1920)%2),1'((sent%1920)%2)})0:raw=17;3:raw=231;default:raw=89;endcase
   do @(posedge clk);while(!ir);
  end
  @(negedge clk);iv=0;wait(frame_ready);@(negedge clk);
  if(received!=2073600 || error)$fatal(1,"ISP1080_FAIL incomplete");
  $display("ISP1080_PASS pixels=%0d cycles=%0d modeled_ms_at_150MHz=%f",received,cycles-begin_cycle,(cycles-begin_cycle)/150000.0);$finish;
 end
 initial begin #20000000;$fatal(1,"ISP1080_TIMEOUT");end
endmodule

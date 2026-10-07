`timescale 1ns/1ps
// Purpose: exhaust all tone codes and compare temporal median/reset/line
// behavior against the committed arithmetic implementation cycle by cycle.
module tb_tone_efficiency;
 reg clk=0,rst=0,active=0,line_end=0,accept=0;reg [7:0] sample=0;
 always #4 clk=~clk;
 wire [7:0] a,b;integer i,checks=0;reg [31:0] rng=32'hbeef9876;
 raw8_display_enhance dut(clk,rst,active,line_end,accept,sample,a);
 raw8_display_enhance_golden ref_dut(clk,rst,active,line_end,accept,sample,b);
 task check;begin checks=checks+1;if(a!==b)$fatal(1,"EFFICIENCY_TONE_FAIL sample=%d",sample);end endtask
 initial begin
  repeat(3)@(negedge clk);rst=1;
  for(i=0;i<256;i=i+1)begin @(negedge clk);sample=i;#1;check();end
  for(i=0;i<4096;i=i+1)begin
   @(negedge clk);rng={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
   sample=rng[7:0];active=i%89!=0;line_end=i%97==0;accept=rng[8];
   rst=i%503!=0;#1;check();@(posedge clk);#1;check();
  end
  $display("EFFICIENCY_TONE_PASS checks=%0d exhaustive_codes=256",checks);$finish;
 end
 initial begin #1000000;$fatal(1,"EFFICIENCY_TONE_TIMEOUT");end
endmodule
// Purpose: cycle-exact configuration-bank miter against checkpoint 8b52050b.
// Compare all public replies and state, including bad indices, retries,
// build completion/context invalidation and activation on the same edge.
module tb_config_efficiency;
 reg clk=0,rst=0,context_valid=1,cmd_valid=0,frame_start=0,build_done=0,lut_failed=0;
 always #4 clk=~clk;
 reg [63:0] epoch=1,source_id=0;reg [31:0] session_id=1;
 reg [7:0] cmd=0;reg [255:0] payload=0;
 wire [7:0] code[0:1];wire [95:0] reply[0:1];wire [447:0] words[0:1];
 wire [1:0] model[0:1],bm[0:1];wire enh[0:1],bank[0:1],busy[0:1],failed[0:1],pending[0:1],bs[0:1],bb[0:1];
 wire [31:0] version[0:1],k1[0:1],k2[0:1],k3[0:1],k4[0:1];wire [63:0] fid[0:1];
`define CP(n) .clk(clk),.rst_n(rst),.context_valid(context_valid),.epoch(epoch),.session_id(session_id),.cmd_valid(cmd_valid),.cmd(cmd),.payload(payload),.code(code[n]),.reply(reply[n]),.frame_start(frame_start),.source_frame_id(source_id),.active_words(words[n]),.active_model(model[n]),.active_enhance(enh[n]),.active_bank(bank[n]),.active_version(version[n]),.applied_frame_id(fid[n]),.build_busy(busy[n]),.build_failed(failed[n]),.pending(pending[n]),.build_start(bs[n]),.build_bank(bb[n]),.build_model(bm[n]),.k1(k1[n]),.k2(k2[n]),.k3(k3[n]),.k4(k4[n]),.build_done(build_done),.lut_failed(lut_failed)
 geometry_config_bank dut(`CP(0));
 geometry_config_bank_golden ref_dut(`CP(1));
`undef CP
 wire [1023:0] a={code[0],reply[0],words[0],model[0],enh[0],bank[0],version[0],fid[0],busy[0],failed[0],pending[0],bs[0],bb[0],bm[0],k1[0],k2[0],k3[0],k4[0]};
 wire [1023:0] b={code[1],reply[1],words[1],model[1],enh[1],bank[1],version[1],fid[1],busy[1],failed[1],pending[1],bs[1],bb[1],bm[1],k1[1],k2[1],k3[1],k4[1]};
 integer checks=0,i,j,n;reg [31:0] rng=32'hca115eed;
 function [31:0] advance(input [31:0] v);advance={v[30:0],v[31]^v[21]^v[1]^v[0]};endfunction
 task check;begin checks=checks+1;if(a!==b)$fatal(1,"EFFICIENCY_CONFIG_FAIL check=%0d cmd=%h payload=%h",checks,cmd,payload);end endtask
 always @(posedge clk)begin #1;if(rst)check();end
 task issue(input [7:0] op,input [255:0] p);
  begin @(negedge clk);cmd=op;payload=p;cmd_valid=1;#1;check();@(negedge clk);cmd_valid=0;end
 endtask
 reg [255:0] p;
 initial begin
  repeat(3)@(negedge clk);rst=1;
  for(n=1;n<=40;n=n+1)begin
   p=0;p[127:96]=n;p[135:128]=n%3;p[136]=n%2;p[159:144]=1920;p[175:160]=1080;issue('h30,p);issue('h30,p);
   for(i=0;i<14;i=i+1)begin
    p=0;p[127:96]=n;p[159:128]=i;
    // Purpose: compare cached legality at exact signed limits, one beyond,
    // zero focal length and INT_MIN against the original wide comparisons.
    case(n%8)
     0:p[191:160]=(i==10 || i==11)?65536:0;
     1:p[191:160]=(i>=6 && i<=9)?32'd67108864:32'd268435456;
     2:p[191:160]=(i>=6 && i<=9)?32'd67108865:32'd268435457;
     3:p[191:160]=(i>=6 && i<=9)?-32'sd67108864:-32'sd268435456;
     4:p[191:160]=(i>=6 && i<=9)?-32'sd67108865:-32'sd268435457;
     5:p[191:160]=32'h80000000;
     6:p[191:160]=32'h7fffffff;
     default:p[191:160]=0;
    endcase
    issue('h31,p);issue('h31,p);
   end
   // All read words and metadata, both banks, plus out-of-range values.
   for(i=0;i<20;i=i+1)for(j=0;j<3;j=j+1)begin p=0;p[127:96]=i;p[159:128]=j;issue('h34,p);end
   p=0;p[127:96]=n;issue('h32,p);
   @(negedge clk);build_done=1;lut_failed=n%7==0;
   @(negedge clk);build_done=0;frame_start=1;source_id=source_id+1;
   @(negedge clk);frame_start=0;issue('h33,0);
   if(n%5==0)begin @(negedge clk);epoch=epoch+1;session_id=session_id+1;end
  end
  // Correlated edge cases include reset and context/build/frame races.
  for(n=0;n<5000;n=n+1)begin
   @(negedge clk);rng=advance(rng);cmd='h30+rng%7;cmd_valid=rng[0];
   for(j=0;j<8;j=j+1)begin rng=advance(rng);payload[j*32+:32]=rng;end
   if(n%3==0)payload[127:96]=n%20;
   if(n%4==0)payload[159:128]=n%16;
   if(n%11==0)payload[159:128]=32'h80000000;
   context_valid=rng[2];frame_start=rng[3];build_done=rng[4];lut_failed=rng[5];
   if(n%61==0)epoch=epoch+1;if(n%67==0)session_id=session_id+1;
   if(n==2500)rst=0;if(n==2501)rst=1;
   #1;if(rst)check();
  end
  $display("EFFICIENCY_CONFIG_PASS checks=%0d",checks);$finish;
 end
 initial begin #3000000;$fatal(1,"EFFICIENCY_CONFIG_TIMEOUT");end
endmodule

// Purpose: exact sampler miter with randomized cache/consumer stalls and
// all 4096 horizontal fractions. Compare intermediates, not just rounded bytes.
module tb_sampler_efficiency;
 reg clk=0,rst=0,start=0,source_valid=1,enhance=0,pixel_ready=0;
 always #4 clk=~clk;
 reg [27:0] base=28'h3000000;reg [11:0] x0=0,x1=1,y0=0,y1=1,fx=0,fy=0;
 reg cache_ready=0,cache_valid=0;reg [7:0] cache_value=0;
 wire ready[0:1],valid[0:1],mask[0:1],req[0:1],consume[0:1];wire [7:0] pixel[0:1];wire [27:0] addr[0:1];
`define SP(n) .clk(clk),.rst_n(rst),.start(start),.source_valid(source_valid),.enhance(enhance),.base(base),.x0(x0),.x1(x1),.y0(y0),.y1(y1),.frac_x(fx),.frac_y(fy),.ready(ready[n]),.valid(valid[n]),.pixel_ready(pixel_ready),.pixel(pixel[n]),.mask_valid(mask[n]),.cache_req(req[n]),.cache_ready(cache_ready),.cache_addr(addr[n]),.cache_valid(cache_valid),.cache_response_ready(consume[n]),.cache_value(cache_value)
 geometry_gray_sampler dut(`SP(0));geometry_gray_sampler_golden ref_dut(`SP(1));
`undef SP
 integer checks=0,completed=0,n;reg outstanding=0;reg [31:0] rng=32'habcd7654;
 function [31:0] advance(input [31:0] v);advance={v[30:0],v[31]^v[21]^v[1]^v[0]};endfunction
 always @(negedge clk)if(rst)begin
  rng=advance(rng);cache_ready=rng[0];cache_valid=outstanding && rng[1];
  // Hold the earlier result until both implementations can be compared.
  // The timing candidate drains its last curve byte for one extra cycle.
  pixel_ready=rng[2] && valid[0] && valid[1];
  // Alternate arbitrary values with all-black/all-white footprints.
  cache_value=n%17==0?0:n%19==0?255:rng[15:8];
 end
 always @(posedge clk)if(rst)begin
  if(req[0] && cache_ready)outstanding<=1;
  if(cache_valid && consume[0])outstanding<=0;
  if(valid[0] && pixel_ready)completed=completed+1;
  #1;checks=checks+1;
  if({req[0],consume[0]}!=={req[1],consume[1]})$fatal(1,"EFFICIENCY_SAMPLER_FAIL cache handshake");
  if(req[0] && addr[0]!==addr[1])$fatal(1,"EFFICIENCY_SAMPLER_FAIL address");
  if(valid[0] && valid[1] && {pixel[0],mask[0]}!=={pixel[1],mask[1]})$fatal(1,"EFFICIENCY_SAMPLER_FAIL pixel n=%0d",n);
  if(dut.state==4 && {dut.top,dut.bottom}!=={ref_dut.top,ref_dut.bottom})$fatal(1,"EFFICIENCY_SAMPLER_FAIL rows");
  if(dut.state==5 && dut.weighted!==ref_dut.weighted)$fatal(1,"EFFICIENCY_SAMPLER_FAIL weighted");
 end
 initial begin
  repeat(3)@(negedge clk);rst=1;
  for(n=0;n<4096;n=n+1)begin
   wait(ready[0]);@(negedge clk);#1;
   x0=n%1920;y0=n%1080;x1=x0==1919?x0:x0+1;y1=y0==1079?y0:y0+1;
   fx=n;fy=n%4==0?0:n%4==1?4095:rng[27:16];source_valid=n%23!=0;enhance=n%2;
   start=1;@(negedge clk);#1;start=0;wait(valid[0]);wait(ready[0]);
  end
  $display("EFFICIENCY_SAMPLER_PASS pixels=%0d checks=%0d",completed,checks);$finish;
 end
 initial begin #10000000;$fatal(1,"EFFICIENCY_SAMPLER_TIMEOUT");end
endmodule

// Purpose: latency-insensitive mapper equivalence including fast bypass,
// clipped coordinates, both lens modes and output backpressure retention.
module tb_map_efficiency;
 reg clk=0,rst=0,request=0,consume=0;always #4 clk=~clk;
 reg [1:0] model=0;reg [447:0] words=0;reg [11:0] ox=0,oy=0;
 wire ready[0:1],valid[0:1],sv[0:1];wire [11:0] x0[0:1],x1[0:1],y0[0:1],y1[0:1],fx[0:1],fy[0:1];wire [10:0] li[0:1];
`define MP(n) .clk(clk),.rst_n(rst),.model(model),.words(words),.request_valid(request),.request_ready(ready[n]),.ox(ox),.oy(oy),.result_valid(valid[n]),.result_ready(consume),.source_valid(sv[n]),.x0(x0[n]),.x1(x1[n]),.y0(y0[n]),.y1(y1[n]),.frac_x(fx[n]),.frac_y(fy[n]),.lut_index(li[n]),.scale0(32'sd67108864),.scale1(32'sd67108864)
 geometry_map_engine dut(`MP(0));geometry_map_engine_golden ref_dut(`MP(1));
`undef MP
 wire [72:0] a={sv[0],x0[0],x1[0],y0[0],y1[0],fx[0],fy[0]};
 wire [72:0] b={sv[1],x0[1],x1[1],y0[1],y1[1],fx[1],fy[1]};
 integer n,cycles=0,launch_at,fast_cycles,old_cycles;reg seen;reg [72:0] held;
 always @(posedge clk)cycles=cycles+1;
 initial begin
  words[31:0]=65536;words[159:128]=65536;words[351:320]=67108864;words[383:352]=67108864;
  repeat(3)@(negedge clk);rst=1;
  for(n=0;n<600;n=n+1)begin
   wait(ready[0] && ready[1]);@(negedge clk);model=n%3;ox=(n*37)%2200;oy=(n*53)%1200;
   request=1;launch_at=cycles;@(negedge clk);request=0;seen=0;
   while(!valid[0] || !valid[1])begin
    if(valid[0] && !seen)begin seen=1;held=a;fast_cycles=cycles-launch_at;end
    if(seen && (!valid[0] || a!==held))$fatal(1,"EFFICIENCY_MAP_FAIL early hold");
    @(negedge clk);
   end
   old_cycles=cycles-launch_at;if(!seen)fast_cycles=old_cycles;
   if(a!==b)$fatal(1,"EFFICIENCY_MAP_FAIL outputs n=%0d",n);
   if(model==0 && fast_cycles>=old_cycles)$fatal(1,"EFFICIENCY_MAP_FAIL no bypass gain");
   held=a;repeat(3)begin @(negedge clk);if(a!==held || !valid[0])$fatal(1,"EFFICIENCY_MAP_FAIL hold");end
   consume=1;@(negedge clk);consume=0;
  end
  $display("EFFICIENCY_MAP_PASS transactions=%0d",n);$finish;
 end
 initial begin #2000000;$fatal(1,"EFFICIENCY_MAP_TIMEOUT");end
endmodule

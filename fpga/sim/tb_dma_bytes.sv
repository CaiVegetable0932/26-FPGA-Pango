`timescale 1ns/1ps
// Purpose: independent byte-level pack/unpack and stride/column/slot scoreboard.
module tb_dma_bytes #(parameter ALIGNED_ROWS=0);
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,ps=0,rgb888=0,pv=0,pl=0,br=0;
 reg [4:0] po=0;reg [23:0] pixel=0;
 wire psr,pr,bv,bl;wire [255:0] bd;wire [31:0] bs;
 dma_pixel_pack pack(clk,rst_n,ps,psr,po,rgb888,pv,pr,pixel,pl,bv,br,bd,bs,bl);
 reg us=0,ubv=0,cr=0;reg [4:0] uo=0;reg [31:0] ub=0;reg [255:0] ubd=0;
 wire usr,ubr,cv,cl;wire [255:0] cd;wire [5:0] cb;
 // Reuse the independent byte/LAST/stall scoreboard for both implementations;
 // aligned mode exercises partial tails but never promises offset removal.
 dma_byte_unpack #(.ALIGNED_ROWS(ALIGNED_ROWS)) unpack(clk,rst_n,us,usr,uo,ub,ubv,ubr,ubd,cv,cr,cd,cb,cl);
 reg ds=0,drr=0;wire dsr,drv,df,dl,dfl,dd,de;
 reg [31:0] base=0,rowbytes=0,stride=0,sbegin=0,sendaddr=0;reg [15:0] rows=0;
 wire [31:0] da,deb;wire [4:0] dn,doffset;
 dma_row_plan plan(clk,rst_n,ds,dsr,base,rowbytes,stride,rows,sbegin,sendaddr,drv,drr,da,dn,doffset,deb,df,dl,dfl,dd,de);
 integer seed=555,seed_arg,total=0;
 integer p_offset,p_bytes,p_seen=0,p_beat=0,u_seen=0,u_bytes,u_offset;
 integer drow=0,dbeat=0,dtotal=0,d_expected=0;
 reg pack_check=0,unpack_check=0,plan_check=0;
 reg pstall=0,ustall=0,dstall=0;
 reg [288:0] pheld;reg [262:0] uheld;reg [44:0] dheld;
 function automatic [7:0] pattern(input integer x);pattern=(x*29+71)&255;endfunction
 always @(negedge clk) begin br=($random(seed)&3)!=0;cr=($random(seed)&3)!=0;drr=($random(seed)&3)!=0;end
 // Purpose: validate actual bytes and masks against unaligned effective range.
 always @(posedge clk) if(rst_n) begin
  if(pstall && {bd,bs,bl}!==pheld) $fatal(1,"packer output changed under stall");
  if(ustall && {cd,cb,cl}!==uheld) $fatal(1,"unpacker changed under stall");
  if(dstall && {da,dn,doffset,df,dl,dfl}!==dheld) $fatal(1,"planner changed under stall");
  pstall=bv&&!br;ustall=cv&&!cr;dstall=drv&&!drr;
  pheld={bd,bs,bl};uheld={cd,cb,cl};dheld={da,dn,doffset,df,dl,dfl};
  if(pack_check && bv&&br) begin
   for(integer b=0;b<32;b=b+1) begin
    integer x;x=p_beat*32+b-p_offset;
    if(bs[b]!=(x>=0 && x<p_bytes)) $fatal(1,"mask offset=%0d beat=%0d byte=%0d",p_offset,p_beat,b);
    if(bs[b]) begin
     if(bd[b*8+:8]!==pattern(x)) $fatal(1,"pack byte mismatch");p_seen=p_seen+1;
    end
   end
   if(bl!=(p_beat==(p_offset+p_bytes+31)/32-1)) $fatal(1,"pack LAST");
   p_beat=p_beat+1;
  end
  if(unpack_check && cv&&cr) begin
   if(cb==0 || cb>32 || cb!=(u_bytes-u_seen>=32 ? 32 : u_bytes-u_seen)) $fatal(1,"unpack chunk size");
   for(integer b=0;b<cb;b=b+1) if(cd[b*8+:8]!==pattern(u_seen+b)) $fatal(1,"unpack byte");
   u_seen=u_seen+cb;
   if(cl!=(u_seen==u_bytes)) $fatal(1,"unpack LAST");
  end
  if(plan_check && drv&&drr) begin
   integer aligned,n,left,col;n=0;
   aligned=(base+drow*stride)&32'hffffffe0;
   left=((base+drow*stride)%32+rowbytes+31)/32-dbeat;
   col=(4096-(aligned+dbeat*32)%4096)/32;
   n=left<16 ? left : 16;if(n>col)n=col;
   if(da!=aligned+dbeat*32 || dn!=n || doffset!=(base+drow*stride)%32 || deb!=rowbytes)
    $fatal(1,"plan address/count row=%0d beat=%0d",drow,dbeat);
   if(df!=(dbeat==0) || dl!=(n==left) || dfl!=(n==left && drow==rows-1)) $fatal(1,"plan row flags");
   dtotal=dtotal+dn*32;
   if(dl) begin drow=drow+1;dbeat=0;end else dbeat=dbeat+dn;
  end
 end
 task automatic pack_case(input integer off,input integer pixels,input bit rgb);
  integer x,n;
  begin
   @(negedge clk);p_offset=off;p_bytes=pixels*(rgb?3:1);p_seen=0;p_beat=0;pack_check=1;
   ps=1;po=off;rgb888=rgb;@(negedge clk);ps=0;
   for(x=0;x<pixels;x=x+1) begin
    n=x*(rgb?3:1);pixel={pattern(n+2),pattern(n+1),pattern(n)};pv=1;pl=x==pixels-1;
    do @(posedge clk);while(!pr);
    @(negedge clk);pv=0;pl=0;
   end
   wait(psr);@(negedge clk);
   if(p_seen!=p_bytes) $fatal(1,"pack count");pack_check=0;total=total+1;
  end
 endtask
 task automatic unpack_case(input integer off,input integer n);
  integer beat,b;
  begin
   @(negedge clk);u_offset=off;u_bytes=n;u_seen=0;unpack_check=1;uo=off;ub=n;us=1;
   @(negedge clk);us=0;
   for(beat=0;beat<(off+n+31)/32;beat=beat+1) begin
    for(b=0;b<32;b=b+1) ubd[b*8+:8]=pattern(beat*32+b-off);
    ubv=1;do @(posedge clk);while(!ubr);@(negedge clk);ubv=0;
   end
   wait(usr);@(negedge clk);if(u_seen!=n)$fatal(1,"unpack count");unpack_check=0;total=total+1;
  end
 endtask
 task automatic plan_case(input integer a,input integer rb,input integer st,input integer nr,input integer lim,input bit bad);
  begin
   @(negedge clk);base=a;rowbytes=rb;stride=st;rows=nr;sbegin=0;sendaddr=lim;
   drow=0;dbeat=0;dtotal=0;plan_check=!bad;ds=1;@(negedge clk);ds=0;
   wait(dd);@(negedge clk);
   if(de!=bad) $fatal(1,"descriptor rejection mismatch");
   if(!bad && drow!=nr) $fatal(1,"planned row count");
   if(!bad) $display("DMA_PLAN_METRIC row_bytes=%0d stride=%0d rows=%0d bus_bytes=%0d useful_bytes=%0d",rb,st,nr,dtotal,rb*nr);
   plan_check=0;total=total+1;
  end
 endtask
 initial begin
  if($value$plusargs("seed=%d",seed_arg)) seed=seed_arg;
  repeat(4) @(negedge clk);rst_n=1;
  for(integer off=0;off<32;off=off+1) begin
   pack_case(off,1,0);pack_case(off,1,1);pack_case(off,16,1);
   pack_case(off,35,0);pack_case(off,45,1);
   if(!ALIGNED_ROWS || off==0)begin
    unpack_case(off,1);unpack_case(off,48);unpack_case(off,97);
   end
  end
  pack_case(0,1920,0);pack_case(0,1920,1);unpack_case(0,1920);unpack_case(0,5760);
  plan_case(0,1920,2048,1080,32'h00400000,0);
  plan_case(0,5760,6144,1080,32'h00800000,0);
  plan_case(4093,48,6144,16,131072,0);
  plan_case(131008,48,64,1,131072,0);
  plan_case(131040,48,64,1,131072,1);
  plan_case(0,48,32,16,131072,1);plan_case(0,0,64,1,131072,1);plan_case(0,48,64,0,131072,1);
  $display("DMA_BYTES_PASS tests=%0d",total);$finish;
 end
 initial begin #2000000;$fatal(1,"DMA_BYTES_TIMEOUT");end
endmodule

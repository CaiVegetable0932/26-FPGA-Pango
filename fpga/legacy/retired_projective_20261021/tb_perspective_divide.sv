`timescale 1ns/1ps
module tb_perspective_divide;
 reg clk=0;always #3.333 clk=~clk;
 reg rst_n=0,iv=0,ready=1;wire ir,ov,ok;reg signed [39:0] q0,q1,q2;
 reg [63:0] itag;wire [63:0] otag;wire signed [23:0] x,y;
 reg [39:0] a[0:2999],b[0:2999],d[0:2999];reg [23:0] gx[0:2999],gy[0:2999];integer gok[0:2999];
 integer fd,rc,n=0,sent,received=0;string root;
 perspective_divide #(.TAG_BITS(64)) dut(.clk(clk),.rst_n(rst_n),.in_valid(iv),.in_ready(ir),.q0(q0),.q1(q1),.q2(q2),
  .in_ok(1'b1),.in_tag(itag),.out_valid(ov),.out_ready(ready),.out_x(x),.out_y(y),.out_ok(ok),.out_tag(otag));
 always @(negedge clk) ready=received<300 ? 1 : $urandom_range(0,3)!=0;
 always @(posedge clk) if(rst_n && ov && ready) begin
  if(otag!==received || ok!==gok[received][0] || (ok && (x!==gx[received] || y!==gy[received])))
   $fatal(1,"PERSPECTIVE_FAIL n=%0d x/y=%0d/%0d expected=%0d/%0d ok=%b expected=%0d",received,x,y,$signed(gx[received]),$signed(gy[received]),ok,gok[received]);
  received=received+1;
 end
 initial begin
  if(!$value$plusargs("VECTORS=%s",root)) $fatal(1,"PERSPECTIVE_FAIL missing vectors");
  fd=$fopen({root,"/perspective.txt"},"r");if(!fd) $fatal(1,"PERSPECTIVE_FAIL open");
  while(!$feof(fd)) begin
   rc=$fscanf(fd,"%h %h %h %h %h %d\n",a[n],b[n],d[n],gx[n],gy[n],gok[n]);
   if(rc==6) n=n+1;else if(!$feof(fd)) $fatal(1,"PERSPECTIVE_FAIL malformed vector");
  end
  repeat(4) @(negedge clk);rst_n=1;
  for(sent=0;sent<n;sent=sent+1) begin
   @(negedge clk);iv=1;q0=a[sent];q1=b[sent];q2=d[sent];itag=sent;
   do @(posedge clk);while(!ir);
  end
  @(negedge clk);iv=0;wait(received==n);@(negedge clk);
  $display("PERSPECTIVE_PASS pixels=%0d",n);$finish;
 end
 initial begin #2000000;$fatal(1,"PERSPECTIVE_TIMEOUT");end
endmodule


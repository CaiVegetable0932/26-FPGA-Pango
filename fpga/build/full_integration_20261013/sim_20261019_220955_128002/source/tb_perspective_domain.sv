`timescale 1ns/1ps
// Scan the full accepted signed40 depth domain, including rounding carries,
// minimum depth, negative/zero rejection and global CE backpressure. Exact
// signed64 integer division is independent of the reciprocal implementation.
module tb_perspective_domain;
 localparam N=4096;
 reg clk=0,rst=0,valid=0,ready=1;always #4 clk=~clk;
 reg signed [39:0] a,b,d;reg [31:0] tag;wire input_ready,output_valid,ok;
 wire signed [23:0] x,y;wire [31:0] output_tag;
 perspective_divide #(.TAG_BITS(32)) dut(clk,rst,valid,input_ready,a,b,d,1'b1,tag,output_valid,ready,x,y,ok,output_tag);
 reg signed [39:0] qa[0:N-1],qb[0:N-1],qd[0:N-1];
 reg signed [63:0] numerator,denominator,expected_x,expected_y,dx,dy,depth;
 reg [63:0] random_bits;reg [31:0] seed=32'h13abcd77;integer i,bit_position,cycles=0,count=0;
 always @(negedge clk)ready=cycles%11!=4 && cycles%11!=5 && cycles%11!=6;
 always @(posedge clk)if(rst)begin
  cycles=cycles+1;
  if(output_valid && ready)begin
   if(output_tag!=count)$fatal(1,"Depth scan tag/order changed");
   denominator=$signed(qd[count]);
   if(denominator>=16384)begin
    numerator=($signed(qa[count])<<<20)+denominator/2;expected_x=numerator/denominator;
    if(numerator<0 && numerator%denominator!=0)expected_x=expected_x-1;
    numerator=($signed(qb[count])<<<20)+denominator/2;expected_y=numerator/denominator;
    if(numerator<0 && numerator%denominator!=0)expected_y=expected_y-1;
    dx=$signed(x)-expected_x;dy=$signed(y)-expected_y;
    if(!ok || dx>2 || dx< -2 || dy>2 || dy< -2)$fatal(1,"Depth-domain precision depth=%0d dx=%0d dy=%0d",denominator,dx,dy);
   end else if(ok)$fatal(1,"Invalid depth accepted");
   count=count+1;
  end
 end
 initial begin
  #100;rst=1;
  for(i=0;i<N;i=i+1)begin
   @(negedge clk);bit_position=14+i%25;random_bits={$random(seed),$random(seed)};
   case(i%4)
    0:depth=64'd1<<bit_position;
    1:depth=(64'd1<<(bit_position+1))-1;
    2:depth=(64'd1<<bit_position)+1;
    3:depth=(64'd1<<bit_position)|(random_bits&((64'd1<<bit_position)-1));
   endcase
   case(i)0:depth=0;1:depth=16383;2:depth=-67108864;3:depth=16384;endcase
   a=(-3*depth)/4;b=depth/3;d=depth;tag=i;qa[i]=a;qb[i]=b;qd[i]=d;valid=1;
   @(posedge clk);while(!input_ready)@(posedge clk);
  end
  @(negedge clk);valid=0;wait(count==N);$display("TB_PERSPECTIVE_DOMAIN_PASS pixels=%0d",count);$finish;
 end
 initial begin #2000000;$fatal(1,"Depth-domain timeout");end
endmodule

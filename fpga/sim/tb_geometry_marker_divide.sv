// Purpose: cycle-exact miter against an immutable pre-CE-fix divider, plus an
// independent unsigned-magnitude arithmetic/latency oracle. Scratch bits may
// differ only while idle; no external output is treated as a don't-care.
`timescale 1ns/1ps
module tb_geometry_marker_divide;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,start=0;
 reg signed [95:0] numerator=0;reg signed [63:0] denominator=0;
 wire done,failed,ref_done,ref_failed;
 wire signed [95:0] result,ref_result;
 geometry_marker_divide dut(clk,rst_n,start,numerator,denominator,done,failed,result);
 geometry_marker_divide_reference reference_dut(clk,rst_n,start,numerator,denominator,ref_done,ref_failed,ref_result);
 integer seed=20261007,prng,cycles=0,accepted=0,completed=0,zero_count=0;
 integer busy_starts=0,resets_busy=0,idle_cycles=0,remaining=0;
 integer i,j,k,stream_cycle;reg expected_busy=0,expected_done=0,expected_failed=0;
 reg [95:0] magnitude_n,expected_result=0,pending_result;
 reg [63:0] magnitude_d;
 reg [95:0] numerators[0:7];reg [63:0] denominators[0:7];
 // Purpose: check held outputs every clock, including ignored busy-start,
// completion-edge start, reset aborts and repeated zero-divide starts.
 always @(posedge clk)begin
  if(!rst_n)begin
   if(expected_busy)resets_busy=resets_busy+1;
   expected_busy=0;expected_done=0;expected_failed=0;expected_result=0;remaining=0;
  end else begin
   expected_done=0;
   if(start && !expected_busy)begin
    accepted=accepted+1;expected_failed=denominator==0;
    if(denominator==0)begin expected_done=1;expected_result=0;zero_count=zero_count+1;end
    else begin
     magnitude_n=numerator[95]?-numerator:numerator;
     magnitude_d=denominator[63]?-denominator:denominator;
     pending_result=magnitude_n/{32'b0,magnitude_d};
     if(numerator[95]^denominator[63])pending_result=-pending_result;
     expected_busy=1;remaining=96;
    end
   end else if(expected_busy)begin
    if(start)busy_starts=busy_starts+1;
    remaining=remaining-1;
    if(remaining==0)begin
     expected_busy=0;expected_done=1;expected_result=pending_result;completed=completed+1;
    end
   end else idle_cycles=idle_cycles+1;
  end
  #1;cycles=cycles+1;
  if({done,failed,result}!=={ref_done,ref_failed,ref_result})
   $fatal(1,"DIVIDER_MITER_FAIL cycle=%0d dut=%b/%b/%h ref=%b/%b/%h",cycles,done,failed,result,ref_done,ref_failed,ref_result);
  if({done,failed,result}!=={expected_done,expected_failed,expected_result})
   $fatal(1,"DIVIDER_ORACLE_FAIL cycle=%0d remaining=%0d result=%h expected=%h",cycles,remaining,result,expected_result);
  if(dut.busy!==reference_dut.busy || dut.busy!==expected_busy)
   $fatal(1,"DIVIDER_BUSY_FAIL cycle=%0d",cycles);
 end
 // Asynchronous reset must clear observable state without waiting for clk.
 always @(negedge rst_n)begin
  #1;if({done,failed,result}!==98'b0 || {ref_done,ref_failed,ref_result}!==98'b0)
   $fatal(1,"DIVIDER_ASYNC_RESET_FAIL");
 end
 task random_operands;
  begin numerator={$random(prng),$random(prng),$random(prng)};denominator={$random(prng),$random(prng)};end
 endtask
 task transaction(input [95:0] n,input [63:0] d,input integer noise);
  begin
   @(negedge clk);numerator=n;denominator=d;start=1;
   @(posedge clk);#2;
   while(reference_dut.busy)begin
    @(negedge clk);random_operands;start=noise && (($unsigned($random(prng))%3)!=0);
    @(posedge clk);#2;
   end
   @(negedge clk);start=0;
  end
 endtask
 initial begin
  if($value$plusargs("SEED=%d",seed))begin end
  prng=seed;
  numerators[0]=0;numerators[1]=1;numerators[2]=-96'd1;numerators[3]=96'h800000000000000000000000;
  numerators[4]=96'h7fffffffffffffffffffffff;numerators[5]=96'haaaaaaaaaaaaaaaaaaaaaaaa;
  numerators[6]=96'h555555555555555555555555;numerators[7]=96'h000000008000000000000000;
  denominators[0]=0;denominators[1]=1;denominators[2]=-64'd1;denominators[3]=64'h8000000000000000;
  denominators[4]=64'h7fffffffffffffff;denominators[5]=2;denominators[6]=-64'd2;denominators[7]=3;
  repeat(3)@(negedge clk);rst_n=1;
  // Cross signed minima/maxima, zero and +/-1. Min96/-1 intentionally wraps
  // to the original 96-bit result; no saturation/overflow policy is added.
  for(i=0;i<8;i=i+1)for(j=0;j<8;j=j+1)transaction(numerators[i],denominators[j],1);
  for(i=0;i<96;i=i+1)begin
   transaction(96'd1<<i,(64'd1<<(i%64)),1);
   transaction(-(96'd1<<i),-(64'd1<<(i%64)),1);
  end
  for(i=0;i<2048;i=i+1)begin
   random_operands;
   transaction(numerator,(i%17==0)?64'd0:denominator,1);
  end
  // A held start must remain ignored at the 96th busy edge, then immediately
  // begin a new transaction on the following idle edge. Zero-divide may pulse
  // done on every held-start cycle, matching the original interface exactly.
  @(negedge clk);start=1;numerator=-96'd987654321;denominator=64'd7;
  repeat(300)@(negedge clk);start=0;
  wait(!reference_dut.busy);@(negedge clk);start=1;denominator=0;
  repeat(5)@(negedge clk);start=0;
  // Reset every iteration position, including just before the completion
  // edge. Long idle after zero-divide exposes irrelevant scratch shifting.
  for(k=0;k<96;k=k+1)begin
   @(negedge clk);start=1;numerator=numerators[4];denominator=3;
   @(negedge clk);start=0;
   repeat(k)@(negedge clk);
   #1;rst_n=0;repeat(2)@(negedge clk);rst_n=1;
  end
  for(stream_cycle=0;stream_cycle<30000;stream_cycle=stream_cycle+1)begin
   @(negedge clk);random_operands;start=($unsigned($random(prng))%4!=0);
   if(stream_cycle%113==0)denominator=0;
   rst_n=(stream_cycle%997!=17);
  end
  @(negedge clk);rst_n=1;start=0;wait(!reference_dut.busy);
  repeat(120)@(negedge clk);
  if(completed<2000 || zero_count<100 || busy_starts<1000 || resets_busy<96 || idle_cycles<120)
   $fatal(1,"DIVIDER_COVERAGE_FAIL");
  $display("MARKER_DIVIDER_PASS seed=%0d cycles=%0d accepted=%0d completed=%0d zero=%0d busy_start=%0d reset_busy=%0d idle=%0d nonzero_latency=96 zero_latency=0",seed,cycles,accepted,completed,zero_count,busy_starts,resets_busy,idle_cycles);
  $finish;
 end
 initial begin #10000000;$fatal(1,"DIVIDER_TIMEOUT");end
endmodule

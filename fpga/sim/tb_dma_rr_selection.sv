`timescale 1ns/1ps
// Exhaustively compare the implementation arbiter against the original cyclic
// specification for all six-client eligibility/urgency masks and quota states.
// Native transport/cancel/readback behavior is tested by the integration benches.
module tb_dma_rr_selection;
 reg [5:0] eligible_mask,urgent_mask;
 reg [2:0] cursor;
 reg [1:0] quota;
 integer r,e,u,q,offset,index,normal_expected,urgent_expected,expected,checks;
 ddr_native_dma dut(.clk(1'b0),.rst_n(1'b0),.urgent(urgent_mask));
 initial begin
  force dut.eligible=eligible_mask;
  force dut.rr=cursor;
  force dut.emergency_run=quota;
  checks=0;
  for(r=0;r<6;r=r+1)for(e=0;e<64;e=e+1)for(u=0;u<64;u=u+1)for(q=0;q<3;q=q+1)begin
   cursor=r;eligible_mask=e;urgent_mask=u;quota=q;
   normal_expected=-1;urgent_expected=-1;
   for(offset=0;offset<6;offset=offset+1)begin
    index=(r+offset)%6;
    if((e>>index)&1)begin
     if(normal_expected<0)normal_expected=index;
     if(((u>>index)&1) && urgent_expected<0)urgent_expected=index;
    end
   end
   expected=(urgent_expected>=0 && q<2)?urgent_expected:normal_expected;
   #1;
   if(dut.chosen!==expected || dut.normal_choice!==normal_expected || dut.urgent_choice!==urgent_expected)
    $fatal(1,"RR mismatch cursor=%0d eligible=%0h urgent=%0h quota=%0d",r,e,u,q);
   checks=checks+1;
  end
  $display("DMA_RR_SELECTION_PASS checks=%0d",checks);$finish;
 end
endmodule

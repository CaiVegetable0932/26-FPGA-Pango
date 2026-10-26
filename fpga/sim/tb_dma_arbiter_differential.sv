`timescale 1ns/1ps
// Purpose: exhaustively compare the actual original/new arbitration blocks.
// Only arbitration inputs are forced; complete transport/ownership behavior
// is checked separately with independent full-DMA instances and memory models.
module tb_dma_arbiter_differential #(parameter CLIENTS=6);
 localparam RR_BITS=CLIENTS>1?$clog2(CLIENTS):1;
 reg [CLIENTS-1:0] eligible_cases=0,urgent_cases=0;
 reg [RR_BITS-1:0] rr_value=0;reg [1:0] emergency_value=0;
 integer eligible_mask,urgent_mask,rr_index,quota_index,checks=0;
 ddr_native_dma #(.CLIENTS(CLIENTS),.MAX_BEATS(1)) candidate(
  .clk(1'b0),.rst_n(1'b0),.controller_ready(1'b1),.urgent(urgent_cases));
 baseline_arbiter_dma #(.CLIENTS(CLIENTS),.MAX_BEATS(1)) reference_impl(
  .clk(1'b0),.rst_n(1'b0),.controller_ready(1'b1),.urgent(urgent_cases));
 initial begin
  // Both original and candidate receive all possible legal selector inputs;
  // no output or derived selection is shared between the two implementations.
  force candidate.eligible=eligible_cases;force reference_impl.eligible=eligible_cases;
  force candidate.rr=rr_value;force reference_impl.rr=rr_value;
  force candidate.emergency_run=emergency_value;force reference_impl.emergency_run=emergency_value;
  for(eligible_mask=0;eligible_mask<(1<<CLIENTS);eligible_mask=eligible_mask+1)
   for(urgent_mask=0;urgent_mask<(1<<CLIENTS);urgent_mask=urgent_mask+1)
    for(rr_index=0;rr_index<CLIENTS;rr_index=rr_index+1)
     for(quota_index=0;quota_index<=2;quota_index=quota_index+1)begin
      eligible_cases=eligible_mask;urgent_cases=urgent_mask;rr_value=rr_index;emergency_value=quota_index;#1;
      checks=checks+1;
      if({candidate.chosen,candidate.normal_choice,candidate.urgent_choice} !==
         {reference_impl.chosen,reference_impl.normal_choice,reference_impl.urgent_choice})
       $fatal(1,"ARBITER mismatch eligible=%h urgent=%h rr=%0d quota=%0d",eligible_cases,urgent_cases,rr_index,quota_index);
     end
  $display("DMA_ARBITER_DIFFERENTIAL_PASS clients=%0d checks=%0d",CLIENTS,checks);$finish;
 end
 initial begin #10000000;$fatal(1,"ARBITER exhaustive timeout");end
endmodule


































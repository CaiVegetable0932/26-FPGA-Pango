`timescale 1ns/1ps
// Independent scheduler/processor agents check all 1358 job bits and 96 return
// bits, asynchronous clock phases, backpressure, failure/cancellation outcome,
// instant completion, common reset while offered/running, and immediate reuse.
// The mailbox has no cancellation input: a drained cancelled job reports failed.
module tb_processing_job_snapshot;
 parameter real SOURCE_HALF=4.0,PROCESSING_HALF=3.333,PROCESSING_PHASE=0.7;
 localparam BITS=1358;
 reg sclk=0,pclk=0,srst=0,prst=0;
 always #SOURCE_HALF sclk=~sclk;
 initial begin #PROCESSING_PHASE;forever #PROCESSING_HALF pclk=~pclk;end
 reg sv=0,pr=0,pdone=0,pfail=0;
 reg [BITS-1:0] job=0,expected;
 wire sr,sd,sf,pv;wire [BITS-1:0] pj;
 // The return payload is scored independently; no test expectation reads DUT state.
 reg [95:0] presult=0,expected_result=0;wire [95:0] sresult;
 processing_job_cdc #(.JOB_BITS(BITS),.RESULT_BITS(96)) dut(
 .source_clk(sclk),.source_rst_n(srst),.source_valid(sv),.source_ready(sr),
 .source_job(job),.source_done(sd),.source_failed(sf),.processing_clk(pclk),
 .processing_rst_n(prst),.processing_valid(pv),.processing_ready(pr),
 .processing_job(pj),.processing_done(pdone),.processing_failed(pfail),
 .processing_result(presult),.source_result(sresult));
 integer cases=0,accepted=0,completed=0,i,b,waited;
 reg drained=0;
 // A completion must never escape before the independent processor declares
 // all its modeled memory requests drained; reset discards the pending job.
 always @(posedge sclk)if(srst && sd && !drained)$fatal(1,"Early scheduler retirement");
 task reset_both;
  begin
   srst=0;prst=0;sv=0;pr=0;pdone=0;pfail=0;drained=0;
   #17;@(negedge sclk);srst=1;@(negedge pclk);prst=1;
   repeat(8)@(negedge sclk);
   if(sd || !sr || pv)$fatal(1,"Reset did not flush mailbox");
  end
 endtask
 task make_job(input integer n);
  begin
   // Exercise every one of the 1358 bits, including top metadata and slots.
   for(b=0;b<BITS;b=b+1)job[b]=((b*17+n*31+(b>>3))%13)<6;
   expected=job;
  end
 endtask
 task transact(input integer n,input integer fail_job,input integer instant);
  begin
   make_job(n);drained=0;
   expected_result={32'(n*65537+73),32'(n*8191+17),32'(n*7+3)};
   fork
    begin
     @(negedge sclk);sv=1;
     @(posedge sclk);while(!sr)@(posedge sclk);
     @(negedge sclk);sv=0;
     waited=0;
     while(!sd && waited<300)begin @(negedge sclk);waited=waited+1;end
     if(!sd || sf!==fail_job[0] || sresult!==expected_result)$fatal(1,"Wrong or missing completion");
     completed=completed+1;
     // Recycle the source immediately on the completion edge; the destination
     // snapshot and last completion statistics must not follow either bus.
     job=~expected;
     #0.01;if(pj!==expected)$fatal(1,"Destination job borrowed recycled source");
     presult=~expected_result;
     #0.01;if(sresult!==expected_result)$fatal(1,"Return borrowed recycled counters");
     @(negedge sclk);
     if(n%3!=0)repeat(10)begin @(negedge sclk);if(sd)$fatal(1,"Duplicate completion");end
    end
    begin:processor_agent
     integer stall,delay_cycles;
     while(!pv)@(negedge pclk);
     stall=n%9;
     repeat(stall)begin
      if(!pv || pj!==expected)$fatal(1,"Offer changed under processor backpressure");
      @(negedge pclk);
     end
     if(pj!==expected)$fatal(1,"Torn descriptor");
     presult=expected_result;pfail=fail_job;pr=1;
     if(instant)begin drained=1;pdone=1;end
     @(posedge pclk);accepted=accepted+1;
     @(negedge pclk);pr=0;pdone=0;
     if(!instant)begin
      delay_cycles=1+n%27;
      repeat(delay_cycles)begin
       if(pv || pj!==expected)$fatal(1,"Repeated offer or source changed before drain");
       @(negedge pclk);
      end
      drained=1;pdone=1;
      @(negedge pclk);pdone=0;pfail='x;
     end
    end
   join
   cases=cases+1;
  end
 endtask
 initial begin
  reset_both;
  for(i=0;i<80;i=i+1)transact(i,i%7==0,i%11==0);
  // An idle completion pulse must not fabricate a new job or scheduler ACK.
  @(negedge pclk);pdone=1;pfail=1;repeat(3)@(negedge pclk);pdone=0;
  repeat(8)@(negedge sclk);if(sd || pv)$fatal(1,"Idle done consumed");
  // Reset while the processor is stalled on an offered descriptor.
  make_job(1000);@(negedge sclk);sv=1;@(negedge sclk);sv=0;
  wait(pv);reset_both;transact(1001,0,0);
  // Reset after admission but before all memory traffic would have drained.
  make_job(2000);@(negedge sclk);sv=1;@(negedge sclk);sv=0;
  wait(pv);@(negedge pclk);pr=1;@(negedge pclk);pr=0;
  repeat(4)@(negedge pclk);reset_both;transact(2001,1,0);
  if(accepted!=82 || completed!=82)$fatal(1,"Scoreboard count mismatch");
  $display("PROCESSING_JOB_SNAPSHOT_PASS cases=%0d accepted=%0d completed=%0d",cases,accepted,completed);$finish;
 end
 initial begin #2000000;$fatal(1,"Watchdog");end
endmodule

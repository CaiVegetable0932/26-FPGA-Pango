`timescale 1ns/1ps
// Purpose: native DDR scoreboard (physical word addresses, no WVALID/RREADY/B).
// Expected byte memory is built from accepted CLIENT requests/data, independently
// of native addresses, so a shared address conversion bug cannot self-validate.
module tb_ddr_native_dma #(parameter BURST_CAP=16);
 localparam N=6, DEPTH=131072;
 reg clk=0; always #4 clk=~clk;
 reg rst_n=0,controller_ready=1;
 reg [N-1:0] req_valid=0,req_write=0,urgent=0,cancel=0,w_valid=0,r_ready='1,done_ready=0;
 wire [N-1:0] req_ready,w_ready,r_valid,r_last,done,cancelled,error;
 reg [N*32-1:0] req_addr=0,req_tag=0;
 reg [N*5-1:0] req_beats=0;
 reg [N*256-1:0] w_data=0;
 reg [N*32-1:0] w_strb=0;
 wire [N*256-1:0] r_data;
 wire [N*32-1:0] done_tag,stats_wait,stats_bus,stats_useful;
 wire [27:0] awaddr,araddr;
 wire [3:0] awlen,arlen,awid,arid;
 wire awvalid,arvalid;
 reg awready=0,arready=0,native_wready=0,native_wlast=0,native_rvalid=0,native_rlast=0;
 reg [3:0] native_wid=0,native_rid=0;
 wire [255:0] native_wdata;
 wire [31:0] native_wstrb;
 reg [255:0] native_rdata=0;
 wire fault;
 // This regression preserves the original transport-only mode; full readback
 // and frame publication are exercised by tb_frame_memory_fabric separately.
 ddr_native_dma #(.MAX_BEATS(BURST_CAP)) dut(.*,.write_verified(),.max_wait_cycles(stats_wait),.bus_bytes(stats_bus),.useful_write_bytes(stats_useful));
 byte unsigned actual[0:DEPTH-1],expected[0:DEPTH-1];
 integer eaddr[0:N-1],elen[0:N-1],ewcount[0:N-1],ercount[0:N-1];
 reg [255:0] ewdata[0:N*16-1]; reg [31:0] ewmask[0:N*16-1];
 reg [N-1:0] ewrite;
 integer wbase=0,wleft=0,wi=0,wowner=0,rbase=0,rleft=0,ri=0;
 integer cycle=0,seed=42,sink_seed=123,initial_seed,test_count=0,native_transactions=0,total_beats=0;
 integer i,b,owner_found,service_grants=0;
 integer last_grant[0:N-1],max_gap[0:N-1],mixed_start_cycle,mixed_start_beats;
 reg pressure=0,mixed=0,inject_bad_id=0;
 reg awstall=0,arstall=0,wstall=0;
 reg [35:0] awheld,arheld; reg [287:0] wheld;

 // Purpose: deterministic random stalls and refresh-sized address pauses. Read
 // returns may have gaps, but may never be backpressured or reordered here.
 always @(negedge clk) begin
  awready=rst_n && wleft==0 && ($random(seed)&7)!=0 && cycle%97>11;
  arready=rst_n && rleft==0 && ($random(seed)&3)!=0 && cycle%97>11;
  native_wready=rst_n && wleft!=0 && ($random(seed)&3)!=0;
  native_wlast=wleft==1;
  native_wid=inject_bad_id ? 4'd3 : 4'd0;
  native_rvalid=rst_n && rleft!=0 && ($random(seed)&3)!=0;
  native_rlast=rleft==1; native_rid=inject_bad_id ? 4'd3 : 4'd0;
  for(b=0;b<32;b=b+1) native_rdata[b*8+:8]=(rbase+ri*32+b<DEPTH) ? actual[rbase+ri*32+b] : 0;
  if(mixed) for(integer c=0;c<N;c=c+1) r_ready[c]=($random(sink_seed)&7)!=0;
 end

 // Purpose: compare every issued native beat and every consumed read byte,
 // assert address stability and ensure no completion precedes transport drain.
 always @(posedge clk) begin
  cycle=cycle+1;
  if(!rst_n) begin wleft=0;rleft=0;wi=0;ri=0;awstall=0;arstall=0;wstall=0; end
  else begin
   if(awstall && {awaddr,awlen,awid}!==awheld) $fatal(1,"AW changed while stalled");
   if(arstall && {araddr,arlen,arid}!==arheld) $fatal(1,"AR changed while stalled");
   if(wstall && {native_wdata,native_wstrb}!==wheld) $fatal(1,"write data changed while stalled");
   awstall=awvalid&&!awready; arstall=arvalid&&!arready;
   wstall=wleft!=0&&!native_wready;
   awheld={awaddr,awlen,awid}; arheld={araddr,arlen,arid}; wheld={native_wdata,native_wstrb};
   for(i=0;i<N;i=i+1) begin
    if(req_valid[i]&&req_ready[i]) begin
     eaddr[i]=req_addr[i*32+:32];elen[i]=req_beats[i*5+:5];ewcount[i]=0;ercount[i]=0;ewrite[i]=req_write[i];
    end
    if(w_valid[i]&&w_ready[i]) begin
     ewdata[i*16+ewcount[i]]=w_data[i*256+:256];ewmask[i*16+ewcount[i]]=w_strb[i*32+:32];
     for(b=0;b<32;b=b+1) if(w_strb[i*32+b]) expected[eaddr[i]+ewcount[i]*32+b]=w_data[i*256+b*8+:8];
     ewcount[i]=ewcount[i]+1;
    end
    if(r_valid[i]&&r_ready[i]) begin
     for(b=0;b<32;b=b+1) if(r_data[i*256+b*8+:8]!==expected[eaddr[i]+ercount[i]*32+b])
      $fatal(1,"read scoreboard client=%0d beat=%0d byte=%0d",i,ercount[i],b);
     if(r_last[i]!=(ercount[i]==elen[i]-1)) $fatal(1,"client read LAST");
     ercount[i]=ercount[i]+1;
    end
    if(done[i]&&!cancelled[i]&&!error[i]) begin
     if(ewrite[i] && wleft!=0 && wowner==i) $fatal(1,"early write completion");
     if(!ewrite[i] && ercount[i]!=elen[i]) $fatal(1,"early read completion");
    end
   end
   if(awvalid&&awready) begin
    if(wleft!=0 || awid!=0 || awlen>15 || awaddr[2:0]!=0) $fatal(1,"invalid native AW");
    wbase=awaddr*4;wleft=awlen+1;wi=0;owner_found=-1;
    for(i=0;i<N;i=i+1) if(ewrite[i] && eaddr[i]==wbase && elen[i]==wleft) owner_found=i;
    if(owner_found<0) $fatal(1,"native AW address/length disagrees with client");
    wowner=owner_found;
    if(ewcount[wowner]!=wleft) $fatal(1,"AW before write reservation");
    if((wbase%4096)+wleft*32>4096) $fatal(1,"native column wrap");
    if(pressure) begin
     if(last_grant[wowner]>=0 && service_grants-last_grant[wowner]>max_gap[wowner])
      max_gap[wowner]=service_grants-last_grant[wowner];
     last_grant[wowner]=service_grants;service_grants=service_grants+1;
    end
    native_transactions=native_transactions+1;
   end
   if(native_wready) begin
    if(native_wdata!==ewdata[wowner*16+wi] || native_wstrb!==ewmask[wowner*16+wi])
     $fatal(1,"native write beat mismatch owner=%0d beat=%0d",wowner,wi);
    for(b=0;b<32;b=b+1) if(native_wstrb[b]) actual[wbase+wi*32+b]=native_wdata[b*8+:8];
    wleft=wleft-1;wi=wi+1;total_beats=total_beats+1;
   end
   if(arvalid&&arready) begin
    if(rleft!=0 || arid!=0 || araddr[2:0]!=0) $fatal(1,"invalid native AR");
    rbase=araddr*4;rleft=arlen+1;ri=0;owner_found=-1;
    for(i=0;i<N;i=i+1) if(!ewrite[i] && eaddr[i]==rbase && elen[i]==rleft) owner_found=i;
    if(owner_found<0) $fatal(1,"native AR address/length disagrees with client");
    if((rbase%4096)+rleft*32>4096) $fatal(1,"native column wrap");
    native_transactions=native_transactions+1;
   end
   if(native_rvalid) begin rleft=rleft-1;ri=ri+1;total_beats=total_beats+1; end
  end
 end

 // Purpose: client driver honors ready/valid and holds completion for ACK checks.
 task automatic request(input integer c,input bit wr,input integer a,input integer n,input integer t);
  begin
   @(negedge clk); req_addr[c*32+:32]=a;req_beats[c*5+:5]=n;req_tag[c*32+:32]=t;req_write[c]=wr;req_valid[c]=1;
   do @(posedge clk); while(!req_ready[c]);
   @(negedge clk);req_valid[c]=0;
  end
 endtask
 task automatic payload(input integer c,input integer n,input integer salt);
  integer x,y;
  begin
   for(x=0;x<n;x=x+1) begin
    @(negedge clk);
    for(y=0;y<32;y=y+1) w_data[c*256+y*8+:8]=(salt+x*37+y*13)&255;
    w_strb[c*32+:32]=mixed ? 32'hffffffff : ((x==0) ? 32'hfffffff8 : (x==n-1 ? 32'h0007ffff : 32'hffffffff));
    w_valid[c]=1;
    do @(posedge clk); while(!w_ready[c]);
    @(negedge clk);w_valid[c]=0;
   end
  end
 endtask
 task automatic completion(input integer c,input bit want_cancel,input bit want_error,input integer t);
  begin
   wait(done[c]); @(negedge clk);
   if(cancelled[c]!==want_cancel || error[c]!==want_error || done_tag[c*32+:32]!=t)
    $fatal(1,"completion flags/tag client %0d cancel=%b error=%b",c,cancelled[c],error[c]);
   repeat(3) @(negedge clk);
   if(!done[c] || req_ready[c]) $fatal(1,"descriptor released before ACK");
   done_ready[c]=1;@(negedge clk);done_ready[c]=0;test_count=test_count+1;
  end
 endtask
 task automatic transfer(input integer c,input bit wr,input integer a,input integer n,input integer t);
  integer legal_n;
  begin legal_n=n>BURST_CAP ? BURST_CAP : n;request(c,wr,a,legal_n,t);if(wr) payload(c,legal_n,t);completion(c,0,0,t);end
 endtask

 initial begin
  if($value$plusargs("seed=%d",initial_seed)) seed=initial_seed;
  for(i=0;i<DEPTH;i=i+1) begin actual[i]=8'h55;expected[i]=8'h55;end
  for(i=0;i<N;i=i+1) begin eaddr[i]=-1;elen[i]=0;last_grant[i]=-1;max_gap[i]=0;end
  repeat(4) @(negedge clk);rst_n=1;
  // Long/short beats, different client addresses, masking and random native gaps.
  for(integer n=1;n<=16;n=n+1) begin
   transfer(n%N,1,4096+n*1024,n,100+n);
   transfer(n%N,0,4096+n*1024,n,200+n);
  end
  // A frozen read consumer must not block another native client.
  r_ready[0]=0;request(0,0,5120,1,300);wait(dut.returned[0]);
  transfer(1,1,32768,16,301);
  if(done[0]) $fatal(1,"slow read consumer released early");
  r_ready[0]=1;completion(0,0,0,300);
  // Queued incomplete writes may be cancelled without issuing any AW.
  request(2,1,36864,BURST_CAP,400);@(negedge clk);cancel[2]=1;
  @(negedge clk);cancel[2]=0;completion(2,1,0,400);
  // Once address VALID is asserted, cancellation still drains the transaction.
  request(3,0,6144,2,401);wait(arvalid);@(negedge clk);cancel[3]=1;
  @(negedge clk);cancel[3]=0;completion(3,1,0,401);
  request(4,1,40960,BURST_CAP,402);payload(4,BURST_CAP,402);wait(dut.state==2);
  @(negedge clk);cancel[4]=1;@(negedge clk);cancel[4]=0;completion(4,1,0,402);
  // Buffered cancelled reads discard remaining responses and free only on ACK.
  r_ready[5]=0;request(5,0,7168,3,403);wait(dut.returned[5]);
  @(negedge clk);cancel[5]=1;@(negedge clk);cancel[5]=0;completion(5,1,0,403);r_ready[5]=1;
  // Reject illegal span, zero/too-long lengths, misalignment.
  request(0,0,4096,0,500);completion(0,0,1,500);
  request(0,0,4096,17,501);completion(0,0,1,501);
  request(0,0,4097,1,502);completion(0,0,1,502);
  request(0,0,4064,2,503);completion(0,0,1,503);
  request(0,0,32'h40000000,1,504);completion(0,0,1,504);
  // Client 5 is the last live RAW reader and must remain serviceable.
  request(5,0,4096,1,505);completion(5,0,0,505);
  // Six concurrent streams, urgent capture/display permanently asserted.
  // Fairness is measured in grants: stalls are finite model assumptions.
  pressure=1;urgent=6'b001011;
  fork
   begin for(integer t=0;t<20;t=t+1) transfer(0,1,65536,16,600+t);end
   begin for(integer t=0;t<20;t=t+1) transfer(1,1,69632,8,700+t);end
   begin for(integer t=0;t<20;t=t+1) transfer(2,1,73728,4,800+t);end
   begin for(integer t=0;t<20;t=t+1) transfer(3,1,77824,16,900+t);end
   begin for(integer t=0;t<20;t=t+1) transfer(4,1,81920,2,1000+t);end
   begin for(integer t=0;t<20;t=t+1) transfer(5,1,86016,1,1100+t);end
  join
  pressure=0;
  for(integer c=0;c<N;c=c+1) begin
   if(max_gap[c]>N*3) $fatal(1,"unbounded starvation client %0d gap %0d",c,max_gap[c]);
   $display("DDR_METRIC client=%0d max_wait_cycles=%0d max_grant_gap=%0d bus_bytes=%0d useful_write_bytes=%0d",c,stats_wait[c*32+:32],max_gap[c],stats_bus[c*32+:32],stats_useful[c*32+:32]);
  end
  // Actual mixed pressure: RAW/S1/result writes plus display/cache/RAW
  // reads, with consumer stalls and refresh pauses. Disjoint destinations keep
  // the scoreboard independent of unproven native cross-channel visibility.
  mixed_start_cycle=cycle;mixed_start_beats=total_beats;mixed=1;
  fork
   begin for(integer t=0;t<30*16/BURST_CAP;t=t+1) transfer(0,1,65536,16,1400+t);end
   begin for(integer t=0;t<30*16/BURST_CAP;t=t+1) transfer(1,1,69632,16,1500+t);end
   begin for(integer t=0;t<30*16/BURST_CAP;t=t+1) transfer(2,1,73728,16,1600+t);end
   begin for(integer t=0;t<30*16/BURST_CAP;t=t+1) transfer(3,0,77824,16,1700+t);end
   begin for(integer t=0;t<30;t=t+1) transfer(4,0,81920,4,1800+t);end
   begin for(integer t=0;t<30*16/BURST_CAP;t=t+1) transfer(5,0,86016,16,1900+t);end
  join
  // Leave mixed pressure away from the negative edge used by the randomized
  // sink driver. Otherwise its last random assignment can overwrite r_ready='1
  // after mixed is cleared and strand the final post-reset read.
  @(posedge clk); #1; mixed=0;r_ready='1;
  $display("DDR_MIXED_METRIC burst_cap=%0d cycles=%0d bus_bytes=%0d",BURST_CAP,cycle-mixed_start_cycle,(total_beats-mixed_start_beats)*32);
  for(integer c=0;c<N;c=c+1)
   $display("DDR_MIXED_CLIENT client=%0d max_wait_cycles=%0d",c,stats_wait[c*32+:32]);
  if(fault) $fatal(1,"unexpected protocol fault");
  // Native ID errors cannot be hidden; reset is joint with the controller model.
  inject_bad_id=1;request(0,0,5120,1,1300);completion(0,0,1,1300);
  if(!fault || req_ready!=0) $fatal(1,"fault did not stop admission");
  @(negedge clk);rst_n=0;inject_bad_id=0;repeat(4) @(negedge clk);rst_n=1;
  transfer(0,0,5120,1,1301);
  $display("DDR_DMA_PASS tests=%0d native_transactions=%0d native_beats=%0d cycles=%0d",test_count,native_transactions,total_beats,cycle);$finish;
 end
 initial begin #2000000;$fatal(1,"DDR_DMA_TIMEOUT");end
endmodule

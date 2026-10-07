// Purpose: standalone old-RTL miter; candidate and golden consume the same
// vectors independently so a slow reference cannot hide candidate throughput.
// Memory has no RREADY and deliberately separates data from transaction done.
`timescale 1ns/1ps
module tb_geometry_window;
 parameter WIDTH=1920,HEIGHT=1080,STRIDE=2048,CACHE_WORDS=256,N=4096,TRACE_ONLY=0;
 reg clk=0;always #4 clk=~clk;
 reg rst_n=0,invalidate=0,run_vectors=0,fast=0,request_allow=1;
 reg [11:0] vx[0:N-1],vy[0:N-1],vfx[0:N-1],vfy[0:N-1];
 reg ven[0:N-1],vmask[0:N-1];reg [27:0] vb[0:N-1];
 integer sent,gsent,received,greceived,cycle,frame,seed,random_seed;
 integer first_accept,last_accept,previous_accept,accepted_gap,max_gap;
 integer reads,reads_start,cycle_start,i,j,phase,compare_index;
 integer trace_x,trace_y,mapped_x,mapped_y;real angle,rot_x,rot_y;
 integer row_reads_start=0,steady_rows=0;
 reg [7:0] got[0:N-1],gold[0:N-1];reg gotmask[0:N-1],goldmask[0:N-1];
 // Purpose: exercise input bubbles independently of golden progress. Once a
 // candidate request is presented, keep VALID asserted until its handshake.
 wire req=run_vectors && sent<N && request_allow;wire grun=run_vectors && gsent<N;
 wire ready,valid,mask,fault;wire [7:0] pixel;reg result_ready=0;
 wire read_req;wire [27:0] read_addr;wire [4:0] read_len;
 reg read_ready=0,read_valid=0,read_done=0;reg [255:0] read_data=0;
 wire [31:0] hits,misses;
 wire [11:0] xx=vx[sent<N?sent:0],yy=vy[sent<N?sent:0];
 wire [11:0] gx=vx[gsent<N?gsent:0],gy=vy[gsent<N?gsent:0];
 geometry_window_sampler #(.WIDTH(WIDTH),.HEIGHT(HEIGHT),.STRIDE(STRIDE),.CACHE_WORDS(CACHE_WORDS)) dut(
  .clk(clk),.rst_n(rst_n),.invalidate(invalidate),.request_valid(req),.request_ready(ready),
  .source_valid(vmask[sent<N?sent:0]),.enhance(ven[sent<N?sent:0]),.base(vb[sent<N?sent:0]),
  .x0(xx),.x1(xx==WIDTH-1?xx:xx+12'd1),.y0(yy),.y1(yy==HEIGHT-1?yy:yy+12'd1),
  .frac_x(vfx[sent<N?sent:0]),.frac_y(vfy[sent<N?sent:0]),
  .result_valid(valid),.result_ready(result_ready),.pixel(pixel),.mask_valid(mask),
  .read_req(read_req),.read_addr(read_addr),.read_len(read_len),.read_ready(read_ready),
  .read_valid(read_valid),.read_done(read_done),.read_data(read_data),.fault(fault),.hits(hits),.misses(misses));
 wire gready,gvalid,gmask,gcache_req,gcache_ready,gcache_valid,gcache_consume;
 wire [27:0] gcache_addr;wire [7:0] gpixel;reg [7:0] gvalue;
 geometry_gray_sampler_golden #(.STRIDE(STRIDE)) golden(
  .clk(clk),.rst_n(rst_n),.start(grun),.ready(gready),.source_valid(vmask[gsent<N?gsent:0]),
  .enhance(ven[gsent<N?gsent:0]),.base(vb[gsent<N?gsent:0]),
  .x0(gx),.x1(gx==WIDTH-1?gx:gx+12'd1),.y0(gy),.y1(gy==HEIGHT-1?gy:gy+12'd1),
  .frac_x(vfx[gsent<N?gsent:0]),.frac_y(vfy[gsent<N?gsent:0]),
  .valid(gvalid),.pixel_ready(1'b1),.pixel(gpixel),.mask_valid(gmask),
  .cache_req(gcache_req),.cache_ready(gcache_ready),.cache_addr(gcache_addr),
  .cache_valid(gcache_valid),.cache_response_ready(gcache_consume),.cache_value(gvalue));
 // Purpose: deterministic address-sensitive RAW includes every intensity and
 // changes at frame invalidation; both DUT and frozen RTL read identical bytes.
 function [7:0] memory_byte(input [27:0] address);
  reg [31:0] mixed;
  begin mixed=(address*32'd73)^(address>>3)^(address>>11)^(frame*32'd91);memory_byte=mixed[7:0];end
 endfunction
 integer gdelay=0;reg gpending=0,gresponse=0;reg [27:0] gheld;
 assign gcache_ready=!gpending && !gresponse;
 assign gcache_valid=gresponse;
 always @(posedge clk)begin
  if(!rst_n)begin gpending<=0;gresponse<=0;end
  else begin
   if(gcache_req && gcache_ready)begin gheld<=gcache_addr;gdelay<=cycle%3;gpending<=1;end
   if(gpending)begin
    if(gdelay==0)begin gvalue<=memory_byte(gheld);gresponse<=1;gpending<=0;end
    else gdelay<=gdelay-1;
   end
   if(gresponse && gcache_consume)gresponse<=0;
  end
 end
 // Purpose: native DDR surrogate reserves one full beat at request acceptance,
 // randomizes grant/latency, emits one beat without readiness, and exercises
 // both coincident and delayed done. Long output stalls overlap returned data.
 integer mstate=0,delay_left=0,done_delay=0;reg [27:0] maddr;
 reg input_waiting=0;integer lookup_handoffs=0,emit_handoffs=0,stalled_windows=0;
 // Purpose: cover the extra elastic read slot, post-fill replay and a reply
 // on the request-grant edge, not only the former single-window handoff.
 reg zero_now=0;integer replays=0,promotions=0,zero_responses=0;
 reg fault_test=0;integer inject=0;
 always @(negedge clk)begin
  if(!rst_n)begin mstate=0;read_ready=0;read_valid=0;read_done=0;request_allow=1;end
  else begin
   read_valid=0;read_done=0;zero_now=0;
   case(mstate)
    1:if(delay_left==0)begin
      for(j=0;j<32;j=j+1)read_data[j*8+:8]=memory_byte(maddr+j);
      read_valid=inject!=1;read_done=(done_delay==0 || inject==1 || inject>=3);
      mstate=read_done?(inject>=3?3:0):2;
     end else delay_left=delay_left-1;
    2:if(done_delay==0)begin read_done=1;mstate=0;end
      else begin
       done_delay=done_delay-1;
       if(inject==2)read_valid=1;
      end
    // A late data beat / second done belongs to NO transaction even while
    // the original response is draining through local byte-extract stages.
    3:begin read_valid=inject==3;read_done=inject==4;mstate=0;end
   endcase
   read_ready=(mstate==0) && (($unsigned($random(random_seed))%4)!=0);
   if(!fault_test && !read_valid && !read_done && read_req && read_ready && reads%7==0)begin
    for(j=0;j<32;j=j+1)read_data[j*8+:8]=memory_byte(read_addr+j);
    read_valid=1;read_done=1;zero_now=1;
   end
   result_ready=fast || (($unsigned($random(random_seed))%4)!=0 && cycle%199<150);
   request_allow=fast || input_waiting || (($unsigned($random(random_seed))%5)!=0);
  end
 end
 reg held_result=0;reg [8:0] held_value;
 reg held_request=0;reg [32:0] held_request_value;
 reg held_window=0;reg [97:0] held_window_value;
 always @(posedge clk)begin
  cycle=cycle+1;
  if(rst_n)begin
   if(read_req && read_ready)begin
    if(mstate!=0 || read_len!=1 || read_addr[4:0]!=0)$fatal(1,"WINDOW_MEMORY_PROTOCOL_FAIL");
    maddr=read_addr;mstate=zero_now?0:1;delay_left=1+$unsigned($random(random_seed))%7;
    if(zero_now)zero_responses=zero_responses+1;
    done_delay=inject==2?3:$unsigned($random(random_seed))%5;reads=reads+1;
   end
   if(!fault_test && fault)$fatal(1,"WINDOW_UNEXPECTED_FAULT cycle=%0d",cycle);
   input_waiting=req && !ready;
   // Purpose: directly assert the cache contract at same-edge handoffs and
   // under backpressure, including invalid-source metadata and raw bytes.
   if(dut.u_window.accept && dut.u_window.fill_write)$fatal(1,"WINDOW_ACCEPT_FILL_COLLISION_FAIL");
   if(dut.u_window.promote)promotions=promotions+1;
   if(dut.u_window.replay)replays=replays+1;
   if(dut.u_window.promote && dut.u_window.a_stale)$fatal(1,"WINDOW_STALE_PROMOTION_FAIL");
   if((dut.u_window.fill_write || dut.u_window.response_bytes_valid) &&
      (dut.u_window.accept || dut.u_window.promote))$fatal(1,"WINDOW_RESPONSE_OVERLAP_FAIL");
   // A miss result can retire before stale A is replayed. Count that actual
   // retirement independently of request acceptance; it is no longer an
   // obligatory same-edge input handoff with this two-slot pipeline.
   if(dut.u_window.state==5 && dut.window_valid && dut.window_ready)emit_handoffs=emit_handoffs+1;
   if(!fault && ready && dut.u_window.state!=0 &&
      !(dut.window_valid && dut.window_ready))$fatal(1,"WINDOW_ACCEPT_WITHOUT_RETIRE_FAIL");
   if(held_window && !fault && (!dut.window_valid ||
      {dut.window_bytes,dut.window_fx,dut.window_fy,dut.window_mask,dut.window_enhance}!==held_window_value))
    $fatal(1,"WINDOW_INTERNAL_STABILITY_FAIL");
   held_window=dut.window_valid && !dut.window_ready;
   held_window_value={dut.window_bytes,dut.window_fx,dut.window_fy,dut.window_mask,dut.window_enhance};
   if(held_window)stalled_windows=stalled_windows+1;
   if(held_result && (!valid || {mask,pixel}!==held_value))$fatal(1,"WINDOW_BACKPRESSURE_FAIL");
   held_result=valid && !result_ready;held_value={mask,pixel};
   // Sticky protocol faults deliberately stop issuing further DDR work.
   if(held_request && !fault && (!read_req || {read_len,read_addr}!==held_request_value))$fatal(1,"WINDOW_REQUEST_STABILITY_FAIL");
   held_request=read_req && !read_ready;held_request_value={read_len,read_addr};
   if(req && ready)begin
    // Purpose: beyond cold-start rows, identity must retain previous source
    // rows and fetch only one new word per 32 pixels. Check transaction counts
    // at cache request boundaries, independent of gray-pipeline drain time.
    if(phase==4 && WIDTH==1920 && STRIDE==2048 && CACHE_WORDS==256 && sent%WIDTH==0)begin
     if(sent>=2*WIDTH)begin
      if(reads-row_reads_start!=WIDTH/32)$fatal(1,"WINDOW_ROW_RETENTION_FAIL row=%0d reads=%0d",sent/WIDTH-1,reads-row_reads_start);
      steady_rows=steady_rows+1;
     end
     row_reads_start=reads;
    end
    if(dut.u_window.state==1)lookup_handoffs=lookup_handoffs+1;
    if(sent==0)first_accept=cycle;
    else begin accepted_gap=cycle-previous_accept;if(accepted_gap>max_gap)max_gap=accepted_gap;end
    previous_accept=cycle;last_accept=cycle;sent<=sent+1;
   end
   if(grun && gready)gsent<=gsent+1;
   if(valid && result_ready)begin
    if(received>=N)$fatal(1,"WINDOW_EXTRA_RESULT_FAIL");
    got[received]=pixel;gotmask[received]=mask;received=received+1;
   end
   if(gvalid)begin gold[greceived]=gpixel;goldmask[greceived]=gmask;greceived=greceived+1;end
  end else begin held_result=0;held_request=0;held_window=0;input_waiting=0;end
 end
 task reset_all;
  begin
   @(negedge clk);rst_n=0;run_vectors=0;invalidate=0;
   repeat(4)@(negedge clk);
   sent=0;gsent=0;received=0;greceived=0;reads=0;max_gap=0;
   rst_n=1;repeat(2)@(negedge clk);
  end
 endtask
 task execute_vectors;
  begin
   sent=0;gsent=0;received=0;greceived=0;max_gap=0;reads_start=reads;cycle_start=cycle;
   @(negedge clk);run_vectors=1;
   wait(received==N);@(negedge clk);
   $display("WINDOW_METRIC width=%0d cache_words=%0d phase=%0d pixels=%0d candidate_cycles=%0d accept_span=%0d max_gap=%0d reads=%0d bytes_per_pixel=%0.3f hits=%0d misses=%0d",WIDTH,CACHE_WORDS,phase,N,cycle-cycle_start,last_accept-first_accept,max_gap,reads-reads_start,32.0*(reads-reads_start)/N,hits,misses);
   if(phase==4 && WIDTH==1920 && STRIDE==2048 && CACHE_WORDS==256 && N%WIDTH==0 && N/WIDTH+HEIGHT/2<HEIGHT-1)
    if(reads-reads_start!=(N/WIDTH+2)*(WIDTH/32))$fatal(1,"WINDOW_IDENTITY_READ_BUDGET_FAIL");
   if(phase==1 && (max_gap!=1 || last_accept-first_accept!=N-1))$fatal(1,"WINDOW_HIT_II1_FAIL");
   if((phase==1 || phase==9) && reads!=reads_start)$fatal(1,"WINDOW_HOT_CACHE_MISS_FAIL");
   if(phase==2 && reads!=reads_start)$fatal(1,"WINDOW_INVALID_SOURCE_READ_FAIL");
   wait(greceived==N);@(negedge clk);run_vectors=0;
   for(compare_index=0;compare_index<N;compare_index=compare_index+1)
    if(got[compare_index]!==gold[compare_index] || gotmask[compare_index]!==goldmask[compare_index])
     $fatal(1,"WINDOW_EQUIVALENCE_FAIL phase=%0d index=%0d xy=%0d,%0d frac=%0d,%0d en=%0d mask=%0d candidate=%0d golden=%0d",phase,compare_index,vx[compare_index],vy[compare_index],vfx[compare_index],vfy[compare_index],ven[compare_index],vmask[compare_index],got[compare_index],gold[compare_index]);
   repeat(4)@(negedge clk);
  end
 endtask
 initial begin
  seed=20261006;if($value$plusargs("SEED=%d",seed))begin end
  random_seed=seed;cycle=0;frame=0;sent=0;gsent=0;received=0;greceived=0;reads=0;
  reset_all;
  // Raster neighborhoods, word crossings, duplicated borders, independent
  // fractions, full-field random access and changing base addresses coexist.
  for(phase=0;phase<9;phase=phase+1)begin
   if(phase!=5 && (!TRACE_ONLY || phase==4 || phase==6 || phase==7 || phase==8))begin
   // Keep generated coordinates identical between cache capacities; elapsed
   // cycles and random memory responses may differ when miss counts change.
   random_seed=seed+phase*104729;
   for(i=0;i<N;i=i+1)begin
    vx[i]=i%WIDTH;vy[i]=(i/WIDTH)%HEIGHT;vb[i]=28'h20000;
    if(i>=N/2)begin vx[i]=$unsigned($random(random_seed))%WIDTH;vy[i]=$unsigned($random(random_seed))%HEIGHT;end
    if(i%17==0)vx[i]=WIDTH-1;if(i%23==0)vy[i]=HEIGHT-1;
    if(i%29==0)vx[i]=0;if(i%31==0)vy[i]=0;
    vfx[i]=$random(random_seed);vfy[i]=$random(random_seed);
    if(i%7==0)vfx[i]=0;if(i%11==0)vfy[i]=4095;
    ven[i]=i%2;vmask[i]=(i%19!=0);
    // Hot windows change row, byte offset, tone enable and fractions every
    // cycle; widths above 32 also cross words. Reusing one constant address
    // would miss same-edge address/data/context skew bugs.
    if(phase==1)begin vx[i]=(30+i%4)<WIDTH?(30+i%4):WIDTH-1;vy[i]=2+i%2;vmask[i]=1;end
    if(phase==2)vmask[i]=0;
    if(phase==3)begin vb[i]=28'h60003+(i%2)*28'h10000;vmask[i]=1;end
    // Purpose: separate spatial locality from fully random stress. Synthetic
    // centered affine traces sample 0/15/45/75 degrees, not a camera FPS claim
    // or an end-to-end calibration/mapper test. The frozen sampler remains the
    // arithmetic oracle for every valid and clipped-out coordinate.
    if(phase>=4)begin
     angle=phase==4?0.0:(phase==6?15.0:(phase==7?45.0:75.0));
     angle=angle*3.141592653589793/180.0;
     trace_x=i%WIDTH;trace_y=(HEIGHT/2+i/WIDTH)%HEIGHT;
     rot_x=$cos(angle)*(trace_x-WIDTH/2)-$sin(angle)*(trace_y-HEIGHT/2)+WIDTH/2;
     rot_y=$sin(angle)*(trace_x-WIDTH/2)+$cos(angle)*(trace_y-HEIGHT/2)+HEIGHT/2;
     mapped_x=$rtoi(rot_x);mapped_y=$rtoi(rot_y);
     vmask[i]=rot_x>=0.0 && rot_y>=0.0 && rot_x<WIDTH && rot_y<HEIGHT;
     vx[i]=vmask[i]?mapped_x:0;vy[i]=vmask[i]?mapped_y:0;
     vfx[i]=vmask[i]?$rtoi((rot_x-mapped_x)*4096.0):0;
     vfy[i]=vmask[i]?$rtoi((rot_y-mapped_y)*4096.0):0;
    end
   end
   fast=(phase==1 || phase>=4);
   if(phase==1)begin
    // Warm the varying footprint sequence before measuring strict hit II=1.
    phase=5;execute_vectors;phase=1;
   end
   execute_vectors;
   if(phase==1)begin
    // Reuse resident windows with randomized input bubbles, long output
    // stalls and alternating valid/invalid sources to pressure handoff state.
    for(i=0;i<N;i=i+1)vmask[i]=(i%7!=0);
    phase=9;fast=0;execute_vectors;phase=1;
   end
   @(negedge clk);invalidate=1;@(negedge clk);invalidate=0;frame=frame+1;
   end
  end
  // Purpose: fault injection verifies transaction ownership and idle-only
  // invalidation. Reset between cases, because errors are intentionally sticky.
  if(lookup_handoffs==0 || emit_handoffs==0 || replays==0 || promotions==0 || zero_responses==0 || (!TRACE_ONLY && stalled_windows==0))$fatal(1,"WINDOW_HANDOFF_COVERAGE_FAIL");
  $display("WINDOW_HANDOFF_COVERAGE lookup=%0d emit_retire=%0d stalled=%0d steady_identity_rows=%0d replay=%0d promote=%0d grant_edge_reply=%0d",lookup_handoffs,emit_handoffs,stalled_windows,steady_rows,replays,promotions,zero_responses);
  fault_test=1;
  for(inject=1;inject<=4;inject=inject+1)begin
   reset_all;run_vectors=1;wait(fault);@(negedge clk);run_vectors=0;
   if(ready)$fatal(1,"WINDOW_FAULT_READY_FAIL");
  end
  inject=0;reset_all;run_vectors=1;wait(read_req);@(negedge clk);invalidate=1;
  @(negedge clk);invalidate=0;run_vectors=0;if(!fault)$fatal(1,"WINDOW_BUSY_INVALIDATE_FAIL");
  // Purpose: a queued A is busy even before B becomes active. Invalidating
  // on that boundary must not silently drop its reserved request/context.
  reset_all;run_vectors=1;wait(sent==1);@(negedge clk);run_vectors=0;invalidate=1;
  @(negedge clk);invalidate=0;if(!fault || ready)$fatal(1,"WINDOW_QUEUED_INVALIDATE_FAIL");
  // Arithmetic may still hold a result after the cache returns idle. Its
  // independent guard must also reject premature frame invalidation.
  reset_all;vmask[0]=0;run_vectors=1;wait(sent==1);@(negedge clk);run_vectors=0;
  wait(dut.u_window.state==0 && dut.pipe_busy);@(negedge clk);invalidate=1;
  @(negedge clk);invalidate=0;if(!fault || ready)$fatal(1,"WINDOW_PIPE_INVALIDATE_FAIL");
  $display("WINDOW_EQUIVALENCE_PASS width=%0d height=%0d stride=%0d cache_words=%0d pixels=%0d seed=%0d",WIDTH,HEIGHT,STRIDE,CACHE_WORDS,N,seed);$finish;
 end
 initial begin #((N/4096+1)*60000000);$fatal(1,"WINDOW_TIMEOUT phase=%0d sent=%0d received=%0d gsent=%0d greceived=%0d cache_state=%0d memory_state=%0d missing=%b seen=%b",phase,sent,received,gsent,greceived,dut.u_window.state,mstate,dut.u_window.missing,dut.u_window.seen);end
endmodule

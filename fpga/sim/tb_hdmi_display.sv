`timescale 1ns/1ps
// Purpose: independent byte-addressed DMA model and pixel/tag scoreboard.
// FULL=1 checks every pixel of true 1080p raster; small mode adds fault cases.
// Models bounded random request/response/done delays, stable backpressure,
// cancellation drain, source-generation changes and recovery without reset.
module tb_hdmi_display;
 parameter FULL=0,NATIVE=0;
 localparam W=(FULL||NATIVE)?1920:64,H=FULL?1080:(NATIVE?16:8),S=(FULL||NATIVE)?6144:256;
 localparam HS=(FULL||NATIVE)?44:4,HB=(FULL||NATIVE)?148:12,HF=(FULL||NATIVE)?88:8;
 localparam VS=FULL?5:2,VB=FULL?36:5,VF=FULL?4:2;
 localparam HT=HS+HB+W+HF,VT=VS+VB+H+VF;
 reg clk=0;always #6.734 clk=~clk;
 reg rst_n=0,enable=1,locked=1,offer_valid=1,release_ready=1;
 reg [31:0] offer_base=32'h01800000,offer_gen=1;
 reg [1:0] offer_slot=0;reg [63:0] offer_epoch=7,offer_id=100;
 wire offer_ready,release_valid,boundary,hs,vs,de,tag_valid;
 wire [1:0] release_slot,ready_lines;wire [31:0] release_gen;
 wire [23:0] rgb;wire [11:0] x,y;
 wire [63:0] epoch,id;wire [31:0] gen,nnew,nrepeat,nfailed,nscan,nempty,uf,ufpixels,gap,low;
 wire req_valid,r_ready,done_ready,cancel,urgent,fault;
 wire [31:0] addr,req_tag;wire [4:0] beats;
 reg req_ready=0,r_valid=0,r_last=0,done=0,cancelled=0,error=0;
 reg [255:0] r_data=0;reg [31:0] done_tag=0;
 reg block_request=0,block_response=0,wrong_tag=0;
 integer model_state=0,remaining=0,beat_no=0,delay_count=0;
 reg [31:0] model_addr=0,model_tag=0,rng=32'hb271ea31;
 reg model_cancelled=0;
 integer cycles=0,checks=0,pixels=0,good_pixels=0,frames=0,line_pixels=0;
 integer accepted=0,released=0,burst_count=0,max_gap=0;
 integer row_start[0:1],tracked_row[0:1],max_line_fill=0;
 integer offer_start=0,max_offer_wait=0,max_ready_to_pixel=0,selected_ready_cycle=0;
 reg previous_offer=0;reg [1:0] previous_ready=0;reg [31:0] previous_pixel_gen=0;
 integer expected_h=0,expected_v=0,j;
 reg held_model=0;reg [31:0] ref_gen=0,ref_base=0;
 reg [1:0] ref_slot=0;reg [63:0] ref_id=0,ref_epoch=0;
 reg was_de=0,was_vs=0;integer prev_tag_x=-1,prev_tag_y=-1;
 reg stalled=0;reg [31:0] stalled_addr,stalled_tag;reg [4:0] stalled_beats;
 wire [1:0] native_req_ready,native_r_valid,native_r_last,native_done,native_cancelled,native_error;
 wire [511:0] native_r_data;wire [63:0] native_done_tag;
 wire [27:0] native_araddr;wire [3:0] native_arlen,native_arid;
 wire native_arvalid,native_fault;wire [63:0] native_wait,native_bus_bytes,native_useful_bytes;
 wire client_req_ready=NATIVE?native_req_ready[0]:req_ready;
 wire client_r_valid=NATIVE?native_r_valid[0]:r_valid;
 wire model_request=NATIVE?native_arvalid:req_valid;
 wire [31:0] model_request_addr=NATIVE?{native_araddr,2'b0}:addr;
 wire [4:0] model_request_beats=NATIVE?({1'b0,native_arlen}+1'b1):beats;
 wire model_response_ready=NATIVE?1'b1:r_ready;
 wire model_done_ready=NATIVE?1'b1:done_ready;
 // Purpose: real DMA integration case with a continuously queued competing
 // 16-beat snapshot read. Native responses cannot be backpressured/cancelled;
 // ddr_native_dma must reserve buffers, arbitrate urgent grants and drain them.
 generate if(NATIVE)begin: mixed_dma
  ddr_native_dma #(.CLIENTS(2)) dma(.clk(clk),.rst_n(rst_n),.controller_ready(1'b1),
   .req_valid({1'b1,req_valid}),.req_ready(native_req_ready),.req_write(2'b00),
   .req_addr({32'h06000000,addr}),.req_beats({5'd16,beats}),.req_tag({32'h12345678,req_tag}),
   .urgent({1'b0,urgent}),.cancel({1'b0,cancel}),.w_valid(2'b00),.w_ready(),.w_data(512'd0),.w_strb(64'd0),
   .r_valid(native_r_valid),.r_ready({1'b1,r_ready}),.r_data(native_r_data),.r_last(native_r_last),
   .done(native_done),.done_ready({1'b1,done_ready}),.cancelled(native_cancelled),.error(native_error),.done_tag(native_done_tag),
   .awaddr(),.awlen(),.awid(),.awvalid(),.awready(1'b1),.native_wdata(),.native_wstrb(),
   .native_wready(1'b0),.native_wid(4'd0),.native_wlast(1'b0),
   .araddr(native_araddr),.arlen(native_arlen),.arid(native_arid),.arvalid(native_arvalid),.arready(req_ready),
   .native_rdata(r_data),.native_rvalid(r_valid),.native_rid(4'd0),.native_rlast(r_last),
   .fault(native_fault),.max_wait_cycles(native_wait),.bus_bytes(native_bus_bytes),.useful_write_bytes(native_useful_bytes));
 end endgenerate
 hdmi_display #(.H_ACTIVE(W),.H_SYNC(HS),.H_BACK(HB),.H_FRONT(HF),
 .V_ACTIVE(H),.V_SYNC(VS),.V_BACK(VB),.V_FRONT(VF),.STRIDE(S)) dut(
 .clk(clk),.rst_n(rst_n),.stream_enable(enable),.locked(locked),
 .offer_valid(offer_valid),.offer_ready(offer_ready),.offer_base(offer_base),.offer_generation(offer_gen),
 .offer_slot(offer_slot),.offer_epoch(offer_epoch),.offer_frame_id(offer_id),
 .release_valid(release_valid),.release_ready(release_ready),.release_slot(release_slot),.release_generation(release_gen),
 .frame_boundary(boundary),.hs(hs),.vs(vs),.de(de),.rgb(rgb),.x(x),.y(y),.tag_valid(tag_valid),
 .epoch(epoch),.source_frame_id(id),.generation(gen),
 .display_new_frames(nnew),.display_repeat_frames(nrepeat),.display_failed_frames(nfailed),
 .display_scan_frames(nscan),.display_empty_frames(nempty),
 .underflow_events(uf),.underflow_pixels(ufpixels),.max_no_service_cycles(gap),.low_water_cycles(low),
 .req_valid(req_valid),.req_ready(client_req_ready),.req_addr(addr),.req_beats(beats),.req_tag(req_tag),
 .r_valid(client_r_valid),.r_ready(r_ready),.r_data(NATIVE?native_r_data[255:0]:r_data),.r_last(NATIVE?native_r_last[0]:r_last),
 .done(NATIVE?native_done[0]:done),.done_ready(done_ready),.cancelled(NATIVE?native_cancelled[0]:cancelled),
 .error(NATIVE?native_error[0]:error),.done_tag(NATIVE?native_done_tag[31:0]:done_tag),
 .cancel(cancel),.urgent(urgent),.ready_lines(ready_lines),.dma_fault(fault));
 task check(input bit ok,input string label_text);
  begin checks++;if(!ok)begin $display("HDMI_DISPLAY_FAIL %s cycle=%0d x=%0d y=%0d rgb=%h gen=%0d ready=%b",label_text,cycles,x,y,rgb,gen,ready_lines);$fatal(1);end end
 endtask
 // Purpose: expected bytes depend on row, position and immutable generation.
 // Padding has a poison value; reading across stride/row boundaries is illegal.
 function automatic [7:0] memory_byte(input [31:0] a,input [31:0] g);
  integer off,row,col,component,px;
  begin
   off=a-ref_base;row=off/S;col=off%S;component=col%3;px=col/3;
   if(col>=W*3) memory_byte=8'he7;
   else case(component)
    0:memory_byte=(px+g*17+row*3)&255;
    1:memory_byte=(px*5+row+g*7)&255;
    2:memory_byte=(px^row^g^8'ha5)&255;
   endcase
  end
 endfunction
 function automatic [23:0] expected_pixel(input integer px,row,input [31:0] g);
  reg [7:0] r,b,gr;
  begin r=(px+g*17+row*3)&255;gr=(px*5+row+g*7)&255;b=(px^row^g^8'ha5)&255;expected_pixel={r,gr,b};end
 endfunction
 // Purpose: one outstanding DMA request. Completion remains asserted until
 // ACK; cancellation drains without returning old bytes to a new generation.
 always @(posedge clk) if(rst_n) begin
  cycles++;
  if(offer_valid && !previous_offer)offer_start=cycles;
  previous_offer=offer_valid;
  rng<={rng[30:0],rng[31]^rng[21]^rng[1]^rng[0]};
  if(stalled) check(req_valid && addr==stalled_addr && beats==stalled_beats && req_tag==stalled_tag,"stalled request stability");
  stalled=req_valid && !client_req_ready;
  if(stalled)begin stalled_addr=addr;stalled_beats=beats;stalled_tag=req_tag;end
  if(release_valid && release_ready)begin
   check(held_model && release_slot==ref_slot && release_gen==ref_gen,"release exact handle");
   check((NATIVE?!native_done[0] && native_req_ready[0]:model_state==0) && !req_valid,"release after DMA ACK fence");
   check(boundary || !enable || !locked,"release legal boundary");held_model=0;released++;
  end
  if(offer_valid && offer_ready)begin
   check(boundary,"acquire at boundary only");check(!held_model,"one display reference");
   held_model=1;ref_gen=offer_gen;ref_base=offer_base;ref_slot=offer_slot;ref_id=offer_id;ref_epoch=offer_epoch;accepted++;
   if(cycles-offer_start>max_offer_wait)max_offer_wait=cycles-offer_start;
   selected_ready_cycle=offer_start;tracked_row[0]=-1;tracked_row[1]=-1;
  end
  // Demand starts at first asserted row-head VALID, so stalled requests are
  // included. Service is complete only when the full-line bank is published.
  if(req_valid && (addr-ref_base)%S==0 && tracked_row[((addr-ref_base)/S)%2]!=(addr-ref_base)/S)begin
   row_start[((addr-ref_base)/S)%2]=cycles;tracked_row[((addr-ref_base)/S)%2]=(addr-ref_base)/S;
  end
  req_ready<=model_state==0 && !block_request && rng[2:0]!=0;
  if(req_valid && client_req_ready)begin
   check(held_model,"DMA requires held reference");
   check(addr[4:0]==0 && beats>0 && beats<=16,"aligned legal burst");
   check((addr&4095)+beats*32<=4096,"physical column split");
   check(addr>=ref_base && addr<ref_base+H*S && (addr-ref_base)%S+beats*32<=W*3,"request effective row only");
   check(req_tag==ref_gen,"DMA generation tag");
  end
  if(model_request && req_ready)begin
   check(model_state==0,"one native request at a time");
   model_addr=model_request_addr;model_tag=NATIVE?ref_gen:req_tag;remaining=model_request_beats;beat_no=0;model_state=1;model_cancelled=0;burst_count++;req_ready<=0;delay_count=rng[5:3];
  end
  if(!NATIVE && cancel && model_state!=0)model_cancelled=1;
  if(model_state==1)begin
   if(r_valid && model_response_ready)begin r_valid<=0;remaining--;beat_no++;delay_count=rng[4:3];end
   if(model_cancelled && !r_valid)begin remaining=0;end
   if(remaining==0 && !r_valid)begin model_state=2;delay_count=2+rng[4:3];end
   else if(!r_valid && !block_response && !model_cancelled)begin
    if(delay_count!=0)delay_count--;
    else begin
     for(j=0;j<32;j++)r_data[j*8+:8]<=memory_byte(model_addr+beat_no*32+j,model_tag);
     r_valid<=1;r_last<=remaining==1;
    end
   end
  end else if(model_state==2)begin
   if(delay_count!=0)delay_count--;
   else begin done<=1;cancelled<=model_cancelled;done_tag<=wrong_tag?model_tag+1:model_tag;model_state=3;end
  end else if(model_state==3 && done && model_done_ready)begin done<=0;cancelled<=0;model_state=0;end
  if(NATIVE)check(!native_fault,"actual DMA native protocol legal");
 end
 // Purpose: independent raster counts and exhaustive payload/identity checks,
 // evaluated after the output register settles; failed pixels must be black.
 always @(posedge clk) if(rst_n)begin
  #2;
  check(hs== (expected_h<HS),"HS exact phase");check(vs==(expected_v<VS),"VS exact phase");
  check(de==(expected_h>=HS+HB && expected_h<HS+HB+W && expected_v>=VS+VB && expected_v<VS+VB+H),"DE exact phase");
  if(de)begin
   check(x==expected_h-HS-HB && y==expected_v-VS-VB,"coordinates align DE");pixels++;line_pixels++;
   if(tag_valid)begin
    check(held_model && gen==ref_gen && epoch==ref_epoch && id==ref_id,"pixel source/generation immutable");
    check(rgb===expected_pixel(x,y,gen),"RGB888 exact pixel incl beat residues");good_pixels++;
    if(gen!=previous_pixel_gen)begin
     if(cycles-selected_ready_cycle>max_ready_to_pixel)max_ready_to_pixel=cycles-selected_ready_cycle;
     previous_pixel_gen=gen;
    end
   end else check(rgb==0,"failed/empty pixel is black");
  end
  if(was_de && !de)begin check(line_pixels==W,"complete active line");line_pixels=0;end
  if(expected_h==HT-1)begin expected_h=0;if(expected_v==VT-1)begin expected_v=0;frames++;end else expected_v++;end else expected_h++;
  was_de=de;was_vs=vs;if(gap>max_gap)max_gap=gap;
  for(j=0;j<2;j++)if(ready_lines[j] && !previous_ready[j] && tracked_row[j]>=0)begin
   if(cycles-row_start[j]>max_line_fill)max_line_fill=cycles-row_start[j];
   if(FULL||NATIVE)check(cycles-row_start[j]<=2474,"line service inside 2477-cycle reuse deadline");
  end
  previous_ready=ready_lines;
 end
 task wait_frame;
  begin @(negedge clk);wait(boundary);@(negedge clk);end
 endtask
 task wait_good(input integer target);
  begin wait(nnew+nrepeat>=target);@(negedge clk);end
 endtask
 integer good_before,failed_before,under_before,acquire_before;
 initial begin
  row_start[0]=0;row_start[1]=0;tracked_row[0]=-1;tracked_row[1]=-1;
  repeat(6)@(negedge clk);rst_n=1;
  wait(accepted==1);@(negedge clk);offer_valid=0;
  wait_good(1);check(nnew==1 && nfailed==0 && uf==0,"first complete frame");
  wait_good(2);check(nrepeat==1 && nfailed==0,"repeat same complete frame");
  // READY midway through a frame must wait for the next field boundary.
  offer_base=32'h02000000;offer_gen=2;offer_slot=1;offer_id=101;offer_valid=1;
  wait(accepted==2);@(negedge clk);offer_valid=0;
  wait(nnew==2);@(negedge clk);check(accepted==2 && released==1,"new frame ordered switch");
  if(!FULL && !NATIVE)begin
   // A delayed release ACK repeats the old ref; the new offer is held stable.
   offer_base=32'h02800000;offer_gen=3;offer_slot=2;offer_id=102;offer_valid=1;release_ready=0;
   good_before=nnew+nrepeat;acquire_before=accepted;wait_good(good_before+1);
   check(accepted==acquire_before && ref_gen==2,"release backpressure holds base");
   release_ready=1;wait(accepted==3);@(negedge clk);offer_valid=0;wait(nnew==3);@(negedge clk);
   // Force a missing full line; no subsequent shifted pixels are permitted.
   failed_before=nfailed;under_before=uf;block_response=1;
   wait(nfailed>failed_before);check(uf==under_before+1 && ufpixels>0,"one underflow event per failed frame");
   block_response=0;good_before=nnew+nrepeat;wait_good(good_before+1);
   // Loss of PLL with a stalled VALID must preserve request until acceptance.
   wait_frame();block_request=1;wait(req_valid);@(negedge clk);locked=0;
   repeat(20)@(negedge clk);check(held_model && req_valid,"hold reference during stalled abort");
   block_request=0;wait(!held_model);check(!done && model_state==0,"loss lock drains before release");
   @(negedge clk);locked=1;offer_valid=1;offer_gen=4;offer_id=103;
   wait(accepted==4);@(negedge clk);offer_valid=0;wait(nnew==4);@(negedge clk);
   // Wrong completion generation invalidates a frame and recovers next field.
   wrong_tag=1;wait(fault);@(negedge clk);wrong_tag=0;
   failed_before=nfailed;wait(nfailed>failed_before);good_before=nnew+nrepeat;wait_good(good_before+1);
   // Disabled output uses drain/release, not a destructive local DMA reset.
   @(negedge clk);enable=0;wait(!held_model);check(released==accepted,"all acquired refs released");
  end
  check(good_pixels>=3*W*H,"three complete RGB frames checked");
  check(nscan==nnew+nrepeat+nfailed+nempty,"all scanned frames accounted");
  if(NATIVE)check(native_bus_bytes[63:32]>0 && uf==0 && nfailed==0,"competing client makes progress without display starvation");
  $display("HDMI_DISPLAY_PASS full=%0d native=%0d frames=%0d pixels=%0d good_pixels=%0d checks=%0d new=%0d repeat=%0d failed=%0d underflow=%0d gap_cycles=%0d bursts=%0d max_line_fill_cycles=%0d offer_wait_cycles=%0d ready_to_first_pixel_cycles=%0d",FULL,NATIVE,frames,pixels,good_pixels,checks,nnew,nrepeat,nfailed,uf,max_gap,burst_count,max_line_fill,max_offer_wait,max_ready_to_pixel);
  $finish;
 end
 initial begin repeat(FULL?12000000:(NATIVE?800000:100000))@(posedge clk);$fatal(1,"HDMI_DISPLAY_TIMEOUT");end
endmodule

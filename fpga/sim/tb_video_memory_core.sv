`timescale 1ns/1fs
// Purpose: real RAW8 -> ISP -> verified SRC -> geometry/refill -> verified DST
// with scheduler/fabric ownership and a native memory model. This synthetic
// small frame checks integration, not physical camera or 1080p30 performance.
// BOARD_MANUAL_PROFILE reproduces the capacity-limited production switches,
// including removal of the separate viewport composer; pose remains active.
// default retains full-feature direct-core regression compatibility.
module tb_video_memory_core #(parameter WIDTH=35,HEIGHT=33,NETWORK_TEST=0,CONTROL_TEST=0,DISPLAY_TEST=0,BOARD_MANUAL_PROFILE=0,EARLY_CAPTURE_TEST=1);
 reg processing_clk=0,processing_rst_n=0;
 initial begin #0.7;forever #3.333333333 processing_clk=~processing_clk;end
 always @(negedge rst_n)processing_rst_n<=0;
 always @(negedge processing_clk)processing_rst_n<=rst_n;

 localparam W=WIDTH,H=HEIGHT;
 reg clk=0,rst_n=0;always #4 clk=~clk;
 reg cv=0,ce=0,legal=1,abort_frame=0,iv=0,rv=0;
 wire cr,cc,ir,rr,offer,fault;wire [31:0] db,dg,good,drop,processed,failed;wire [1:0] ds;
 wire [63:0] de,di;
 reg display_release=0;wire display_release_ready;
 // Optional physical-style display client: keep the old no-scanout fixture
 // available as an isolation comparison, and measure actual CDC/read traffic
 // in the full 1080p mixed-load scenario.
 wire scan_request,scan_offer_ready,scan_release,scan_req,scan_req_ready,scan_cancel,scan_urgent;
 wire scan_rvalid,scan_rready,scan_rlast,scan_done,scan_done_ready,scan_error,scan_cancelled,scan_fault;
 wire [31:0] scan_addr,scan_tag,scan_done_tag,scan_release_gen;
 wire [1:0] scan_release_slot;wire [4:0] scan_beats;wire [255:0] scan_rdata;
 wire scan_confirm;wire [63:0] scan_confirm_epoch,scan_confirm_frame;wire [31:0] scan_confirm_generation;
 wire [31:0] scan_new,scan_repeat,scan_failed,scan_underflow,scan_bad_pixels,scan_checked;
 generate if(DISPLAY_TEST)begin: actual_display
  video_core_display_fixture scanout(.clk(clk),.rst_n(rst_n),.memory_request(scan_request),
   .offer_valid(offer),.offer_ready(scan_offer_ready),.base(db),.generation(dg),.slot(ds),.epoch(de),.frame_id(di),
   .release_valid(scan_release),.release_ready(display_release_ready),.release_slot(scan_release_slot),.release_generation(scan_release_gen),
   .req_valid(scan_req),.req_ready(scan_req_ready),.req_addr(scan_addr),.req_tag(scan_tag),.req_beats(scan_beats),
   .cancel(scan_cancel),.urgent(scan_urgent),.r_valid(scan_rvalid),.r_ready(scan_rready),.r_data(scan_rdata),.r_last(scan_rlast),
   .done(scan_done),.done_ready(scan_done_ready),.error(scan_error),.cancelled(scan_cancelled),.done_tag(scan_done_tag),
   .confirm_valid(scan_confirm),.confirm_epoch(scan_confirm_epoch),.confirm_frame(scan_confirm_frame),.confirm_generation(scan_confirm_generation),
   .new_frames(scan_new),.repeat_frames(scan_repeat),.failed_frames(scan_failed),.underflow_events(scan_underflow),
   .underflow_pixels(scan_bad_pixels),.checked_pixels(scan_checked),.dma_fault(scan_fault));
 end endgenerate
 wire [27:0] awaddr,araddr;wire [3:0] awlen,arlen,awid,arid;
 wire awvalid,arvalid;wire [255:0] wd;wire [31:0] wm;
 wire wr,wl;reg rvalid=0,rlast=0;reg [255:0] rd=0;
 reg [31:0] wa,read_addr;reg [4:0] write_left,read_left;reg write_active=0,read_active=0;
 reg [447:0] coefficients=0;
 reg geometry_valid=0;reg [543:0] geometry_entity=0;reg [31:0] geometry_version=0;wire geometry_ready;wire [767:0] geometry_status;
 reg mode_valid=0;reg [1:0] mode=0;reg [31:0] mode_version=0;wire mode_ready;wire [767:0] status;
 reg affine_submit=0;reg [95:0] affine_request=0;wire [7:0] wire_data;wire wire_enable;
 reg [63:0] fid=1;reg [7:0] pixel=73;reg link=1;
 // Native-width backing words preserve the complete authoritative address space.
 reg [255:0] memory[0:(32'h04c00000>>5)-1];
 function integer location(input [31:0] addr);
  begin location=addr>>5;end
 endfunction
 assign wr=write_active,wl=write_active && write_left==1;
 integer j,checks=0,seed_wait_cycles;
 always @(posedge clk)begin
  rvalid<=0;rlast<=0;
  if(!rst_n)begin write_active<=0;read_active<=0;end
  else begin
   if(awvalid && !write_active)begin wa<={awaddr,2'b0};write_left<={1'b0,awlen}+1'b1;write_active<=1;end
   if(wr)begin
    for(j=0;j<32;j=j+1)if(wm[j])memory[location(wa)][j*8+:8]<=wd[j*8+:8];
    wa<=wa+32;write_left<=write_left-1'b1;
    if(write_left==1)begin write_active<=0;end
   end
   if(arvalid && !read_active)begin read_addr<={araddr,2'b0};read_left<={1'b0,arlen}+1'b1;read_active<=1;end
   if(read_active)begin
    for(j=0;j<32;j=j+1)rd[j*8+:8]<=memory[location(read_addr)][j*8+:8];
    rvalid<=1;rlast<=read_left==1;read_addr<=read_addr+32;read_left<=read_left-1'b1;
    if(read_left==1)read_active<=0;
   end
  end
 end
 // Match the board consumer specialization for the manual profile. This
 // fixture supplies no image uploads; upstream CCM/LUT legality and retry
 // ownership are separately checked by the gateway fixtures. Generic tests
 // retain the default consumer-side checks with BOARD_MANUAL_PROFILE=0.
 video_memory_core #(.WIDTH(W),.HEIGHT(H),.STATIC_ENDPOINTS(0),.SUPPORT_CONTROLS(CONTROL_TEST),.TONE_LUT_PREVALIDATED(BOARD_MANUAL_PROFILE),// Match the current board PC-only control profile in full-frame proof.
 .PC_ONLY_CONTROL(BOARD_MANUAL_PROFILE),.CCM_PREVALIDATED(BOARD_MANUAL_PROFILE),.IMAGE_AUTOMATION(!BOARD_MANUAL_PROFILE),.TONE_UPLOAD(!BOARD_MANUAL_PROFILE),.MCU_CONFIG_DIGEST_ONLY(BOARD_MANUAL_PROFILE),.SUPPORT_VIEWPORT(!BOARD_MANUAL_PROFILE)) dut(.clk(clk),.rst_n(rst_n),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),.controller_ready(1'b1),
  // Synthetic stable camera/ISP commissioning baseline. These explicit
  // inputs exercise normal image statistics without claiming optical timing.
  // Motion/MCU submission is disabled here and covered by dedicated fixtures.
  .camera_config_version(32'd1),.image_auto_stable(1'b1),
  .image_submit_valid(1'b0),.image_kind(16'd0),.image_entity(2048'd0),.image_version(32'd0),.image_id(32'd0),.image_read_kind(16'd1),
  .motion_submit_valid(1'b0),.motion_kind(16'd0),.motion_entity(1024'd0),.motion_version(32'd0),.motion_id(32'd0),.motion_read_kind(16'd11),
  .runtime_action_valid(1'b0),.runtime_action(16'd0),.runtime_action_seq(16'd0),
  .mcu_enable(1'b0),.mcu_rx_valid(1'b0),.mcu_rx_data(8'd0),.mcu_rx_error(1'b0),.mcu_tx_ready(1'b1),
  .mcu_timing_valid(1'b0),.mcu_capture_error(32'd0),.mcu_config_approved(1'b0),.mcu_new_session(32'd0),.mcu_config_ready(1'b0),.mcu_event_ready(1'b1),
  .affine_reference({112'd0,16'd1,32'd1,16'(H),16'(W),coefficients[191:0],64'd0,32'h04000000,32'h04000000}),
  .reference_submit_valid(1'b0),.reference_entity(512'd0),.reference_version(32'd0),.reference_entity_id(32'd0),.reference_submit_code(),.reference_status(),.affine_submit_valid(affine_submit),.affine_sequence(16'd100),.affine_payload(affine_request),
  .affine_submit_code(),.affine_status(),.display_confirm_valid(DISPLAY_TEST?scan_confirm:1'b0),.display_confirm_epoch(scan_confirm_epoch),
  .display_confirm_frame(scan_confirm_frame),.display_confirm_generation(scan_confirm_generation),
  .geometry_coefficients(coefficients),.enhancement(2'd0),.capture_valid(cv),.capture_ready(cr),.capture_complete(cc),
  .geometry_submit_valid(geometry_valid),.geometry_submit_ready(geometry_ready),.geometry_submit(geometry_entity),.geometry_version(geometry_version),.geometry_entity_id(geometry_version),.geometry_status(geometry_status),.mode_submit_valid(mode_valid),.mode_submit_ready(mode_ready),.mode_submit(mode),.mode_version(mode_version),.control_status(status),
  .capture_epoch(64'hf123456789abcdef),.capture_id(fid),.capture_first(64'd100),.capture_last(64'd10000),
  .capture_end(ce),.capture_isp_legal(legal),.capture_raw_legal(legal),.capture_errors(legal?32'd0:32'd1),
  .isp_abort(abort_frame),.raw_abort(abort_frame),.capture_queues_drained(!iv && !rv),
  .isp_byte_valid(iv),.isp_byte_ready(ir),.isp_byte(pixel),.raw_byte_valid(rv),.raw_byte_ready(rr),.raw_byte(pixel),
  .display_request(DISPLAY_TEST?scan_request:1'b1),.display_offer_valid(offer),.display_offer_ready(DISPLAY_TEST?scan_offer_ready:1'b0),.display_base(db),.display_gen(dg),.display_slot(ds),
  .display_epoch(de),.display_id(di),.display_release(DISPLAY_TEST?scan_release:display_release),.display_release_slot(DISPLAY_TEST?scan_release_slot:ds),.display_release_gen(DISPLAY_TEST?scan_release_gen:dg),.display_release_ready(display_release_ready),
  .display_req_valid(DISPLAY_TEST?scan_req:1'b0),.display_req_ready(scan_req_ready),.display_req_addr(DISPLAY_TEST?scan_addr:32'd0),.display_req_tag(DISPLAY_TEST?scan_tag:32'd0),.display_req_beats(DISPLAY_TEST?scan_beats:5'd0),
  .display_cancel(DISPLAY_TEST?scan_cancel:1'b0),.display_urgent(DISPLAY_TEST?scan_urgent:1'b0),.display_r_valid(scan_rvalid),.display_r_ready(DISPLAY_TEST?scan_rready:1'b1),.display_r_data(scan_rdata),.display_r_last(scan_rlast),
  .display_done(scan_done),.display_done_ready(DISPLAY_TEST?scan_done_ready:1'b1),.display_error(scan_error),.display_cancelled(scan_cancelled),.display_done_tag(scan_done_tag),
  .rx_data(8'd0),.rx_dv(1'b0),.rx_er(1'b0),.gigabit_link(link),.network_local_mac(48'h020000000001),.network_peer_mac(48'h020000000002),
  .network_local_ip(32'hc0a85003),.network_peer_ip(32'hc0a85002),.network_local_port(16'd50001),.network_peer_port(16'd50000),.tx_data(wire_data),.tx_en(wire_enable),.tx_er(),.fault(fault),
  .captured_frames(good),.dropped_capture_frames(drop),.processed_frames(processed),.failed_processing_frames(failed),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.awid(awid),.arid(arid),.awvalid(awvalid),.arvalid(arvalid),
  .awready(!write_active),.arready(!read_active),.native_wdata(wd),.native_wstrb(wm),.native_wready(wr),.native_wlast(wl),.native_wid(4'd0),
  .native_rdata(rd),.native_rvalid(rvalid),.native_rlast(rlast),.native_rid(4'd0));
 // Retired PRAW types must never appear on the production GMII image stream.
 reg [7:0] wire_packet[0:1600];integer wire_length=0,wire_index,wire_payload;
 integer raw_vector,raw_vector_bytes=0;reg [31:0] wire_crc;
 function [31:0] ethernet_crc(input [31:0] initial_crc,input [7:0] value);
  reg [31:0] v;integer k;begin v=initial_crc^value;for(k=0;k<8;k=k+1)v=(v>>1)^(v[0]?32'hedb88320:0);ethernet_crc=v;end
 endfunction
 always @(posedge clk)begin
  if(wire_enable)begin if(wire_length>=1600)$fatal(1,"Oversized wire packet");wire_packet[wire_length]=wire_data;wire_length=wire_length+1;end
  else if(wire_length!=0)begin
   if(wire_length>=118 && wire_packet[50]==8'h50 && wire_packet[51]==8'h52 && wire_packet[58]!=1)
    $fatal(1,"Retired image type transmitted");
   // Frame one supplies a compact RAW vector and independent full-byte/FCS check.
   if(wire_length>=118 && wire_packet[50]==8'h50 && wire_packet[51]==8'h52 && wire_packet[70]==1)begin
    wire_crc=32'hffffffff;
    for(wire_index=8;wire_index<wire_length-4;wire_index=wire_index+1)wire_crc=ethernet_crc(wire_crc,wire_packet[wire_index]);
    if({wire_packet[wire_length-1],wire_packet[wire_length-2],wire_packet[wire_length-3],wire_packet[wire_length-4]}!==~wire_crc)$fatal(1,"RAW FCS differs");
    wire_payload=wire_packet[98]+256*wire_packet[99];
    $fwrite(raw_vector,"%c%c",(wire_payload+64)&255,(wire_payload+64)>>8);
    for(wire_index=50;wire_index<114+wire_payload;wire_index=wire_index+1)$fwrite(raw_vector,"%c",wire_packet[wire_index]);
    for(wire_index=0;wire_index<wire_payload;wire_index=wire_index+1)
     if(wire_packet[114+wire_index]!==73)$fatal(1,"RAW payload differs");
    raw_vector_bytes=raw_vector_bytes+wire_payload;
   end
   wire_length=0;
  end
 end
 integer n,x,y,ic,rc,cycles=0,geo_begin=0,geo_cycles=0,geo_max_cycles=0,geo_jobs=0;
 always @(posedge clk)if(rst_n)begin
  cycles=cycles+1;
  if(dut.geo_valid && dut.geo_ready)geo_begin=cycles;
  // Report every completed geometry job, including the job overlapping the
  // next capture/network traffic. A last-frame-only number can hide an earlier
  // slower frame. The physical campaign applies the 125MHz/30fps cycle gate
  // to the maximum of these observations; this remains modeled, not board FPS.
  if(dut.geo_done)begin
   geo_cycles=cycles-geo_begin;geo_jobs=geo_jobs+1;
   if(geo_cycles>geo_max_cycles)geo_max_cycles=geo_cycles;
   $display("FRAME_GEOMETRY job=%0d geometry_cycles=%0d",geo_jobs,geo_cycles);
   // Flush diagnostics after a complete job so long full-frame runs expose
   // the measured deadline before the simulator's stdout buffer fills.
   $fflush();
  end
  // Full mixed-frame diagnostics show real progress under the shared bus;
  // they do not alter RTL stimulus, readiness or deadlines.
  if(WIDTH==1920 && cycles%1250000==0)$display("FULL_PROGRESS cycle=%0d cap=%0d geo=%0d ix=%0d iy=%0d processed=%0d",cycles,dut.scheduler.capture_state,dut.scheduler.geometry_state,dut.ix,dut.iy,processed);
 end
 task next_normal_frame(input [63:0] identity,input [7:0] grey);
  integer ii,ri;
  begin
   fid=identity;pixel=grey;legal=1;abort_frame=0;cv=1;wait(cr);@(negedge clk);cv=0;repeat(3)@(negedge clk);
   fork
    begin iv=1;for(ii=0;ii<W*H;ii=ii+1)begin @(posedge clk);while(!ir)@(posedge clk);@(negedge clk);end iv=0;end
    begin rv=1;for(ri=0;ri<W*H;ri=ri+1)begin @(posedge clk);while(!rr)@(posedge clk);@(negedge clk);end rv=0;end
   join
   ce=1;wait(cc);@(negedge clk);ce=0;
  end
 endtask
 initial begin
  raw_vector=$fopen("raw_datagrams.bin","wb");
  coefficients[0+:32]=65536;coefficients[128+:32]=65536;coefficients[320+:32]=32'h04000000;coefficients[352+:32]=32'h04000000;
  // Keep a source request asserted immediately after reset. Controlled OFF
  // admission must wait for the validated reference seed; the controls-off
  // baseline must not wait on a seed that is intentionally never requested.
  #100;
  if(EARLY_CAPTURE_TEST)begin
   @(negedge clk);rst_n=1;cv=1;seed_wait_cycles=0;#1;
   while(!cr && seed_wait_cycles<64)begin @(negedge clk);seed_wait_cycles=seed_wait_cycles+1;end
   if(!cr)$fatal(1,"initial reference seed failed to release capture");
   if(CONTROL_TEST)begin
    if(!dut.reference_seeded || dut.reference_capture_version!=1 ||
       dut.affine_capture_enable || dut.selected_capture_geometry[191:0]!=coefficients[191:0])
     $fatal(1,"first OFF capture did not use validated seed reference");
   end else if(seed_wait_cycles>1)$fatal(1,"controls-off baseline waited for disabled seed");
  end else begin rst_n=1;repeat(10)@(negedge clk);end
  cv=1;wait(cr);@(negedge clk);cv=0;repeat(3)@(negedge clk);
  // Independent producers obey elastic readiness. Constant Bayer input makes
  // all S1 channels exactly 73, allowing a full destination-byte comparison.
  fork
   begin iv=1;for(ic=0;ic<W*H;ic=ic+1)begin @(posedge clk);while(!ir)@(posedge clk);@(negedge clk);end iv=0;end
   begin rv=1;for(rc=0;rc<W*H;rc=rc+1)begin @(posedge clk);while(!rr)@(posedge clk);@(negedge clk);end rv=0;end
  join
  ce=1;wait(cc);@(negedge clk);ce=0;
  wait(offer);repeat(5)@(negedge clk);
  if(fault || good!=1 || processed!=1 || failed || di!=1 || de!=64'hf123456789abcdef)$fatal(1,"Integration status/identity failed");
  for(y=0;y<H;y=y+1)for(x=0;x<W*3;x=x+1)begin
   if(memory[location(db+y*6144+x)][(x%32)*8+:8]!==73)$fatal(1,"Result differs x=%0d y=%0d value=%0d",x,y,memory[location(db+y*6144+x)][(x%32)*8+:8]);
   checks=checks+1;
  end
  // S1 is observed in simulation only; verified writer memory is the oracle.
  for(y=0;y<H;y=y+1)for(x=0;x<W*3;x=x+1)
   if(memory[location(y*6144+x)][(x%32)*8+:8]!==73)$fatal(1,"S1 memory differs");
  wait(dut.network.raw.complete_frames==1);wait(!dut.network_active);repeat(4)@(negedge clk);
  if(raw_vector_bytes!=W*H)$fatal(1,"Last DMA client RAW byte coverage differs");
  $fclose(raw_vector);
  // Truncated following capture must cancel/drain; it cannot publish a second
  // SRC/DST frame or deadlock on a slot already invalidated by write cancel.
  // Queue ON after the first completed OFF frame. The following admitted
  // capture commits it; that intentionally bad frame still cannot publish.
  if(CONTROL_TEST)begin
   affine_request={32'd1,32'd1,32'd1};affine_submit=1;
   @(negedge clk);affine_submit=0;
  end
  fid=2;cv=1;wait(cr);@(negedge clk);cv=0;repeat(5)@(negedge clk);
  legal=0;abort_frame=1;ce=1;wait(cc);@(negedge clk);ce=0;abort_frame=0;repeat(40)@(negedge clk);
  if(fault || good!=1 || processed!=1)$fatal(1,"Bad frame was published or faulted");
  if(NETWORK_TEST)begin
   wait(dut.network.raw.complete_frames==1);
   next_normal_frame(3,81);wait(dut.network_active);wait(dut.reader.state==3);
   @(negedge clk);link=0;wait(!dut.network_active);repeat(20)@(negedge clk);
   if(fault || dut.network.raw.failed_frames!=1)$fatal(1,"Network cancel did not drain/release");
   link=1;next_normal_frame(4,91);wait(dut.network.raw.complete_frames==2);wait(!dut.network_active);
   if(fault || dut.network_active || dut.reader.failed)$fatal(1,"Network did not recover after link loss");
  end
  if(CONTROL_TEST)begin
   mode=1;mode_version=2;wait(mode_ready);@(negedge clk);mode_valid=1;@(negedge clk);mode_valid=0;
   geometry_entity={32'h04000000,64'd0,coefficients};geometry_entity[0+:32]=32768;geometry_version=2;
   wait(geometry_ready);geometry_valid=1;@(negedge clk);geometry_valid=0;
   next_normal_frame(3,81);wait(dut.geo_valid && dut.geo_ready);@(posedge clk);
   wait(dut.processor.pv && dut.processor.pr);@(posedge processing_clk);@(negedge processing_clk);@(negedge clk);
   if(dut.processor.processor.geometry.coefficients[0+:32]!=32768 || dut.processor_meta.geometry_version!=2)$fatal(1,"Old source geometry entity was not retained a00=%0d version=%0d",dut.processor.processor.geometry.coefficients[0+:32],dut.processor_meta.geometry_version);
   geometry_entity={32'h04000000,64'd0,coefficients};geometry_version=3;
   wait(geometry_ready);geometry_valid=1;@(negedge clk);geometry_valid=0;
   // Independent gamma: round(255 * (81 / 255)^0.7) = 114.
   // Change the pending mode while the older job runs. Its immutable SRC
   // descriptor must retain pre-resample mode 1 until every result retires.
   mode=0;mode_version=3;wait(mode_ready);mode_valid=1;@(negedge clk);mode_valid=0;
   next_normal_frame(4,91);wait(processed==3);repeat(20)@(negedge clk);
   for(y=0;y<H;y=y+1)for(x=0;x<W*3;x=x+1)begin
    if(memory[location(32'h02000000+y*6144+x)][(x%32)*8+:8]!==114)$fatal(1,"Old pre changed x=%0d y=%0d actual=%0d",x,y,memory[location(32'h02000000+y*6144+x)][(x%32)*8+:8]);
    if(memory[location(32'h02800000+y*6144+x)][(x%32)*8+:8]!==91)$fatal(1,"New frame's disabled mode failed");
   end
   if(geometry_status[576+:32]!=3 || dut.processor.processor.geometry.coefficients[0+:32]!=65536)$fatal(1,"New source geometry entity was not applied");
   if(status[320+:32]!=3 || status[256+:64]!=4 || status[384+:64]!=4 || status[528+:32]!=0 || status[632+:8]!=0)
    $fatal(1,"Applied/source statistics identity differs");
  end
  if(DISPLAY_TEST)begin
   // Wait for all distinct produced frames to scan out; repeating old output
   // cannot satisfy this check. The blank startup interval is allowed.
   wait(scan_new>=(CONTROL_TEST?3:1));repeat(10)@(negedge clk);
   if(scan_fault || scan_failed!=0 || scan_underflow!=0 || scan_bad_pixels!=0 || scan_checked<W*H*(CONTROL_TEST?3:1))
    $fatal(1,"DISPLAY_CORE failed/underflow scanout new=%0d failed=%0d underflow=%0d",scan_new,scan_failed,scan_underflow);
   if(CONTROL_TEST)begin
    wait(dut.affine_status[35] && dut.affine_status[576+:64]==4);
    if(dut.affine_status[640+:32]!=1 || dut.affine_status[672+:32]!=3 || !dut.affine_status[736])
     $fatal(1,"Displayed descriptor control/geometry version differs");
   end
   $display("DISPLAY_CORE_PASS new=%0d repeat=%0d checked_pixels=%0d failed=%0d underflow=%0d",scan_new,scan_repeat,scan_checked,scan_failed,scan_underflow);
  end
  $display("GEOMETRY_BUDGET jobs=%0d max_cycles=%0d clock_hz=125000000 minimum_fps=30",geo_jobs,geo_max_cycles);
  $display("TB_VIDEO_MEMORY_CORE_PASS bytes=%0d good=%0d processed=%0d geometry_cycles=%0d",checks,good,processed,geo_cycles);$finish;
 end
 initial begin #300000000;$fatal(1,"Core timeout cap=%0d geo=%0d fault=%b ix=%0d iy=%0d processed=%0d",dut.scheduler.capture_state,dut.scheduler.geometry_state,fault,dut.ix,dut.iy,processed);end
endmodule

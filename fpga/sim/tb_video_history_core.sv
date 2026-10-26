`timescale 1ns/1fs
// Purpose: real RAW8 -> ISP -> verified SRC -> geometry/refill -> verified DST
// with scheduler/fabric ownership and a native memory model. This synthetic
// small frame checks integration, not physical camera or 1080p30 performance.
module tb_video_history_core;
 localparam WIDTH=64,HEIGHT=36,DISPLAY_TEST=0,CONTROL_TEST=1;
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
 reg motion_submit=0;reg [15:0] motion_kind=4;reg [1023:0] motion_entity=0;
 reg [31:0] motion_version=1,motion_id=1;wire [7:0] motion_code;
 reg image_submit=0,submit_colour_on_admit=0;reg [31:0] image_version=2,expected_colour_version=1;reg [2047:0] image_entity=0;wire [7:0] image_code;
 reg [7:0] isp_pixel=0,raw_pixel=0;reg [511:0] reference=0;
 integer accepted_jobs=0,historical_jobs=0,history_dma_requests=0;
 reg [31:0] last_history_base,last_current_base,last_result_base;
 reg [63:0] last_job_id;reg last_history_eligible;reg [31:0] last_history_pixels;
 reg affine_submit=0;reg [95:0] affine_request=0;wire [7:0] wire_data;wire wire_enable;
 reg [63:0] fid=1;reg [7:0] pixel=73;reg link=1;
 // Native-width backing words preserve the complete authoritative address space.
 reg [255:0] memory[0:(32'h03c00000>>5)-1];
 function integer location(input [31:0] addr);
  begin location=addr>>5;end
 endfunction
 assign wr=write_active,wl=write_active && write_left==1;
 integer j,checks=0;
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
 video_memory_core #(.WIDTH(W),.HEIGHT(H),.STATIC_ENDPOINTS(0),.SUPPORT_CONTROLS(CONTROL_TEST)) dut(.clk(clk),.rst_n(rst_n),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),.controller_ready(1'b1),
  .affine_reference(reference),
  .reference_submit_valid(1'b0),.reference_entity(512'd0),.reference_version(32'd0),.reference_entity_id(32'd0),.reference_submit_code(),.reference_status(),.affine_submit_valid(affine_submit),.affine_sequence(16'd100),.affine_payload(affine_request),
  .affine_submit_code(),.affine_status(),.display_confirm_valid(DISPLAY_TEST?scan_confirm:1'b0),.display_confirm_epoch(scan_confirm_epoch),
  .display_confirm_frame(scan_confirm_frame),.display_confirm_generation(scan_confirm_generation),
  .motion_submit_valid(motion_submit),.motion_kind(motion_kind),.motion_entity(motion_entity),.motion_version(motion_version),.motion_id(motion_id),.motion_submit_code(motion_code),.motion_read_kind(16'd11),.motion_status(),
  .image_submit_valid(image_submit),.image_kind(16'd3),.image_entity(image_entity),.image_version(image_version),.image_id(image_version),.image_submit_code(image_code),.image_read_kind(16'd3),.image_status(),
  .camera_config_version(32'd1),.image_auto_stable(1'b0),.mcu_enable(1'b0),.mcu_rx_valid(1'b0),.mcu_rx_data(8'd0),.mcu_rx_error(1'b0),.mcu_tx_ready(1'b1),.mcu_timing_valid(1'b0),.mcu_capture_error(32'd0),.mcu_config_approved(1'b0),
  .geometry_coefficients(coefficients),.enhancement(2'd0),.capture_valid(cv),.capture_ready(cr),.capture_complete(cc),
  .geometry_submit_valid(geometry_valid),.geometry_submit_ready(geometry_ready),.geometry_submit(geometry_entity),.geometry_version(geometry_version),.geometry_entity_id(geometry_version),.geometry_status(geometry_status),.mode_submit_valid(mode_valid),.mode_submit_ready(mode_ready),.mode_submit(mode),.mode_version(mode_version),.control_status(status),
  .capture_epoch(64'hf123456789abcdef),.capture_id(fid),.capture_first(64'd100),.capture_last(64'd10000),
  .capture_end(ce),.capture_isp_legal(legal),.capture_raw_legal(legal),.capture_errors(legal?32'd0:32'd1),
  .isp_abort(abort_frame),.raw_abort(abort_frame),.capture_queues_drained(!iv && !rv),
  .isp_byte_valid(iv),.isp_byte_ready(ir),.isp_byte(isp_pixel),.raw_byte_valid(rv),.raw_byte_ready(rr),.raw_byte(raw_pixel),
  .display_request(DISPLAY_TEST?scan_request:1'b1),.display_offer_valid(offer),.display_offer_ready(1'b1),.display_base(db),.display_gen(dg),.display_slot(ds),
  .display_epoch(de),.display_id(di),.display_release(offer),.display_release_slot(DISPLAY_TEST?scan_release_slot:ds),.display_release_gen(DISPLAY_TEST?scan_release_gen:dg),.display_release_ready(display_release_ready),
  .display_req_valid(DISPLAY_TEST?scan_req:1'b0),.display_req_ready(scan_req_ready),.display_req_addr(DISPLAY_TEST?scan_addr:32'd0),.display_req_tag(DISPLAY_TEST?scan_tag:32'd0),.display_req_beats(DISPLAY_TEST?scan_beats:5'd0),
  .display_cancel(DISPLAY_TEST?scan_cancel:1'b0),.display_urgent(DISPLAY_TEST?scan_urgent:1'b0),.display_r_valid(scan_rvalid),.display_r_ready(DISPLAY_TEST?scan_rready:1'b1),.display_r_data(scan_rdata),.display_r_last(scan_rlast),
  .display_done(scan_done),.display_done_ready(DISPLAY_TEST?scan_done_ready:1'b1),.display_error(scan_error),.display_cancelled(scan_cancelled),.display_done_tag(scan_done_tag),
  .rx_data(8'd0),.rx_dv(1'b0),.rx_er(1'b0),.gigabit_link(link),.network_local_mac(48'h020000000001),.network_peer_mac(48'h020000000002),
  .network_local_ip(32'hc0a85003),.network_peer_ip(32'hc0a85002),.network_local_port(16'd50001),.network_peer_port(16'd50000),.tx_data(wire_data),.tx_en(wire_enable),.tx_er(),.fault(fault),
  .captured_frames(good),.dropped_capture_frames(drop),.processed_frames(processed),.failed_processing_frames(failed),
  .awaddr(awaddr),.araddr(araddr),.awlen(awlen),.arlen(arlen),.awid(awid),.arid(arid),.awvalid(awvalid),.arvalid(arvalid),
  .awready(!write_active),.arready(!read_active),.native_wdata(wd),.native_wstrb(wm),.native_wready(wr),.native_wlast(wl),.native_wid(4'd0),
  .native_rdata(rd),.native_rvalid(rvalid),.native_rlast(rlast),.native_rid(4'd0));

 // Observe real frame-job admission and physical fabric requests independently
 // of the completion eligibility decision. No outputs are forced in this test.
 always @(posedge clk)if(rst_n)begin
  if(dut.geo_valid && dut.geo_ready)begin
   accepted_jobs=accepted_jobs+1;last_job_id=dut.processor_meta.frame_id;last_history_eligible=dut.history_eligible;
   last_history_base=dut.history_base;last_current_base=dut.geo_src_base;last_result_base=dut.geo_dst_base;
   if(dut.history_eligible)historical_jobs=historical_jobs+1;
  end
  if(dut.req_valid[2] && dut.req_ready[2] && dut.source_history)history_dma_requests=history_dma_requests+1;
  if(dut.geo_done)last_history_pixels=dut.history_pixel_count;
 end
 function [7:0] stored_byte(input [31:0] address);
  begin stored_byte=memory[location(address)][(address%32)*8+:8];end
 endfunction
 function [7:0] texture(input integer x,y,shift);
  integer xx;begin xx=x-shift;texture=(xx*37+y*73+xx*y*13)&255;end
 endfunction
 task submit_motion;
  begin @(negedge clk);#1;if(motion_code!=0)$fatal(1,"motion submit rejected kind=%0d code=%0d",motion_kind,motion_code);
   motion_submit=1;@(negedge clk);motion_submit=0;end
 endtask
 task frame(input integer identity,shift);
  integer ii,ri;
  begin
   @(negedge clk);fid=identity;legal=1;abort_frame=0;cv=1;wait(cr);image_submit=submit_colour_on_admit;@(negedge clk);cv=0;image_submit=0;repeat(3)@(negedge clk);
   if(dut.admitted_colour_version!=expected_colour_version)
    $fatal(1,"admission colour race frame%0d",identity);
   fork
    begin for(ii=0;ii<W*H;ii=ii+1)begin isp_pixel=texture(ii%W,ii/W,shift);iv=1;@(posedge clk);while(!ir)@(posedge clk);@(negedge clk);end iv=0;end
    begin for(ri=0;ri<W*H;ri=ri+1)begin raw_pixel=texture(ri%W,ri/W,shift);rv=1;@(posedge clk);while(!rr)@(posedge clk);@(negedge clk);end rv=0;end
   join
   ce=1;wait(cc);@(negedge clk);ce=0;
   wait(last_job_id==identity);wait(dut.scheduler.geometry_state==0);wait(!dut.network_active);repeat(10)@(negedge clk);
   if(identity>1 && !dut.affine_enabled)$fatal(1,"fixture C3 never applied ON");
   if(fault || failed!=0)$fatal(1,"history core main path failed");
   $display("HISTORY_CORE_FRAME id=%0d eligible=%0d history_pixels=%0d dma=%0d held=%0d status=%0d dx=%0d conf=%0d",identity,last_history_eligible,last_history_pixels,history_dma_requests,dut.scheduler.history_held,dut.motion_visual_state,$signed(dut.motion_job_dx),dut.motion_job_confidence);
  end
 endtask
 initial begin
  coefficients=0;coefficients[0+:32]=2097152;coefficients[128+:32]=2097152;
  coefficients[64+:32]=-61865984;coefficients[160+:32]=-36700160;
  coefficients[320+:32]=32*65536;coefficients[352+:32]=32*65536;
  coefficients[384+:32]=63*32768;coefficients[416+:32]=35*32768;
  reference=0;reference[0+:32]=32*65536;reference[32+:32]=32*65536;
  reference[64+:32]=63*32768;reference[96+:32]=35*32768;
  reference[128+:192]=coefficients[191:0];reference[192+:32]=-66060288;
  reference[320+:16]=W;reference[336+:16]=H;reference[352+:32]=1;reference[384+:16]=1;
  #100;rst_n=1;wait(dut.tone_initialized);wait(dut.geometry_seeded);wait(dut.reference_seeded);repeat(5)@(negedge clk);
  // Old C4 and registration-dependent C5 must NAK, never ACK a zero motion.
  motion_entity=0;motion_entity[0]=1;#1;if(motion_code!=6)$fatal(1,"C4 accepted");
  @(negedge clk);motion_submit=1;@(negedge clk);motion_submit=0;frame(1,0);
  // C3 must actually be ON before testing the shifted current-source border.
  // The first real source commits boot geometry/reference before this A6.
  @(negedge clk);affine_request={32'd1,32'd1,32'd1};#1;
  if(dut.affine_submit_code!=0)$fatal(1,"fixture A6 rejected code=%0d geometry=%0d pending=%0d",dut.affine_submit_code,dut.active_geometry_version,dut.affine_pending);
  affine_submit=1;@(negedge clk);affine_submit=0;

  motion_kind=6;motion_entity=0;motion_entity[0]=1;#1;if(motion_code!=6)$fatal(1,"C5 enabled accepted");
  @(negedge clk);motion_submit=1;@(negedge clk);motion_submit=0;
  // Disabled C5 entity remains usable and reports unavailable registration.
  motion_entity=0;motion_entity[15:8]=1;submit_motion;frame(2,0);frame(3,4);
  if(last_history_eligible || last_history_pixels || history_dma_requests || dut.history_registration_ok || dut.motion_job_confidence || dut.motion_visual_state!=8)
   $fatal(1,"unregistered history/visual status after withdrawal");
  // Independent native-memory oracle: outside current S1 stays invalid/black;
  // in-domain pixels still come from current S1, never the prior frame.
  for(integer channel=0;channel<3;channel=channel+1)begin
   if(stored_byte(last_result_base+10*6144+62*3+channel)!==0)$fatal(1,"unregistered outside pixel value=%0d a00=%0d a02=%0d enabled=%0d matrix=%h",stored_byte(last_result_base+10*6144+62*3+channel),dut.motion_geometry[31:0],$signed(dut.motion_geometry[95:64]),dut.affine_enabled,dut.motion_geometry);
   if(stored_byte(last_result_base+10*6144+10*3+channel)!==stored_byte(last_current_base+10*6144+12*3+channel))
    $fatal(1,"current pixel priority differs from current S1 byte");
  end
  // Same pixels but a new ISP version invalidate old-S1 radiometric pairing.
  image_entity=0;image_entity[32+:64]=64'h1000100010001000;
  image_entity[128+:32]=16384;image_entity[256+:32]=16384;image_entity[384+:32]=16384;
  @(negedge clk);#1;if(image_code!=0)$fatal(1,"colour entity rejected");image_submit=1;@(negedge clk);image_submit=0;
  expected_colour_version=2;frame(4,4);if(last_history_eligible || last_history_pixels!=0)$fatal(1,"colour change reused old history");
  // A truncated capture never becomes history and cannot leak a pending claim.
  fid=5;cv=1;wait(cr);@(negedge clk);cv=0;repeat(5)@(negedge clk);
  legal=0;abort_frame=1;ce=1;wait(cc);@(negedge clk);ce=0;abort_frame=0;repeat(20)@(negedge clk);
  frame(6,4);if(last_history_eligible)$fatal(1,"bad capture gap reused history");
  // Same-edge ISP submission/admission must leave frame7 on version2. The
  // later source_start cannot sample the new pending version3 from a live bus.
  // Frame8 then applies version3 and must invalidate the prior history.
  image_version=3;submit_colour_on_admit=1;frame(7,4);submit_colour_on_admit=0;
  if(dut.processor_meta.isp_version!=2)$fatal(1,"same-edge submission changed admitted metadata");
  expected_colour_version=3;frame(8,4);
  if(dut.processor_meta.isp_version!=3 || dut.motion_visual_state!=8 || last_history_eligible)
   $fatal(1,"new colour version or disabled status mismatch");
  motion_version=2;motion_id=2;motion_entity[7:0]=0;submit_motion;frame(9,4);
  repeat(40)@(negedge clk);
  if(dut.scheduler.history_held || dut.scheduler.src_occupied!=0)$fatal(1,"SRC history references leaked");
  $display("VIDEO_HISTORY_CORE_PASS source_frames=%0d jobs=%0d history_jobs=%0d history_dma=%0d",good,accepted_jobs,historical_jobs,history_dma_requests);$finish;
 end
 initial begin #300000000;$fatal(1,"history core timeout state=%0d processed=%0d",dut.scheduler.geometry_state,processed);end
endmodule




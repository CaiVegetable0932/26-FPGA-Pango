// Purpose: real RAW8 frame store with independent HDMI and Ethernet consumers.
// mem_clk is the native 125 MHz HMIC core clock; network uses that SAME domain.
// All cross-clock pixels/records traverse native FIFOs; controls are held levels.
module raw8_dual_core #(parameter WARMUP_FRAMES=10)(
 input wire mem_clk,mem_reset_n,cam_clk,cam_reset_n,pixel_clk,pixel_reset_n,
 input wire configured,vsync,href,input wire [7:0] camera_data,
 input wire commissioned,network_enable,input wire [63:0] epoch,
 input wire [47:0] src_mac,dst_mac,input wire [31:0] src_ip,dst_ip,
 input wire [15:0] src_port,dst_port,
 output wire [27:0] awaddr,araddr,output wire [3:0] awlen,arlen,arid,
 output wire awvalid,arvalid,input wire awready,arready,wready,wlast,
 input wire [3:0] wid,rid,input wire rvalid,rlast,input wire [255:0] rdata,
 output wire [255:0] wdata,output wire [31:0] wstrb,
 output wire [23:0] rgb,output wire hs,vs,de,
 output wire [7:0] gmii_data,output wire gmii_en,gmii_error,
 output wire fault,output wire [31:0] published,underflows,
 output wire [7:0] fault_detail,output wire [95:0] writer_snapshot,
 output wire [287:0] chain_diagnostics
);
 wire [287:0] rec_in,rec_out;wire rec_valid,rec_ready,rec_out_valid,rec_out_ready;
 reg lease_valid;wire lease_ack;
 // Purpose: latch epoch when reserving a slot, BEFORE its DVP frame begins.
 // Commissioning while a START record is crossing must not relabel an older
 // physical frame. A pre-commissioning lease stays epoch zero until released.
 reg [63:0] capture_lease_epoch;
 wire [31:0] capture_rejected,capture_overflows;
 wire [7:0] capture_debug,writer_debug;
 // Purpose: independent DVP evidence survives rejected frames and FIFO stalls.
 raw8_dvp_monitor u_dvp_monitor(.cam_clk(cam_clk),.cam_reset_n(cam_reset_n),
  .mem_clk(mem_clk),.mem_reset_n(mem_reset_n),.vsync(vsync),.href(href),
  .capture_state(capture_debug),.rejected(capture_rejected),.overflows(capture_overflows),
  .geometry(chain_diagnostics[95:0]),.progress(chain_diagnostics[191:96]));
 // Purpose: the ISP RAW candidate may emit exactly 1080 rows, while the prior
 // sensor RAW tap emitted 1086. Accept only those two complete geometries;
 // publish the first 1080 and keep the six-row crop explicitly provisional.
 raw8_capture_records #(.WARMUP_FRAMES(WARMUP_FRAMES),
  .SENSOR_EXTRA_ROWS(6)) u_records(.cam_clk(cam_clk),.cam_reset_n(cam_reset_n),
  .configured(configured),.lease_valid(lease_valid),.vsync(vsync),.href(href),.data(camera_data),
  .lease_ack(lease_ack),.record_data(rec_in),.record_valid(rec_valid),.record_ready(rec_ready),
  .rejected(capture_rejected),.overflows(capture_overflows),.debug_state(capture_debug));
 raw8_native_queue #(.WIDTH(288)) u_capture_queue(.wr_clk(cam_clk),.wr_reset_n(cam_reset_n),
  .in_data(rec_in),.in_valid(rec_valid),.in_ready(rec_ready),.wr_used(),
  .rd_clk(mem_clk),.rd_reset_n(mem_reset_n),.out_data(rec_out),
  .out_valid(rec_out_valid),.out_ready(rec_out_ready));
 wire commit,write_good,write_fault,arb_fault,pool_fault;
 wire [2:0] write_fault_code;
 wire [63:0] captured_id,captured_epoch;
 wire [27:0] capture_base,f_addr;wire [1:0] capture_slot;
 wire f_req,f_ready,f_valid,f_done;
 raw8_write_engine u_writer(.clk(mem_clk),.rst_n(mem_reset_n),.slot_base(capture_base),
  .epoch(capture_lease_epoch),.record_data(rec_out),.record_valid(rec_out_valid),
  .record_ready(rec_out_ready),.commit(commit),.good(write_good),
  .captured_id(captured_id),.captured_epoch(captured_epoch),
  .awaddr(awaddr),.awlen(awlen),.awvalid(awvalid),.awready(awready),
  .wready(wready),.wlast(wlast),.wid(wid),.wdata(wdata),.wstrb(wstrb),
  .fence_req(f_req),.fence_addr(f_addr),.fence_ready(f_ready),.fence_valid(f_valid),
  .fence_done(f_done),.rdata(rdata),.fault(write_fault),.fault_code(write_fault_code),
  .fault_snapshot(writer_snapshot),.debug_state(writer_debug));
 reg c_req,h_req,h_release,n_req,n_release;
 wire c_grant,h_grant,n_grant,h_locked,n_locked;
 wire [1:0] h_slot,n_slot;wire [63:0] h_id,h_epoch,n_id,n_epoch;
 raw8_frame_pool u_pool(.clk(mem_clk),.reset_n(mem_reset_n),
  .capture_request(c_req),.capture_grant(c_grant),.capture_slot(capture_slot),.capture_base(capture_base),
  .capture_commit(commit),.capture_good(write_good && !arb_fault && !write_fault),
  .capture_drained(commit),.captured_id(captured_id),.captured_epoch(captured_epoch),
  .hdmi_request(h_req),.hdmi_release(h_release),.hdmi_grant(h_grant),.hdmi_locked(h_locked),
  .hdmi_slot(h_slot),.hdmi_id(h_id),.hdmi_epoch(h_epoch),
  .net_request(n_req),.net_release(n_release),.net_grant(n_grant),.net_locked(n_locked),
  .net_slot(n_slot),.net_id(n_id),.net_epoch(n_epoch),
  .published(published),.dropped(),.protocol_error(pool_fault));
 (* syn_preserve=1 *) reg lease_meta,lease_sync;
 reg [1:0] cstate;
 // Purpose: exactly one preallocated slot per admitted camera frame. The
 // write engine's ordered END and fence are the sole commit/drained authority.
 always @(posedge mem_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin lease_meta<=0;lease_sync<=0;lease_valid<=0;capture_lease_epoch<=0;c_req<=0;cstate<=0;end
  else begin
   lease_meta<=lease_ack;lease_sync<=lease_meta;c_req<=0;
   case(cstate)
    0:if(!write_fault && !arb_fault && !pool_fault && !lease_sync)begin c_req<=1;cstate<=1;end
    // Keep requesting while all three slots are occupied. A single pulse can
    // be refused by the pool and would otherwise stop capture permanently.
    1:if(c_grant)begin
     lease_valid<=1;capture_lease_epoch<=commissioned?epoch:64'b0;cstate<=2;
    end else c_req<=1;
    2:if(lease_sync)begin lease_valid<=0;cstate<=3;end
    3:if(commit)cstate<=0;
   endcase
  end
 wire h_dma_req,n_dma_req,h_dma_ready,n_dma_ready,h_dma_valid,n_dma_valid;
 wire h_burst_done,n_burst_done,h_dma_done,n_dma_done;
 wire [27:0] h_addr,n_addr;wire [4:0] h_len,n_len;
 reg h_start,n_start;
 wire [9:0] h_used,n_used;wire h_queue_ready,n_queue_ready;
 raw8_read_scheduler u_h_dma(.clk(mem_clk),.reset_n(mem_reset_n),.start(h_start),
  .base(28'h3000000+({26'b0,h_slot}<<22)),.idle(),.request(h_dma_req),
  .burst_ready(h_dma_ready),.burst_done(h_burst_done),.address(h_addr),.length(h_len),.done(h_dma_done));
 raw8_read_scheduler u_n_dma(.clk(mem_clk),.reset_n(mem_reset_n),.start(n_start),
  .base(28'h3000000+({26'b0,n_slot}<<22)),.idle(),.request(n_dma_req),
  .burst_ready(n_dma_ready),.burst_done(n_burst_done),.address(n_addr),.length(n_len),.done(n_dma_done));
 // Purpose: 32-word safety margin exceeds the largest native 16-beat response
 // and accounts for local FIFO flag latency. No RVALID beat may be discarded.
 raw8_read_arbiter u_reads(.clk(mem_clk),.rst_n(mem_reset_n),
  .h_req(h_dma_req),.h_addr(h_addr),.h_len(h_len),.h_space(h_used<=480),
  .h_ready(h_dma_ready),.h_valid(h_dma_valid),.h_done(h_burst_done),
  .n_req(n_dma_req),.n_addr(n_addr),.n_len(n_len),.n_space(n_used<=480),
  .n_ready(n_dma_ready),.n_valid(n_dma_valid),.n_done(n_burst_done),
  .f_req(f_req),.f_addr(f_addr),.f_ready(f_ready),.f_valid(f_valid),.f_done(f_done),
  .araddr(araddr),.arlen(arlen),.arid(arid),.arvalid(arvalid),.arready(arready),
  .rvalid(rvalid),.rlast(rlast),.rid(rid),.fault(arb_fault));
 wire [255:0] h_word,n_word;wire h_word_valid,h_word_ready,n_word_valid,n_word_ready;
 raw8_native_queue u_h_queue(.wr_clk(mem_clk),.wr_reset_n(mem_reset_n),
  .in_data(rdata),.in_valid(h_dma_valid),.in_ready(h_queue_ready),.wr_used(h_used),
  .rd_clk(pixel_clk),.rd_reset_n(pixel_reset_n),.out_data(h_word),
  .out_valid(h_word_valid),.out_ready(h_word_ready));
 raw8_native_queue u_n_queue(.wr_clk(mem_clk),.wr_reset_n(mem_reset_n),
  .in_data(rdata),.in_valid(n_dma_valid),.in_ready(n_queue_ready),.wr_used(n_used),
  .rd_clk(mem_clk),.rd_reset_n(mem_reset_n),.out_data(n_word),
  .out_valid(n_word_valid),.out_ready(n_word_ready));
 wire pixel_req,pixel_release;reg pixel_ack,pixel_release_ack;
 raw8_hdmi_consumer u_display(.clk(pixel_clk),.rst_n(pixel_reset_n),
  .frame_ack(pixel_ack),.release_ack(pixel_release_ack),.frame_req(pixel_req),.release_req(pixel_release),
  .word_data(h_word),.word_valid(h_word_valid),.word_ready(h_word_ready),
  .hs(hs),.vs(vs),.de(de),.rgb(rgb),.underflows(underflows));
 (* syn_preserve=1 *) reg hreq_meta,hreq_sync,hrel_meta,hrel_sync;
 reg [2:0] hstate;reg h_finished;
 always @(posedge mem_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin hreq_meta<=0;hreq_sync<=0;hrel_meta<=0;hrel_sync<=0;
   hstate<=0;h_finished<=0;h_req<=0;h_release<=0;h_start<=0;pixel_ack<=0;pixel_release_ack<=0;end
  else begin
   hreq_meta<=pixel_req;hreq_sync<=hreq_meta;hrel_meta<=pixel_release;hrel_sync<=hrel_meta;
   h_release<=0;h_start<=0;
   if(h_dma_done)h_finished<=1;
   case(hstate)
    0:if(hreq_sync)begin h_req<=1;hstate<=1;end
    1:if(h_grant)begin h_req<=0;pixel_ack<=1;h_start<=1;h_finished<=0;hstate<=2;end
    2:if(!hreq_sync)begin pixel_ack<=0;hstate<=3;end
    3:if(hrel_sync && h_finished)begin h_release<=1;pixel_release_ack<=1;hstate<=4;end
    4:if(!hrel_sync)begin pixel_release_ack<=0;hstate<=0;end
   endcase
  end
 wire net_ready,net_done,net_error,net_idle,mac_busy;
 reg net_drain,net_fault,n_finished,n_frame_done,n_seen;
 reg [2:0] nstate;reg [63:0] last_id,last_epoch;
 reg [31:0] last_publication,requested_publication;
 // Purpose: publish an explicitly versioned, FPGA-enhanced Bayer RAW8 stream.
 // DDR still retains the original sensor bytes; Ethernet applies the same
 // display enhancement as HDMI, so this payload is not unprocessed S0.
 raw8_network_output #(.ENHANCE(1)) u_network(.clk(mem_clk),.reset_n(mem_reset_n),
  // Finish an admitted frame even if link permission drops on the start edge.
  // New admission still requires network_enable; errors drain the locked slot.
  .enable((network_enable || nstate==2) && !net_fault),.frame_start(n_start),.discard(net_drain),
  .frame_ready(net_ready),.source_idle(net_idle),.stream_epoch(n_epoch),.frame_id(n_id),
  .descriptor_id(32'h484e4552),.param_version(32'd2),
  .word_data(n_word),.word_valid(n_word_valid),.word_ready(n_word_ready),
  .src_mac(src_mac),.dst_mac(dst_mac),.src_ip(src_ip),.dst_ip(dst_ip),.src_port(src_port),.dst_port(dst_port),
  .gmii_txd(gmii_data),.gmii_tx_en(gmii_en),.gmii_tx_er(gmii_error),
  .frame_done(net_done),.frame_error(net_error),.error_code(),.mac_busy(mac_busy));
 // Purpose: transmit each captured identity at most once; pre-commissioning
 // epoch-zero HDMI frames are never relabeled as newly commissioned RAW data.
 always @(posedge mem_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin nstate<=0;n_req<=0;n_release<=0;n_start<=0;net_drain<=0;net_fault<=0;
   n_finished<=0;n_frame_done<=0;n_seen<=0;last_id<=0;last_epoch<=0;last_publication<=0;requested_publication<=0;end
  else begin
   n_release<=0;n_start<=0;
   if(n_dma_done)n_finished<=1;
   if(net_done)n_frame_done<=1;
   if(net_error)begin net_fault<=1;net_drain<=1;end
   case(nstate)
    0:if(network_enable && !net_fault && net_ready && published!=last_publication)begin
     n_req<=1;requested_publication<=published;nstate<=1;
    end
    1:if(n_grant)begin
     n_req<=0;last_publication<=requested_publication;
     if(n_epoch==epoch && commissioned && network_enable &&
        (!n_seen || n_id!=last_id || n_epoch!=last_epoch))begin
      n_start<=1;n_finished<=0;n_frame_done<=0;n_seen<=1;last_id<=n_id;last_epoch<=n_epoch;nstate<=2;
     end else begin n_release<=1;nstate<=0;end
    end
    2:if(n_finished && net_idle && !mac_busy && (n_frame_done || net_drain))begin
     n_release<=1;net_drain<=0;nstate<=0;
    end
   endcase
  end
 reg overflow_fault;
 always @(posedge mem_clk or negedge mem_reset_n)
  if(!mem_reset_n)overflow_fault<=0;
  else if((h_dma_valid && !h_queue_ready)||(n_dma_valid && !n_queue_ready))overflow_fault<=1;
 assign fault=write_fault || arb_fault || pool_fault || net_fault || overflow_fault;
 // Purpose: independent sticky source bits plus writer's first-error reason.
 // This is memory-domain telemetry only; it never masks a stop condition.
 assign fault_detail={write_fault_code,overflow_fault,net_fault,pool_fault,arb_fault,write_fault};
 // Purpose: actual accepted records and native W beats, not requested traffic.
 // These counters and FSM fields all live in mem_clk; no per-bit CDC here.
 reg [15:0] debug_starts,debug_ends,debug_writes;reg [31:0] debug_words;
 always @(posedge mem_clk or negedge mem_reset_n)
  if(!mem_reset_n)begin debug_starts<=0;debug_ends<=0;debug_words<=0;debug_writes<=0;end
  else begin
   if(rec_out_valid && rec_out_ready)case(rec_out[287:286])
    1:debug_starts<=debug_starts+1'b1;
    2:debug_ends<=debug_ends+1'b1;
    0:debug_words<=debug_words+1'b1;
   endcase
   if(wready && (writer_debug[6:4]==2 || (writer_debug[6:4]==1 && awready)))
    debug_writes<=debug_writes+1'b1;
  end
 assign chain_diagnostics[287:192]={writer_debug,cstate,hstate,rec_out_valid,rec_out_ready,commit,
                                   debug_writes,debug_words,debug_ends,debug_starts};
endmodule

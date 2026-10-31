`timescale 1ns/1ps
// Frame-atomic affine/projective two-clock subsystem; the mailbox snapshots the complete job in
// processing_clk before exposing valid. DDR-side descriptors are borrowed and
// MUST remain immutable until job_done, including metadata and LUT version.
// LUT programming ports belong to processing_clk; a DDR pulse is not legal.
// All native traffic drains before the mailbox releases scheduler ownership.
// No PLL/reset integration or CDC timing signoff is implied by this adapter.
module geometry_processing_domain_external_refill #(parameter META_BITS=616,EXTERNAL_TONE_PAGES=0,HISTORY_SUPPORT=0,
 // S1G bypasses LUT programming but keeps the job's original tone metadata.
 // Gray specialization changes only the processing cache/interpolator.
 parameter SOURCE_PRE_ENHANCED=0,GRAYSCALE=0,PROJECTIVE=0,COEFF_BITS=PROJECTIVE?544:448)(
 input clk,rst_n,processing_clk,processing_rst_n,input job_valid,output job_ready,
 input [31:0] source_base,source_generation,result_base,result_generation,
 input [15:0] width,height,input [COEFF_BITS-1:0] coefficients,input [META_BITS-1:0] metadata,
 input [1:0] enhancement,input [31:0] lut_version,
 input history_enable,input [31:0] history_base,history_generation,input signed [31:0] history_dx_q16,history_dy_q16,
 output source_history,output [31:0] current_pixels,history_pixels,invalid_pixels,
 input lut_write,input [7:0] lut_addr,lut_data,input lut_commit,input lut_page,input [31:0] lut_program_version,
 output job_done,job_failed,output [META_BITS-1:0] result_metadata,
 output source_req_valid,input source_req_ready,output [31:0] source_req_addr,source_req_tag,
 output [4:0] source_req_beats,output source_cancel,
 input source_r_valid,output source_r_ready,input [255:0] source_r_data,input source_r_last,
 input source_done,output source_done_ready,input source_error,source_cancelled,input [31:0] source_done_tag,
 output result_req_valid,input result_req_ready,output [31:0] result_req_addr,result_req_tag,
 output [4:0] result_req_beats,output result_cancel,
 output result_w_valid,input result_w_ready,output [255:0] result_w_data,output [31:0] result_w_strb,
 input result_done,output result_done_ready,input result_error,result_cancelled,input [31:0] result_done_tag
);
 // Quads cross once per tile; all row addresses/checks stay with DDR.
 wire freq,fready,fv,fr,fl,fe,fbusy,mreq,mready,mv,mr,ml,me;
 wire [11:0] ftx,fty,mtx,mty;wire [95:0] frgb,mrgb;wire [31:0] fbytes,mbytes;
 localparam JOB_BITS=META_BITS+707+(COEFF_BITS-448);
 wire phe,fill_domain;wire signed [31:0] phdx,phdy;
 wire pv,pr,pdone,pfail;wire [JOB_BITS-1:0] pjob;
 wire [31:0] psb,psg,prb,prg,plv;wire [15:0] pw,ph;
 wire [COEFF_BITS-1:0] pc;wire [1:0] pe;wire [META_BITS-1:0] pm;
 wire [31:0] processing_current_pixels,processing_history_pixels,processing_invalid_pixels;
 wire sreq,sready,scancel,srv,srr,srl,sd,sdr,se,sx;
 wire [31:0] sa,st,sdt;wire [4:0] sn;wire [255:0] sdata;
 wire rreq,rready,rcancel,rwv,rwr,rd,rdr,re,rx;
 wire [31:0] ra,rt,rdt;wire [4:0] rn;wire [255:0] rdata;wire [31:0] rstrb;
 // Readiness and LUT-version comparisons see only the mailbox destination
 // snapshot. Slot-addressed DDR LUTRAM reads cannot reach processing enables.
 assign {phe,phdx,phdy,psb,psg,prb,prg,pw,ph,pc,pm,pe,plv}=pjob;
 assign result_metadata=metadata;
 processing_job_cdc #(.JOB_BITS(JOB_BITS),.RESULT_BITS(96)) job_mailbox(
  .source_clk(clk),.source_rst_n(rst_n),.source_valid(job_valid),.source_ready(job_ready),
  .source_job({HISTORY_SUPPORT && history_enable,history_dx_q16,history_dy_q16,source_base,source_generation,result_base,result_generation,width,height,coefficients,metadata,enhancement,lut_version}),
  .source_done(job_done),.source_failed(job_failed),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),
  .processing_valid(pv),.processing_ready(pr),.processing_job(pjob),.processing_done(pdone),.processing_failed(pfail),
  // Geometry holds final counters until the next job; the synchronized done
  // captures all three atomically before DDR observers receive job_done.
  .processing_result({processing_current_pixels,processing_history_pixels,processing_invalid_pixels}),
  .source_result({current_pixels,history_pixels,invalid_pixels}));
 geometry_frame_processor_external_refill #(.META_BITS(META_BITS),.EXTERNAL_TONE_PAGES(EXTERNAL_TONE_PAGES),.HISTORY_SUPPORT(HISTORY_SUPPORT),.PROGRAM_VERSION_SEPARATE(1),.SOURCE_PRE_ENHANCED(SOURCE_PRE_ENHANCED),.GRAYSCALE(GRAYSCALE),.PROJECTIVE(PROJECTIVE)) processor(
  .clk(processing_clk),.rst_n(processing_rst_n),.job_valid(pv),.job_ready(pr),
  .source_base(psb),.source_generation(psg),.result_base(prb),.result_generation(prg),
  .width(pw),.height(ph),.coefficients(pc),.metadata(pm),.enhancement(pe),.lut_version(plv),
  .history_enable(phe),.history_dx_q16(phdx),.history_dy_q16(phdy),.fill_history(fill_domain),
  .current_pixels(processing_current_pixels),.history_pixels(processing_history_pixels),.invalid_pixels(processing_invalid_pixels),
  // Programming controls/version are held on processing_clk, independently
  // of job admission. Legacy callers use lut_version for both roles, while
  // board EXTERNAL_TONE_PAGES mode supplies its separate programming version.
  .lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),.lut_commit(lut_commit),.lut_page(lut_page),.lut_program_version(EXTERNAL_TONE_PAGES?lut_program_version:lut_version),
  .job_done(pdone),.job_failed(pfail),.result_metadata(),
  .fill_req_valid(freq),.fill_req_ready(fready),.fill_tile_x(ftx),.fill_tile_y(fty),
  .fill_valid(fv),.fill_ready(fr),.fill_rgb(frgb),.fill_last(fl),.fill_error(fe),.fill_bus_bytes(fbytes),.refill_busy(fbusy),
  .result_req_valid(rreq),.result_req_ready(rready),.result_req_addr(ra),.result_req_tag(rt),.result_req_beats(rn),.result_cancel(rcancel),
  .result_w_valid(rwv),.result_w_ready(rwr),.result_w_data(rdata),.result_w_strb(rstrb),
  .result_done(rd),.result_done_ready(rdr),.result_error(re),.result_cancelled(rx),.result_done_tag(rdt),
  .cache_misses(),.cache_stalls(),.cache_bus_bytes());
 // Keep RGB888 interfaces but remove duplicated gray bytes inside the CDC FIFO.
 tile_refill_cdc #(.HISTORY_SUPPORT(HISTORY_SUPPORT),.GRAYSCALE(GRAYSCALE)) refill_bridge(
  .processing_clk(processing_clk),.processing_rst_n(processing_rst_n),
  .fill_req_valid(freq),.fill_req_ready(fready),.fill_tile_x(ftx),.fill_tile_y(fty),
  .fill_history(fill_domain),.memory_history(source_history),
  .fill_valid(fv),.fill_ready(fr),.fill_rgb(frgb),.fill_last(fl),.fill_error(fe),.fill_bus_bytes(fbytes),.busy(fbusy),
  .memory_clk(clk),.memory_rst_n(rst_n),.memory_req_valid(mreq),.memory_req_ready(mready),.memory_tile_x(mtx),.memory_tile_y(mty),
  .memory_fill_valid(mv),.memory_fill_ready(mr),.memory_fill_rgb(mrgb),.memory_fill_last(ml),.memory_fill_error(me),.memory_fill_bus_bytes(mbytes));
 geometry_tile_refill memory_refill(.clk(clk),.rst_n(rst_n),.fill_req_valid(mreq),.fill_req_ready(mready),
  .fill_tile_x(mtx),.fill_tile_y(mty),.source_base(source_history?history_base:source_base),.source_stride(32'd6144),.source_generation(source_history?history_generation:source_generation),
  .source_width(width),.source_height(height),.fill_valid(mv),.fill_ready(mr),.fill_rgb(mrgb),.fill_last(ml),.fill_error(me),.fill_bus_bytes(mbytes),
  .cancel(1'b0),.req_valid(source_req_valid),.req_ready(source_req_ready),.req_addr(source_req_addr),.req_tag(source_req_tag),
  .req_beats(source_req_beats),.req_write(),.dma_cancel(source_cancel),.r_valid(source_r_valid),.r_ready(source_r_ready),
  .r_data(source_r_data),.r_last(source_r_last),.done(source_done),.done_ready(source_done_ready),
  .dma_error(source_error),.dma_cancelled(source_cancelled),.done_tag(source_done_tag),.busy());
 dma_write_cdc result_bridge(
  .client_clk(processing_clk),.client_rst_n(processing_rst_n),.req_valid(rreq),.req_ready(rready),.req_addr(ra),.req_tag(rt),.req_beats(rn),.cancel(rcancel),
  .w_valid(rwv),.w_ready(rwr),.w_data(rdata),.w_strb(rstrb),.done(rd),.done_ready(rdr),.error(re),.cancelled(rx),.done_tag(rdt),
  .memory_clk(clk),.memory_rst_n(rst_n),.memory_req_valid(result_req_valid),.memory_req_ready(result_req_ready),
  .memory_req_addr(result_req_addr),.memory_req_tag(result_req_tag),.memory_req_beats(result_req_beats),.memory_cancel(result_cancel),
  .memory_w_valid(result_w_valid),.memory_w_ready(result_w_ready),.memory_w_data(result_w_data),.memory_w_strb(result_w_strb),
  .memory_done(result_done),.memory_done_ready(result_done_ready),.memory_error(result_error),.memory_cancelled(result_cancelled),.memory_done_tag(result_done_tag));
endmodule

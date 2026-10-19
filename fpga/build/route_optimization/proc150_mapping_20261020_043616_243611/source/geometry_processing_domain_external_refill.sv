`timescale 1ns/1ps
// Unintegrated two-clock subsystem. DDR-side descriptors are borrowed and
// MUST remain immutable until job_done, including metadata and LUT version.
// LUT programming ports belong to processing_clk; a DDR pulse is not legal.
// All native traffic drains before the mailbox releases scheduler ownership.
// No PLL/reset integration or CDC timing signoff is implied by this adapter.
module geometry_processing_domain_external_refill #(parameter META_BITS=616,PROJECTIVE=1)(
 input clk,rst_n,processing_clk,processing_rst_n,input job_valid,output job_ready,
 input [31:0] source_base,source_generation,result_base,result_generation,
 input [15:0] width,height,input [447:0] coefficients,input [META_BITS-1:0] metadata,
 input [1:0] enhancement,input [31:0] lut_version,input [95:0] projective,
 input lut_write,input [7:0] lut_addr,lut_data,input lut_commit,
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
 localparam JOB_BITS=META_BITS+738;
 wire pv,pr,pdone,pfail;wire [JOB_BITS-1:0] pjob;
 wire [31:0] psb,psg,prb,prg,plv;wire [15:0] pw,ph;
 wire [447:0] pc;wire [95:0] pp;wire [1:0] pe;wire [META_BITS-1:0] pm;
 wire sreq,sready,scancel,srv,srr,srl,sd,sdr,se,sx;
 wire [31:0] sa,st,sdt;wire [4:0] sn;wire [255:0] sdata;
 wire rreq,rready,rcancel,rwv,rwr,rd,rdr,re,rx;
 wire [31:0] ra,rt,rdt;wire [4:0] rn;wire [255:0] rdata;wire [31:0] rstrb;
 // The processor's existing frame admission registers are the bundled-data
 // capture endpoints, avoiding an additional full-width mailbox shadow.
 assign {psb,psg,prb,prg,pw,ph,pc,pm,pe,plv,pp}=pjob;
 assign result_metadata=metadata;
 processing_job_cdc #(.JOB_BITS(JOB_BITS)) job_mailbox(
  .source_clk(clk),.source_rst_n(rst_n),.source_valid(job_valid),.source_ready(job_ready),
  .source_job({source_base,source_generation,result_base,result_generation,width,height,coefficients,metadata,enhancement,lut_version,projective}),
  .source_done(job_done),.source_failed(job_failed),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),
  .processing_valid(pv),.processing_ready(pr),.processing_job(pjob),.processing_done(pdone),.processing_failed(pfail));
 geometry_frame_processor_external_refill #(.META_BITS(META_BITS),.PROJECTIVE(PROJECTIVE)) processor(
  .clk(processing_clk),.rst_n(processing_rst_n),.job_valid(pv),.job_ready(pr),
  .source_base(psb),.source_generation(psg),.result_base(prb),.result_generation(prg),
  .width(pw),.height(ph),.coefficients(pc),.metadata(pm),.enhancement(pe),.lut_version(plv),.projective(pp),
  .lut_write(lut_write),.lut_addr(lut_addr),.lut_data(lut_data),.lut_commit(lut_commit),
  .job_done(pdone),.job_failed(pfail),.result_metadata(),
  .fill_req_valid(freq),.fill_req_ready(fready),.fill_tile_x(ftx),.fill_tile_y(fty),
  .fill_valid(fv),.fill_ready(fr),.fill_rgb(frgb),.fill_last(fl),.fill_error(fe),.fill_bus_bytes(fbytes),.refill_busy(fbusy),
  .result_req_valid(rreq),.result_req_ready(rready),.result_req_addr(ra),.result_req_tag(rt),.result_req_beats(rn),.result_cancel(rcancel),
  .result_w_valid(rwv),.result_w_ready(rwr),.result_w_data(rdata),.result_w_strb(rstrb),
  .result_done(rd),.result_done_ready(rdr),.result_error(re),.result_cancelled(rx),.result_done_tag(rdt),
  .cache_misses(),.cache_stalls(),.cache_bus_bytes());
 tile_refill_cdc refill_bridge(
  .processing_clk(processing_clk),.processing_rst_n(processing_rst_n),
  .fill_req_valid(freq),.fill_req_ready(fready),.fill_tile_x(ftx),.fill_tile_y(fty),
  .fill_valid(fv),.fill_ready(fr),.fill_rgb(frgb),.fill_last(fl),.fill_error(fe),.fill_bus_bytes(fbytes),.busy(fbusy),
  .memory_clk(clk),.memory_rst_n(rst_n),.memory_req_valid(mreq),.memory_req_ready(mready),.memory_tile_x(mtx),.memory_tile_y(mty),
  .memory_fill_valid(mv),.memory_fill_ready(mr),.memory_fill_rgb(mrgb),.memory_fill_last(ml),.memory_fill_error(me),.memory_fill_bus_bytes(mbytes));
 geometry_tile_refill memory_refill(.clk(clk),.rst_n(rst_n),.fill_req_valid(mreq),.fill_req_ready(mready),
  .fill_tile_x(mtx),.fill_tile_y(mty),.source_base(source_base),.source_stride(32'd6144),.source_generation(source_generation),
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

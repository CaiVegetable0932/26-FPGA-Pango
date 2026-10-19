"""Prepare the next CDC round at the complete tile/quad interface, not per row."""
from pathlib import Path
import hashlib,json

def once(text,old,new):
    if text.count(old)!=1:raise ValueError('Unexpected source anchor: '+old)
    return text.replace(old,new)

def external_processor(text):
    text=once(text,'module geometry_frame_processor #(','module geometry_frame_processor_external_refill #(')
    start=text.index(' output source_req_valid,');end=text.index(' output result_req_valid,',start)
    text=text[:start]+''' // Cache-fill stream belongs to processing_clk; native row DMA is external.
 output fill_req_valid,input fill_req_ready,output [11:0] fill_tile_x,fill_tile_y,
 input fill_valid,output fill_ready,input [95:0] fill_rgb,input fill_last,fill_error,
 input [31:0] fill_bus_bytes,input refill_busy,
'''+text[end:]
    text=once(text,' wire fill_req_valid,fill_req_ready,fill_valid,fill_ready,fill_last,fill_error,refill_busy;\n wire [11:0] fill_tile_x,fill_tile_y;wire [95:0] fill_rgb;wire [31:0] fill_bus_bytes;','')
    start=text.index(' geometry_tile_refill refill(');end=text.index(' frame_writer_buffer',start)
    return text[:start]+' // The DDR-domain refill is connected through the bounded quad bridge.\n'+text[end:]

def external_adapter(text):
    text=once(text,'module geometry_processing_domain #(','module geometry_processing_domain_external_refill #(')
    text=once(text,' geometry_frame_processor #(',' geometry_frame_processor_external_refill #(')
    start=text.index('  .source_req_valid(sreq)');end=text.index('  .result_req_valid(rreq)',start)
    text=text[:start]+'''  .fill_req_valid(freq),.fill_req_ready(fready),.fill_tile_x(ftx),.fill_tile_y(fty),
  .fill_valid(fv),.fill_ready(fr),.fill_rgb(frgb),.fill_last(fl),.fill_error(fe),.fill_bus_bytes(fbytes),.refill_busy(fbusy),
'''+text[end:]
    anchor=' localparam JOB_BITS=META_BITS+738;'
    text=once(text,anchor,''' // Quads cross once per tile; all row addresses/checks stay with DDR.
 wire freq,fready,fv,fr,fl,fe,fbusy,mreq,mready,mv,mr,ml,me;
 wire [11:0] ftx,fty,mtx,mty;wire [95:0] frgb,mrgb;wire [31:0] fbytes,mbytes;
'''+anchor)
    start=text.index(' dma_read_cdc source_bridge(');end=text.index(' dma_write_cdc result_bridge(',start)
    replacement=''' tile_refill_cdc refill_bridge(
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
'''
    return text[:start]+replacement+text[end:]

def main():
    f=Path(__file__).resolve().parents[1];directory=f/'experiments/proc150/rtl'
    originals=[f/'rtl/geometry/geometry_frame_processor.sv',directory/'geometry_processing_domain.sv']
    targets=[directory/'geometry_frame_processor_external_refill.sv',directory/'geometry_processing_domain_external_refill.sv']
    for source,target,transform in zip(originals,targets,[external_processor,external_adapter]):
        if target.exists():raise ValueError('Do not overwrite prepared variant')
        target.write_text(transform(source.read_text(encoding='utf-8')),encoding='utf-8',newline='\n')
    (directory/'tile_refill_domain_origin.json').write_text(json.dumps(dict(
        originals={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in originals},
        targets={str(p):hashlib.sha256(p.read_bytes()).hexdigest() for p in targets},
        production_changed=False,one_native_transaction_per_refill=True),indent=2))
    print('TILE_DOMAIN_PREPARED')

if __name__=='__main__':main()

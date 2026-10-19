"""Express the full frame span product with signed source-width operands."""
from datetime import datetime
import hashlib,json,shutil
from pathlib import Path


def localize(text):
    before=" wire [63:0] span_end={32'd0,frame_base}+({48'd0,frame_height}-1)*{32'd0,frame_stride}+"
    after=""" // Height-1 is exactly -1..65534, including the rejected height=0
 // case. A signed 17x33 product retains every input bit and its full result;
 // sign extension restores the original modulo-2^64 negative-product value.
 // The width/RGB term and final 64-bit round-up/range check are unchanged.
 wire signed [16:0] preceding_rows=$signed({1'b0,frame_height})-17'sd1;
 wire signed [49:0] row_span=preceding_rows*$signed({1'b0,frame_stride});
 wire [63:0] span_end={32'd0,frame_base}+{{14{row_span[49]}},row_span}+"""
    if text.count(before)!=1:raise ValueError('Unexpected span expression')
    return text.replace(before,after)


def main():
    fpga=Path(__file__).resolve().parents[1]
    names=json.loads((fpga/'build/route_optimization/session_20261019/unpack_finalist/sources.json').read_text())
    run=fpga/'build/route_optimization'/datetime.now().strftime('writer_span_product_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    for name,expected in names.items():
        p=fpga/name
        if hashlib.sha256(p.read_bytes()).hexdigest()!=expected:raise ValueError('Main drift: '+name)
        target=source/name;target.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p,target)
    for name in ['frame_pixel_writer','geometry_tile_refill']:
        shutil.copyfile(source/'rtl/memory'/(name+'.sv'),run/('original_'+name+'.sv'))
    target=source/'rtl/memory/frame_pixel_writer.sv'
    target.write_text(localize(target.read_text(encoding='utf-8')),encoding='utf-8',newline='\n')
    (run/'sources.json').write_text(json.dumps({n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in names},indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/frame_pixel_writer.sv'],extra_latency_cycles=0,final_span_bits=64,
        signed_product_bits=50,height_zero_semantics_retained=True,pixel_precision_unchanged=True),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print(run)


if __name__=='__main__':main()

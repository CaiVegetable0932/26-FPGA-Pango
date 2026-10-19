"""Build an experimental source closure; never edit production RTL/fixtures."""
from pathlib import Path
from datetime import datetime
import argparse,hashlib,json,shutil

def replace_once(text,old,new):
    if text.count(old)!=1:raise ValueError('Unexpected integration anchor: '+old)
    return text.replace(old,new)

def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline',type=Path,required=True)
    parser.add_argument('--read-prefetch-proof',type=Path)
    parser.add_argument('--exact-clock',action='store_true',help='Use femtosecond precision for the 150MHz model')
    args=parser.parse_args();fpga=Path(__file__).resolve().parents[1];baseline=args.baseline.resolve()
    names=json.loads((baseline/'sources.json').read_text())
    if len(names)!=290 or not all(hashlib.sha256((baseline/'source'/n).read_bytes()).hexdigest()==h for n,h in names.items()):
        raise ValueError('Intact 290-input baseline required')
    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_video_model_%Y%m%d_%H%M%S_%f')
    shutil.copytree(baseline/'source',run/'source');source=run/'source'
    for n,d in [('geometry_processing_domain.sv','geometry'),('processing_job_cdc.sv','memory'),('dma_write_cdc.sv','memory')]:
        shutil.copyfile(fpga/'experiments/proc150/rtl'/n,source/'rtl'/d/n)
    extra_names=[]
    if args.read_prefetch_proof:
        checked=json.loads((args.read_prefetch_proof/'result.json').read_text())
        if not checked.get('passed') or len(checked.get('tests',[]))!=8 or any(
            hashlib.sha256(Path(p).read_bytes()).hexdigest()!=h for p,h in checked['inputs'].items()):
            raise ValueError('Complete intact prefetch proof required')
        name='rtl/memory/dma_read_cdc_prefetch.sv';extra_names.append(name)
        shutil.copyfile(fpga/'experiments/proc150/rtl/dma_read_cdc_prefetch.sv',source/name)
        adapter=source/'rtl/geometry/geometry_processing_domain.sv'
        adapter.write_text(replace_once(adapter.read_text(),'dma_read_cdc source_bridge(',
            'dma_read_cdc_prefetch source_bridge('),encoding='utf-8',newline='\n')
    core=source/'rtl/board/video_memory_core.sv';text=core.read_text(encoding='utf-8')
    text=replace_once(text,' input clk,rst_n,controller_ready,',' input clk,rst_n,processing_clk,processing_rst_n,controller_ready,')
    # Move the immutable LUT boot writer as one local unit. Only its ready bit
    # crosses to DDR; all 256 data writes and commit remain in processing_clk.
    start=text.index(' reg [8:0] tone_cursor;');end=text.index(' frame_meta_t processor_meta;',start)
    tone=text[start:end].replace('posedge clk or negedge rst_n','posedge processing_clk or negedge processing_rst_n').replace('if(!rst_n)','if(!processing_rst_n)')
    tone+=''' // Processing-side LUT completion crosses as a single synchronized bit.
 (* syn_preserve=1 *) reg tone_ready_meta,tone_ready_ddr;
 always @(posedge clk or negedge rst_n)begin
  if(!rst_n)begin tone_ready_meta<=0;tone_ready_ddr<=0;end
  else begin tone_ready_meta<=!SUPPORT_CONTROLS || (tone_cursor[8] && !tone_commit);tone_ready_ddr<=tone_ready_meta;end
 end
 wire mailbox_ready;
 assign geo_ready=mailbox_ready && tone_ready_ddr;
'''
    text=text[:start]+tone+text[end:]
    text=replace_once(text,'geometry_frame_processor #(.META_BITS(META_BITS),.PROJECTIVE(PROJECTIVE)) processor(.clk(clk),.rst_n(rst_n),.job_valid(geo_valid),.job_ready(geo_ready),',
        'geometry_processing_domain #(.META_BITS(META_BITS),.PROJECTIVE(PROJECTIVE)) processor(.clk(clk),.rst_n(rst_n),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),.job_valid(geo_valid && tone_ready_ddr),.job_ready(mailbox_ready),')
    text=replace_once(text,',.cache_misses(),.cache_stalls(),.cache_bus_bytes());',');')
    core.write_text(text,encoding='utf-8',newline='\n')
    (source/'sim').mkdir(exist_ok=True)
    for name in ['tb_video_memory_core.sv','video_core_display_fixture.sv']:
        shutil.copyfile(fpga/'sim'/name,source/'sim'/name)
    tb=source/'sim/tb_video_memory_core.sv';text=tb.read_text(encoding='utf-8')
    # Add a real independent 150MHz simulation clock and local reset release.
    anchor='module tb_video_memory_core'
    pos=text.index(';',text.index(anchor))+1
    text=text[:pos]+'''
 reg processing_clk=0,processing_rst_n=0;
 initial begin #0.7;forever #3.333 processing_clk=~processing_clk;end
 always @(negedge rst_n)processing_rst_n<=0;
 always @(negedge processing_clk)processing_rst_n<=rst_n;
'''+text[pos:]
    if args.exact_clock:
        # A 1ps unit would round every half-cycle to 3.333ns (150.015MHz).
        # Keep the real 6.666667ns target to femtosecond rounding instead.
        text=replace_once(text,'`timescale 1ns/1ps','`timescale 1ns/1fs')
        text=replace_once(text,'forever #3.333 processing_clk','forever #3.333333333 processing_clk')
    text=replace_once(text,'.clk(clk),.rst_n(rst_n),.controller_ready(','.clk(clk),.rst_n(rst_n),.processing_clk(processing_clk),.processing_rst_n(processing_rst_n),.controller_ready(')
    text=text.replace('dut.processor.geometry.coefficients','dut.processor.processor.geometry.coefficients')
    # The prior fixture looked one DDR edge after synchronous admission. With
    # the mailbox, wait for actual processor admission before checking the same
    # old-frame coefficient/version assertion; no identity oracle is removed.
    # Return stimulus to a DDR falling edge before the following UART-style
    # submit pulse: a processing edge may fall after DDR's sampling edge and
    # otherwise truncate the pulse before it can be accepted by the DDR bank.
    text=replace_once(text,'next_normal_frame(3,81);wait(dut.geo_valid && dut.geo_ready);@(posedge clk);@(negedge clk);',
        'next_normal_frame(3,81);wait(dut.geo_valid && dut.geo_ready);@(posedge clk);\n   wait(dut.processor.pv && dut.processor.pr);@(posedge processing_clk);@(negedge processing_clk);@(negedge clk);')
    tb.write_text(text,encoding='utf-8',newline='\n')
    all_names=[*names,*extra_names,*['rtl/'+d+'/'+n for n,d in [('geometry_processing_domain.sv','geometry'),('processing_job_cdc.sv','memory'),('dma_write_cdc.sv','memory')]],'sim/tb_video_memory_core.sv','sim/video_core_display_fixture.sv']
    hashes={n:hashlib.sha256((source/n).read_bytes()).hexdigest() for n in all_names}
    (run/'sources.json').write_text(json.dumps(hashes,indent=2))
    (run/'candidate.json').write_text(json.dumps(dict(experimental_only=True,production_instantiated=False,
        baseline=str(baseline),processing_clock_period_ns=6.666666666 if args.exact_clock else 6.666,ddr_clock_period_ns=8,
        exact_clock=args.exact_clock,read_prefetch_proof=str(args.read_prefetch_proof) if args.read_prefetch_proof else None,
        common_reset_assertion_required=True,pll_hardware_integrated=False,
        changed_production_files=[],input_count=len(hashes)),indent=2))
    shutil.copyfile(__file__,run/'prepare_script.py');print('PROC150_VIDEO_MODEL',run)

if __name__=='__main__':main()

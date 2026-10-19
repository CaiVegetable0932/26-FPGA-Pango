"""Compare repaired writer/refill against frozen originals on the same edges.

Independent native-memory scoreboards remain enabled. Compare handshakes and
valid payloads cycle by cycle, so changed latency cannot hide behind equal final
images. Sweep raster/tiled RAW/RGB, partial segments, tile bands and 4KiB splits.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import subprocess


def comparison(module, outputs, inputs, params=''):
    """Connect original outputs to separate wires while sharing all stimulus."""
    declarations = '\n'.join(' wire '+width+' baseline_'+name+';' for name, width in outputs.items())
    ports = ['.'+name+'(baseline_'+name+')' for name in outputs]
    ports += ['.'+name+'('+name+')' for name in inputs.split()]
    return declarations+'\n '+module+'_baseline '+params+' baseline('+','.join(ports)+');\n'


def main():
    """Keep all generated fixtures and failure logs under the candidate build."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--candidate', type=Path, required=True)
    parser.add_argument('--reference-candidate', type=Path,
                        help='Use preserved original writer/refill from an earlier candidate')
    parser.add_argument('--storage-edges', action='store_true',
                        help='Also cover uninitialized/retained row storage and mid-DMA reset')
    parser.add_argument('--writer-context', action='store_true',
                        help='Check the redundant writer context against original current state')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    candidate = args.candidate.resolve()
    if not candidate.is_relative_to(fpga / 'build'):
        raise ValueError('Candidate must be under fpga/build')
    # Composed candidates may preserve references equal to their own modules.
    # An explicit earlier reference checks the cumulative changes without
    # rewriting old proof inputs; record its real paths and hashes below.
    reference = args.reference_candidate.resolve() if args.reference_candidate else candidate
    if not reference.is_relative_to(fpga / 'build'):
        raise ValueError('Reference candidate must be under fpga/build')
    run = candidate / datetime.now().strftime('differential_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    source = candidate / 'source'
    tool = fpga / 'build/ov5640_pwm_20261012/tools/iverilog/app/bin'
    inputs = {}
    # Freeze both reference modules and independent testbench sources in the
    # result directory. No running build or live RTL is modified by this test.
    for module in ('frame_pixel_writer', 'geometry_tile_refill'):
        p = reference / ('original_'+module+'.sv')
        inputs[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
        text = p.read_text(encoding='utf-8').replace('module '+module, 'module '+module+'_baseline', 1)
        (run / (module+'_baseline.sv')).write_text(text, encoding='utf-8')
    for name in ('rtl/memory/frame_pixel_writer.sv', 'rtl/memory/geometry_tile_refill.sv',
                 'rtl/memory/ddr_native_dma.v', 'rtl/memory/dma_pixel_pack.v'):
        p = source / name
        inputs[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
        shutil.copyfile(p, run / p.name)
    for module in ('frame_pixel_writer', 'geometry_tile_refill'):
        p = fpga / 'sim' / ('tb_'+module+'.sv')
        inputs[str(p)] = hashlib.sha256(p.read_bytes()).hexdigest()
        shutil.copyfile(p, run / ('original_tb_'+module+'.sv'))
    writer = (run / 'original_tb_frame_pixel_writer.sv').read_text(encoding='utf-8')
    writer = writer.replace('module tb_frame_pixel_writer;', 'module tb_frame_pixel_writer #(parameter W=35,H=9,TILED=1);')
    writer = writer.replace('frame_width=35,frame_height=9', 'frame_width=W,frame_height=H')
    writer = writer.replace('.TILED(1)', '.TILED(TILED)')
    writer = writer.replace('65535', '262143').replace('65536', '262144')
    writer = writer.replace('for(integer ty=0;ty<9;ty+=8)for(integer tx=0;tx<35;tx+=32)\n    for(integer y=ty;y<ty+8 && y<9;y++)for(integer x=tx;x<tx+32 && x<35;x++)send_pixel(x,y);',
        '''if(TILED)begin
    for(integer ty=0;ty<H;ty+=8)for(integer tx=0;tx<W;tx+=32)
     for(integer y=ty;y<ty+8 && y<H;y++)for(integer x=tx;x<tx+32 && x<W;x++)send_pixel(x,y);
   end else begin
    for(integer y=0;y<H;y++)for(integer x=0;x<W;x++)send_pixel(x,y);
   end''')
    writer = writer.replace('accepted_pixels!=315', 'accepted_pixels!=W*H')
    writer = writer.replace('y<9;y++', 'y<H;y++').replace('x>=35*(rgb?3:1)', 'x>=W*(rgb?3:1)')
    outputs = {n:'' for n in 'frame_ready in_ready frame_done frame_failed req_valid req_write w_valid dma_cancel done_ready'.split()}
    outputs.update({n:'[31:0]' for n in 'accepted_pixels req_addr req_tag w_strb'.split()})
    outputs.update(req_beats='[4:0]', w_data='[255:0]')
    added = comparison('frame_pixel_writer', outputs,
        'clk rst_n frame_valid frame_base frame_stride frame_generation frame_width frame_height frame_rgb888 frame_abort in_valid in_pixel in_x in_y req_ready w_ready done dma_error dma_cancelled done_tag', '#(.TILED(TILED))')
    # Compare control on every active edge; data/address only while VALID.
    added += ''' always @(negedge clk)begin #2;
  if(rst_n)begin
   if({frame_ready,in_ready,frame_done,frame_failed,accepted_pixels,req_valid,w_valid,dma_cancel,done_ready} !==
      {baseline_frame_ready,baseline_in_ready,baseline_frame_done,baseline_frame_failed,baseline_accepted_pixels,baseline_req_valid,baseline_w_valid,baseline_dma_cancel,baseline_done_ready})$fatal(1,"WRITER_DIFFERENTIAL control/latency");
   if(req_valid && {req_addr,req_tag,req_beats,req_write} !== {baseline_req_addr,baseline_req_tag,baseline_req_beats,baseline_req_write})$fatal(1,"WRITER_DIFFERENTIAL request");
   if(w_valid && {w_data,w_strb} !== {baseline_w_data,baseline_w_strb})$fatal(1,"WRITER_DIFFERENTIAL data");
  end
 end
'''
    if args.writer_context:
        # Check redundant state before it gates payload writes, including
        # inactive cycles; equal final output alone can miss a stale context.
        writer_source = (run / 'frame_pixel_writer.sv').read_text(encoding='utf-8')
        if 'reg collect_write_context;' not in writer_source:
            raise ValueError('Writer context invariant requested for a different candidate')
        added += ''' always @(negedge clk)begin #2;
  if(rst_n && writer.collect_write_context !== (writer.state==2 && !writer.aborting))
   $fatal(1,"WRITER_DIFFERENTIAL collect context invariant");
 end
'''
    writer = writer.replace('endmodule', added+'endmodule')
    (run / 'tb_frame_pixel_writer.sv').write_text(writer, encoding='utf-8')
    refill = (run / 'original_tb_geometry_tile_refill.sv').read_text(encoding='utf-8')
    refill = refill.replace('module tb_geometry_tile_refill;', 'module tb_geometry_tile_refill #(parameter EDGE_WIDTH=1919);')
    refill = refill.replace('source_width=1919;', 'source_width=EDGE_WIDTH;')
    if args.storage_edges:
        # Storage without reset must overwrite every observable byte, including
        # after a partial DMA and with many virtual bottom rows. Keep the real
        # DMA plus independent RGB/byte/drain scoreboards from the fixture.
        marker='  // Reject wrapped source spans before issuing any memory request.'
        extra='''  if(EDGE_WIDTH==1919)begin
   // Reset while an accepted transfer is returning data, then restart with
   // a tiny cold frame; no previously stored byte may become a valid sample.
   scoring=1;submit(0,0);wait(r_valid);@(negedge clk);rst_n=0;scoring=0;
   repeat(4)@(negedge clk);rst_n=1;repeat(4)@(negedge clk);
   source_width=2;source_height=2;run_tile(0,0);
   // Exercise 1/2/3-beat row tails and both actual and virtual bottom rows.
   for(integer wi=0;wi<11;wi++)begin
    case(wi)
     0:source_width=2;1:source_width=10;2:source_width=11;3:source_width=21;
     4:source_width=22;5:source_width=31;6:source_width=32;7:source_width=33;
     8:source_width=63;9:source_width=64;10:source_width=65;
    endcase
    for(integer hi=0;hi<5;hi++)begin
     case(hi)0:source_height=2;1:source_height=3;2:source_height=7;
      3:source_height=8;4:source_height=9;endcase
     run_tile((source_width-1)/32,(source_height-1)/8);
    end
   end
   $display("STORAGE_EDGE_PASS tiny_cold_frame=1 tail_bottom_shapes=55 mid_dma_reset=1");
  end
'''
        if refill.count(marker)!=1:
            raise ValueError('Unexpected refill fixture for storage edges')
        refill=refill.replace(marker,extra+marker,1)
    outputs = {n:'' for n in 'fill_req_ready fill_valid fill_last fill_error req_valid req_write dma_cancel r_ready done_ready busy'.split()}
    outputs.update({n:'[31:0]' for n in 'fill_bus_bytes req_addr req_tag'.split()})
    outputs.update(fill_rgb='[95:0]', req_beats='[4:0]')
    added = comparison('geometry_tile_refill', outputs,
        'clk rst_n fill_req_valid fill_tile_x fill_tile_y source_base source_stride source_generation source_width source_height fill_ready cancel req_ready r_valid r_data r_last done dma_error dma_cancelled done_tag')
    added += ''' always @(negedge clk)begin #2;
  if(rst_n)begin
   if({fill_req_ready,fill_valid,req_valid,dma_cancel,r_ready,done_ready,busy,fill_bus_bytes} !==
      {baseline_fill_req_ready,baseline_fill_valid,baseline_req_valid,baseline_dma_cancel,baseline_r_ready,baseline_done_ready,baseline_busy,baseline_fill_bus_bytes})$fatal(1,"REFILL_DIFFERENTIAL control/latency");
   if(req_valid && {req_addr,req_tag,req_beats,req_write} !== {baseline_req_addr,baseline_req_tag,baseline_req_beats,baseline_req_write})$fatal(1,"REFILL_DIFFERENTIAL request");
   if(fill_valid && {fill_rgb,fill_last,fill_error} !== {baseline_fill_rgb,baseline_fill_last,baseline_fill_error})$fatal(1,"REFILL_DIFFERENTIAL quad");
  end
 end
'''
    refill = refill.replace('endmodule', added+'endmodule')
    (run / 'tb_geometry_tile_refill.sv').write_text(refill, encoding='utf-8')
    cases = []
    for tiled in (0,1):
        for width,height in ((1,1),(10,7),(11,8),(21,9),(22,17),(31,9),(32,17),(33,8),(35,9),(64,17),(65,9),(1920,9)):
            cases.append(('writer_%s_%s_%s'%(tiled,width,height), 'tb_frame_pixel_writer',
                          {'TILED':tiled,'W':width,'H':height}))
    for width in (1889,1898,1899,1909,1910,1919,1920):
        cases.append(('refill_'+str(width), 'tb_geometry_tile_refill', {'EDGE_WIDTH':width}))
    status = dict(passed=False, tests=[], inputs=inputs, cycle_equivalent=False,
                  storage_edges=args.storage_edges, writer_context=args.writer_context)
    try:
        for name,top,params in cases:
            executable = run / (name+'.vvp')
            files = [str(run / n) for n in ('ddr_native_dma.v','dma_pixel_pack.v',
                     'frame_pixel_writer.sv','frame_pixel_writer_baseline.sv',
                     'geometry_tile_refill.sv','geometry_tile_refill_baseline.sv',top+'.sv')]
            compile_cmd = [str(tool/'iverilog.exe'),'-g2012','-s',top,'-o',str(executable)]
            compile_cmd += ['-P'+top+'.'+k+'='+str(v) for k,v in params.items()]
            for phase,cmd in [('compile',compile_cmd+files),('run',[str(tool/'vvp.exe'),str(executable)])]:
                result = subprocess.run(cmd,cwd=run,capture_output=True,timeout=180,creationflags=0x08000000)
                log = result.stdout+result.stderr
                (run/(name+'.'+phase+'.log')).write_bytes(log)
                if result.returncode or (phase=='run' and (b'_PASS' not in log or b'FATAL' in log)):
                    raise RuntimeError(name+' '+phase+': '+log.decode(errors='replace')[-2000:])
            status['tests'].append(name)
            print(name,'PASS',flush=True)
        status.update(passed=True,cycle_equivalent=True)
    finally:
        status['inputs_intact']=all(hashlib.sha256(Path(n).read_bytes()).hexdigest()==h for n,h in inputs.items())
        (run/'result.json').write_text(json.dumps(status,indent=2),encoding='utf-8')
        shutil.copyfile(__file__,run/'verification_script.py')
        print('DIFFERENTIAL_RUN',run,flush=True)


if __name__=='__main__':
    main()

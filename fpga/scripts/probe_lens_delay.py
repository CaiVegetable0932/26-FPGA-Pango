"""Measure lossless circular RAM payload delays in the native lens pipeline."""
from datetime import datetime
from pathlib import Path
import argparse
import hashlib
import json
import re
import shutil
import subprocess


def candidate_text(code):
    """Replace only pure delay chains; arithmetic and validity retain their stages."""
    replacements = {
        'reg [TAG_BITS-1:0] tags[0:22];': 'wire [TAG_BITS-1:0] delayed_tag;',
        'reg signed [23:0] x[0:13],y[0:13];':
        'reg signed [23:0] x_first,y_first; wire signed [23:0] x_last,y_last;',
        'reg signed [31:0] t,radial,tx[0:6],ty[0:6],xd,yd;':
        'reg signed [31:0] t,radial,xd,yd; wire signed [31:0] tx_last,ty_last;',
        '   tags[0]<=in_tag;\n   for(i=1;i<23;i=i+1) tags[i]<=tags[i-1];\n': '',
        '   for(i=1;i<14;i=i+1) begin x[i]<=x[i-1];y[i]<=y[i-1];end\n': '',
        '   tx[0]<=tx_round[31:0];ty[0]<=ty_round[31:0];\n   for(i=1;i<7;i=i+1) begin tx[i]<=tx[i-1];ty[i]<=ty[i-1];end\n': ''}
    for old,new in replacements.items():
        if code.count(old)!=1:
            raise ValueError('Unexpected lens delay declaration or writer: '+old)
        code=code.replace(old,new)
    for old,new in [('tags[22]','delayed_tag'),('x[0]','x_first'),('y[0]','y_first'),
                    ('x[13]','x_last'),('y[13]','y_last'),('tx[6]','tx_last'),('ty[6]','ty_last')]:
        code=code.replace(old,new)
    delay = '''
 // Purpose: preserve 14/23/7 accepted-advance alignment using LUT RAM
 // (installed ADS 5.16). Nonzero read offsets avoid write/read collisions.
 // Public validity flushes stale entries after pointer reset; all payload
 // writes/reads freeze under the original common stall/reset guard.
 reg [4:0] payload_write;
 wire [4:0] xy_read=payload_write-5'd13;
 wire [4:0] tag_read=payload_write-5'd22;
 wire [4:0] tangent_read=payload_write-5'd6;
 reg [47:0] xy_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [TAG_BITS-1:0] tag_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [63:0] tangent_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [47:0] xy_output;
 reg [TAG_BITS-1:0] tag_output;
 reg [63:0] tangent_output;
 assign {x_last,y_last}=xy_output;
 assign delayed_tag=tag_output;
 assign {tx_last,ty_last}=tangent_output;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) payload_write<=0;
  else if(advance) payload_write<=payload_write+1'b1;
 end
 always @(posedge clk) if(rst_n && advance) begin
  xy_memory[payload_write]<={in_x,in_y};
  tag_memory[payload_write]<=in_tag;
  tangent_memory[payload_write]<={tx_round[31:0],ty_round[31:0]};
  xy_output<=xy_memory[xy_read];
  tag_output<=tag_memory[tag_read];
  tangent_output<=tangent_memory[tangent_read];
 end
'''
    code=code.replace(' integer i;',delay+' integer i;')
    if re.search(r'\b(?:x|y|tx|ty|tags)\s*\[',code):
        raise ValueError('Old payload chain reference remains')
    return code


def main():
    """Freeze both implementations; compare identical TAG_BITS=32 native targets."""
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-snapshot',type=Path,required=True)
    args=parser.parse_args()
    fpga=Path(__file__).resolve().parents[1]
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('lens_delay_%Y%m%d_%H%M%S')
    run.mkdir();shutil.copyfile(Path(__file__),run/'probe_script.py')
    result=dict(passed=False,hardware_tested=False,board_routed=False,variants=[])
    print('PROBE',run,flush=True)
    try:
        for variant in ('baseline','candidate'):
            target=run/variant;source=target/'source';source.mkdir(parents=True)
            for name in ('lens_inverse_map.sv','signed_mult32_pipe.sv'):
                shutil.copyfile(args.rtl_snapshot/'rtl/geometry'/name,source/name)
            path=source/'lens_inverse_map.sv';code=path.read_text(encoding='utf-8')
            if variant=='candidate':code=candidate_text(code)
            # The real board carries 32 coordinate bits. Parameterizing the
            # isolated top this way avoids claiming savings on an unused tag.
            code=code.replace('parameter TAG_BITS=192','parameter TAG_BITS=32')
            path.write_text(code,encoding='utf-8')
            manifest={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir()}
            (target/'sources.json').write_text(json.dumps(manifest,indent=2))
            (target/'clock.fdc').write_text('create_clock -name clk -period 8.0 [get_ports clk]\n')
            flow=f'set_dir -impl_directory {{{target.as_posix()}}}\nset_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for p in source.iterdir():flow+=f'add_design {{{p.as_posix()}}}\n'
            flow+=f'add_constraint {{{(target/"clock.fdc").as_posix()}}}\ncompile -top_module lens_inverse_map -system_verilog\nsynthesize -ads -selected_syn_tool_opt 2\n'
            (target/'flow.tcl').write_text(flow)
            print('SYN',variant,flush=True)
            with (target/'console.log').open('wb') as log:
                child=subprocess.run(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe','-file',str(target/'flow.tcl'),'-work_dir',str(target)],cwd=target,stdout=log,stderr=subprocess.STDOUT,timeout=1800,creationflags=0x08000000)
            errors=re.findall(r'^E:.*',(target/'console.log').read_text(errors='replace'),re.M)
            entry=dict(variant=variant,native_exit=child.returncode,errors=errors)
            result['variants'].append(entry)
            if child.returncode or errors:raise RuntimeError('Native lens synthesis failed')
            for line in (target/'synthesize/lens_inverse_map.snr').read_text(errors='replace').splitlines():
                cols=[c.strip() for c in line.split('|')]
                if len(cols)>7 and cols[1]=='lens_inverse_map':
                    entry['resources']=dict(zip(['LUT','FF','Distributed RAM','APM','DRM'],cols[2:7]));break
            entry['snapshot_intact']=all(hashlib.sha256((source/n).read_bytes()).hexdigest()==h for n,h in manifest.items())
            if not entry['snapshot_intact'] or 'resources' not in entry:raise RuntimeError('Incomplete native evidence')
            print(json.dumps(entry),flush=True)
        result['passed']=True
    finally:
        (run/'result.json').write_text(json.dumps(result,indent=2)+'\n')
        print(json.dumps(result),flush=True)


if __name__=='__main__':
    main()

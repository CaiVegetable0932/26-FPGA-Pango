"""Measure installed ADS shift-register attributes on immutable divider copies."""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import re
import shutil
import subprocess
import time


def main():
    # This historical transform expects the retired projective architecture.
    raise SystemExit('Retired projective experiment: reproduce from its frozen build/source; current production is affine_lens.')
    """Compare the same 32-bit-tag, full-precision divider, without board changes."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--rtl-snapshot', type=Path, required=True)
    parser.add_argument('--packed-chains', action='store_true',
                        help='Use the exact packed-vector shift idiom in ADS section 5.19')
    parser.add_argument('--circular-memory', action='store_true',
                        help='Use explicit LUT RAM with distinct read/write addresses')
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    run = fpga / 'build/full_integration_20261013' / datetime.now().strftime('srl_%Y%m%d_%H%M%S')
    run.mkdir()
    shutil.copyfile(Path(__file__), run / 'probe_script.py')
    names = ['perspective_divide.sv', 'unsigned_mult32_pipe.sv', 'signed_mult40_unsigned40_pipe.sv']
    result = dict(passed=False, hardware_tested=False, board_routed=False, variants=[],
                  official_reference='E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/ADS_Synthesis_User_Guide.pdf',
                  official_section=('5.16 syn_ramstyle' if args.circular_memory else '5.19 syn_srlstyle'),
                  original_snapshot=str(args.rtl_snapshot.resolve()))
    print('PROBE', run, flush=True)
    try:
        for variant in ('baseline', 'candidate'):
            target = run / variant
            source = target / 'source'
            source.mkdir(parents=True)
            for name in names:
                shutil.copyfile(args.rtl_snapshot / 'rtl/geometry' / name, source / name)
            shutil.copyfile(fpga / 'sim/perspective_timing_probe.sv', source / 'perspective_timing_probe.sv')
            if variant == 'candidate':
                path = source / 'perspective_divide.sv'
                code = path.read_text(encoding='utf-8')
                replacements = {
                    'reg [TAG_BITS-1:0] tags[0:25];':
                    '// PDS 2022.2-SP6.4 ADS section 5.19: preserve all CE steps and bits,\n'
                    ' // but request distributed storage for pure payload shift chains.\n'
                    ' reg [TAG_BITS-1:0] tags[0:25] /* synthesis syn_srlstyle="lut_ram" */;',
                    'reg signed [39:0] n0[0:20],n1[0:20];':
                    'reg signed [39:0] n0[0:20] /* synthesis syn_srlstyle="lut_ram" */;\n'
                    ' reg signed [39:0] n1[0:20] /* synthesis syn_srlstyle="lut_ram" */;'
                }
                for old, new in replacements.items():
                    if code.count(old) != 1:
                        raise ValueError('Unexpected divider declaration: '+old)
                    code = code.replace(old, new)
                if args.packed_chains or args.circular_memory:
                    # Unpacked array annotations alone did not infer SRLs in
                    # the first measurement. Use the documented packed-vector
                    # shift form, preserving every bit, CE step and latency.
                    code = code.replace('reg [TAG_BITS-1:0] tags[0:25] /* synthesis syn_srlstyle="lut_ram" */;',
                                        'wire [TAG_BITS-1:0] delayed_tag;')
                    code = code.replace('reg signed [39:0] n0[0:20] /* synthesis syn_srlstyle="lut_ram" */;\n reg signed [39:0] n1[0:20] /* synthesis syn_srlstyle="lut_ram" */;',
                                        'wire signed [39:0] delayed_n0,delayed_n1;')
                    code = code.replace('n0[20]', 'delayed_n0').replace('n1[20]', 'delayed_n1').replace('tags[25]', 'delayed_tag')
                    code = code.replace('   tags[0]<=in_tag;\n', '')
                    code = code.replace('   n0[0]<=q0;n1[0]<=q1;', '   ')
                    code = code.replace('   for(i=1;i<26;i=i+1) tags[i]<=tags[i-1];\n', '')
                    code = code.replace('begin n0[i]<=n0[i-1];n1[i]<=n1[i-1];exponent[i]<=exponent[i-1];end',
                                        'begin exponent[i]<=exponent[i-1];end')
                    chains = '''
 // Purpose: lossless payload alignment using the packed shift form supported
 // by installed ADS. Each bit holds during stall/reset and advances alongside
 // valid/ok; no arithmetic, tag width or pipeline latency is changed.
 genvar payload_bit;
 generate
  for(payload_bit=0;payload_bit<40;payload_bit=payload_bit+1) begin : numerator_delay
   reg [20:0] lane0 /* synthesis syn_srlstyle="lut_ram" */;
   reg [20:0] lane1 /* synthesis syn_srlstyle="lut_ram" */;
   always @(posedge clk) if(rst_n && advance) begin
    lane0<={lane0[19:0],q0[payload_bit]};
    lane1<={lane1[19:0],q1[payload_bit]};
   end
   assign delayed_n0[payload_bit]=lane0[20];
   assign delayed_n1[payload_bit]=lane1[20];
  end
  for(payload_bit=0;payload_bit<TAG_BITS;payload_bit=payload_bit+1) begin : tag_delay
   reg [25:0] lane /* synthesis syn_srlstyle="lut_ram" */;
   always @(posedge clk) if(rst_n && advance) lane<={lane[24:0],in_tag[payload_bit]};
   assign delayed_tag[payload_bit]=lane[25];
  end
 endgenerate
'''
                    if args.circular_memory:
                        code = code.replace('ADS section 5.19:', 'ADS section 5.16:')
                        # A registered read at write_pointer-(DEPTH-1) matches
                        # exactly DEPTH CE advances. Offsets 20/25 are nonzero
                        # modulo 32, so no read-during-write collision occurs.
                        # Reset only the pointer; valid masks every old payload
                        # until a complete new lane traverses the pipeline.
                        chains = '''
 // Purpose: retain exact 21/26-advance payload alignment in circular LUT RAM.
 // Reads use addresses distinct from the simultaneous write, with an explicit
 // output register. Stall/reset holds payload; validity flushes old RAM data.
 reg [4:0] payload_write;
 wire [4:0] numerator_read=payload_write-5'd20;
 wire [4:0] tag_read=payload_write-5'd25;
 reg [79:0] numerator_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [TAG_BITS-1:0] tag_memory[0:31] /* synthesis syn_ramstyle="lut_ram" */;
 reg [79:0] numerator_output;
 reg [TAG_BITS-1:0] tag_output;
 assign {delayed_n0,delayed_n1}=numerator_output;
 assign delayed_tag=tag_output;
 always @(posedge clk or negedge rst_n) begin
  if(!rst_n) payload_write<=0;
  else if(advance) payload_write<=payload_write+1'b1;
 end
 always @(posedge clk) if(rst_n && advance) begin
  numerator_memory[payload_write]<={q0,q1};
  tag_memory[payload_write]<=in_tag;
  numerator_output<=numerator_memory[numerator_read];
  tag_output<=tag_memory[tag_read];
 end
'''
                    code = code.replace(' integer i,leading,k;', chains+' integer i,leading,k;')
                    # Check whole identifiers, not suffixes of delayed_n0.
                    if re.search(r'\b(?:n0|n1|tags)\s*\[', code):
                        raise ValueError('Old unpacked shift-chain reference remains')
                path.write_text(code, encoding='utf-8')
            hashes = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in source.iterdir()}
            (target / 'sources.json').write_text(json.dumps(hashes, indent=2), encoding='utf-8')
            # Match the board's native target and 8 ns business clock. No new
            # exception, MAP, route or bitstream is included in this unit probe.
            clock = target / 'clock.fdc'
            clock.write_text('create_clock -name clk -period 8.0 [get_ports clk]\n', encoding='utf-8')
            flow = f'set_dir -impl_directory {{{target.as_posix()}}}\n'
            flow += 'set_arch -family Logos2 -device PG2L100H -speedgrade -6 -package FBG676\n'
            for name in names + ['perspective_timing_probe.sv']:
                flow += f'add_design {{{(source / name).as_posix()}}}\n'
            flow += f'add_constraint {{{clock.as_posix()}}}\n'
            flow += 'compile -top_module perspective_timing_probe -system_verilog\nsynthesize -ads -selected_syn_tool_opt 2\n'
            (target / 'flow.tcl').write_text(flow, encoding='utf-8')
            start = time.time()
            print('SYN', variant, flush=True)
            with (target / 'console.log').open('wb') as log:
                child = subprocess.run(['E:/PDS_Pangu/PDS_2022.2-SP6.4/bin/pds_shell.exe', '-file', str(target / 'flow.tcl'), '-work_dir', str(target)],
                                       cwd=target, stdout=log, stderr=subprocess.STDOUT,
                                       timeout=1800, creationflags=0x08000000)
            errors = re.findall(r'^E:.*', (target / 'console.log').read_text(errors='replace'), re.M)
            intact = all(hashlib.sha256((source / n).read_bytes()).hexdigest() == h for n, h in hashes.items())
            entry = dict(variant=variant, native_exit=child.returncode, errors=errors,
                         snapshot_intact=intact, elapsed_seconds=time.time()-start)
            result['variants'].append(entry)
            if child.returncode or errors or not intact:
                raise RuntimeError('Native unit synthesis failed')
            for line in (target / 'synthesize/perspective_timing_probe.snr').read_text(errors='replace').splitlines():
                cols = [x.strip() for x in line.split('|')]
                if len(cols)>7 and cols[1]=='perspective_timing_probe':
                    entry['resources'] = dict(zip(['LUT','FF','Distributed RAM','APM','DRM'], cols[2:7]))
                    break
            if 'resources' not in entry:
                raise RuntimeError('Native top resource row missing')
            print(json.dumps(entry), flush=True)
        result['passed'] = True
    finally:
        (run / 'result.json').write_text(json.dumps(result, indent=2)+'\n', encoding='utf-8')
        print(json.dumps(result), flush=True)


if __name__ == '__main__':
    main()

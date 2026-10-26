"""Freeze a block-pressure candidate from L without changing production inputs.

Remove one redundant MCU payload stage, detach private PC snapshot storage
from asynchronous reset, and use fixed bank-address selection in the cache.
All external latency, protocol fields and clocks remain part of the baseline.
"""
from datetime import datetime
from pathlib import Path
import argparse
import difflib
import hashlib
import json
import shutil


def main():
    """Check every baseline byte before applying bounded source transformations."""
    fpga = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--two-way', action='store_true',
                        help='Compare a 64-tile/two-way geometry cache against the 128-tile baseline')
    parser.add_argument('--cache-set-bits', type=int, choices=[5,6], default=5,
                        help='Use 64 sets with two ways to retain the original 128-tile capacity')
    args = parser.parse_args()
    base = fpga / 'build/full_integration_20261013/board_postsyn_20261023_221908_913042'
    hashes = json.loads((base / 'sources.json').read_text())
    if not all(hashlib.sha256((base / 'source' / n).read_bytes()).hexdigest() == h for n, h in hashes.items()):
        raise ValueError('Frozen L source changed')
    run = fpga / 'build/block_pressure_20261025' / datetime.now().strftime('candidate_%Y%m%d_%H%M%S_%f')
    run.mkdir(parents=True)
    shutil.copytree(base / 'source', run / 'source')
    shutil.copyfile(base / 'sources.json', run / 'baseline_sources.json')
    changed = []

    def edit(name, operation):
        path = run / 'source' / name
        old = path.read_text(encoding='utf-8')
        new = operation(old)
        if old == new:
            raise ValueError('No change: ' + name)
        original = run / 'baseline' / name
        original.parent.mkdir(parents=True, exist_ok=True)
        original.write_bytes(path.read_bytes())
        path.write_text(new, encoding='utf-8')
        patch = run / 'patches' / (name + '.patch')
        patch.parent.mkdir(parents=True, exist_ok=True)
        patch.write_text(''.join(difflib.unified_diff(old.splitlines(True), new.splitlines(True),
                         fromfile='a/fpga/' + name, tofile='b/fpga/' + name)), encoding='utf-8')
        changed.append(name)

    def replace(text, old, new, count=1):
        if text.count(old) != count:
            raise ValueError('Unexpected baseline fragment: ' + old)
        return text.replace(old, new)

    def mcu(text):
        text = replace(text, 'reg [767:0] state_buffer;reg [63:0] state_time;', 'reg [63:0] state_time;')
        text = replace(text, 'state_buffer<=0;', '')
        text = replace(text, 'state_buffer<=received[0+:768];', '')
        text = replace(text, 'state_payload<=state_buffer;', 'state_payload<=received;')
        text = replace(text, 'last_sample<=state_buffer[128+:32];', 'last_sample<=received[128+:32];')
        text = replace(text,
            '// Stage sample delta separately from acceptance/statistics enables. Keep\n   // the immutable complete STATE across parser ACK, never use the next packet.',
            '// Stage sample delta separately from acceptance/statistics enables.\n   // received is already a complete client-owned copy, independent of parser\n   // ACK/revocation. process_packet does not write it; on this next edge any\n   // new borrow clears it only AFTER these reads (nonblocking assignments).\n   // Thus a second 768-bit intermediate copy is unnecessary. Keep the public\n   // state_payload register and its original publication/reset behavior.')
        return text

    def boot(text):
        text = replace(text, 'status_snapshot<=0;', '')
        text = replace(text, 'status_snapshot<=selected_entity_status;', '', 2)
        block = '''
 // Private readback storage is overwritten in full on accepted page zero.
 // Reset clears have_snapshot/state, so no page can expose its uninitialized
 // payload. Keep the exact original capture edge and last-page retry freeze;
 // removing the payload reset reduces reset/control-set routing pressure.
 wire capture_status_snapshot=state==CHECK &&
  (((operation==8'h90 || operation==8'h95) && received[7:0]==0) ||
   (operation==8'ha4 && read_kind_legal && received[31:24]==0 &&
    received[23:16]==0 && page_count(received[15:0])!=0 && !entity_page_retry));
 always @(posedge clk) if(rst_n && capture_status_snapshot)
  status_snapshot<=selected_entity_status;
'''
        return replace(text, 'endmodule', block + 'endmodule')

    def cache(text):
        text = replace(text, '   bank_addr[banks[i]]=addresses[i];', '')
        anchor = '\n  if(state==SELECT) begin'
        block = '''  // Adjacent/clamped neighbours sharing a parity bank address the same
  // sample. Decode each physical bank locally and OR its matching addresses;
  // this avoids four variable-index writes and their priority merge cascade.
  // A conflicting coordinate set is rejected by the unchanged conflict gate.
  for(i=0;i<4;i=i+1)begin
   bank_addr[i]=0;
   for(j=0;j<4;j=j+1)
    bank_addr[i]=bank_addr[i] | (addresses[j] & {32{banks[j]==i}});
  end
'''
        text = replace(text, anchor, '\n' + block + anchor)
        if args.two_way:
            # Ways are independent of the four pixel parity banks. Keep four
            # synchronous sample ports, while reducing replicated tag search
            # and data capacity. A 2x2 adjacent query pins at most two tiles in
            # any XOR-hashed set; retain the existing no-victim fault fence.
            text = replace(text, 'tiles, 4-way associative,', 'tiles, parameterized 2/4-way associative,')
            text = replace(text, 'parameter TAG_BITS=192,parameter SET_BITS=5,', 'parameter WAY_BITS=2,parameter TAG_BITS=192,parameter SET_BITS=5,')
            text = replace(text, 'localparam SETS=1<<SET_BITS,SLOTS=SETS*4,', 'localparam WAYS=1<<WAY_BITS;\n localparam SETS=1<<SET_BITS,SLOTS=SETS*WAYS,')
            text = replace(text, 'localparam PARAMETERS_VALID=MAX_FRAME_WIDTH>=2', 'localparam PARAMETERS_VALID=(WAY_BITS==1 || WAY_BITS==2) && MAX_FRAME_WIDTH>=2')
            text = replace(text, 'reg [1:0] replace_way', 'reg [WAY_BITS-1:0] replace_way')
            text = replace(text, '[0:3][0:3]', '[0:3][0:WAYS-1]', 4)
            text = replace(text, 'reg [SET_BITS+2:0] saved_slots', 'reg [SET_BITS+WAY_BITS:0] saved_slots')
            text = replace(text, 'for(j=0;j<4;j=j+1)\n    if(query_hit_valid', 'for(j=0;j<WAYS;j=j+1)\n    if(query_hit_valid')
            text = replace(text, 'slots[i]=sets[i]*4+j;', 'slots[i]=sets[i]*WAYS+j;')
            text = replace(text, 'for(w=0;w<4;w=w+1)', 'for(w=0;w<WAYS;w=w+1)')
            text = replace(text, 'rr_way=(replace_way[saved_set]+w)&3;candidate=saved_set*4+rr_way;', 'rr_way=(replace_way[saved_set]+w)&(WAYS-1);candidate=saved_set*WAYS+rr_way;')
            text = replace(text, 'for(n=0;n<4;n=n+1)begin\n     query_x', 'for(n=0;n<WAYS;n=n+1)begin\n     query_x')
            text = replace(text, 'read_set[lane]*4+n', 'read_set[lane]*WAYS+n', 4)
            text = replace(text, 'replace_way[fill_slot>>2]<=fill_slot[1:0]+2\'d1;', 'replace_way[fill_slot>>WAY_BITS]<=fill_slot[WAY_BITS-1:0]+1\'b1;')
        return text

    edit('rtl/control/mcu_readonly_client.sv', mcu)
    edit('rtl/control/pc_video_boot.sv', boot)
    edit('rtl/geometry/rgb_tile_cache.sv', cache)
    if args.two_way:
        def geometry(text):
            text = replace(text, 'parameter TILE_X_BITS=5,', 'parameter CACHE_WAY_BITS=1,parameter TILE_X_BITS=5,')
            text = replace(text, 'parameter SET_BITS=5,', 'parameter SET_BITS='+str(args.cache_set_bits)+',')
            return replace(text, ' rgb_tile_cache #(.TAG_BITS(TAG_BITS),',
                ' // Two ways retain all four parity reads. The selected '+str(2*(1<<args.cache_set_bits))+'-tile cache\n'
                ' // reduces tag/memory footprint; miss bandwidth is checked separately.\n'
                ' rgb_tile_cache #(.WAY_BITS(CACHE_WAY_BITS),.TAG_BITS(TAG_BITS),')
        edit('rtl/geometry/geometry_rgb_pipeline.sv', geometry)
    manifest = {n: hashlib.sha256((run / 'source' / n).read_bytes()).hexdigest() for n in hashes}
    (run / 'sources.json').write_text(json.dumps(manifest, indent=2), encoding='utf-8')
    (run / 'candidate.json').write_text(json.dumps(dict(baseline=str(base), changed_files=changed,
        scope='MCU owned payload reuse, private PC snapshot reset removal, local cache bank selection', cache_ways=2 if args.two_way else 4,
        cache_sets=(1<<args.cache_set_bits) if args.two_way else 32,
        production_selected=False, routed=False, bitstream_generation_allowed=False, hardware_tested=False), indent=2))
    shutil.copyfile(__file__, run / 'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

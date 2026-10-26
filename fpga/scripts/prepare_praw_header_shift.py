"""Prepare an isolated serial-header candidate without changing live/running RTL.

PRAW preparation consumes exactly one header byte per accepted edge. Shift that
private captured header by eight bits instead of selecting through a 64:1 mux.
Packet bytes, checksums, bank ownership, stalls and external latency stay fixed.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes, replace_once


def main():
    """Rehash the frozen baseline and permit exactly one candidate RTL change."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    base = args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Frozen FPGA baseline required')
    before = json.loads((base/'sources.json').read_text())
    if hashes(base/'source') != before:
        raise ValueError('Baseline source changed')
    run = fpga/'build/full_integration_20261013'/datetime.now().strftime('praw_header_shift_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source', run/'source')
    name = 'rtl/network/praw_udp_tx.sv'
    path = run/'source'/name
    old = path.read_text()
    text = replace_once(old, ' wire [7:0] incoming=(wp<64) ? saved_header[wp*8+:8] : data;',
        ''' // Header bytes are consumed in order without gaps in wp. Keep the
 // next byte at the low end of this private descriptor capture, avoiding a
 // wide variable-index mux; payload acceptance and packet timing are unchanged.
 wire [7:0] incoming=(wp<64) ? saved_header[7:0] : data;''')
    text = replace_once(text, '   if(accept) begin\n    mem[{wr_bank,11\'d0}+wp]<=incoming;',
        '''   if(accept) begin
    // Shift only after consuming a header byte. Stalls preserve the cursor,
    // flush discards preparation, and the next descriptor fully overwrites it.
    if(wp<64) saved_header<={8'd0,saved_header[511:8]};
    mem[{wr_bank,11'd0}+wp]<=incoming;''')
    path.write_text(text)
    (run/'original_praw_udp_tx.sv').write_text(old)
    # Preserve previous proof references for any later composite verification.
    for n in ('original_frame_pixel_writer.sv', 'original_geometry_tile_refill.sv'):
        shutil.copyfile(base/n, run/n)
    after = hashes(run/'source')
    if {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Unexpected source changes')
    (run/'sources.json').write_text(json.dumps(after, indent=2)+'\n')
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base), changed=[name],
        functional_pass=False, native_synthesis_started=False, programmed=False), indent=2)+'\n')
    shutil.copyfile(__file__, run/'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

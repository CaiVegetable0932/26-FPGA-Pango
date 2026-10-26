"""Share the already-validated descriptor bus across ACQUIRE response lanes.

The synchronous multi-slot bank accepts at most one consumer per cycle. Every
accepted one-slot consumer refers to the same slot. Thus a single complete
descriptor can feed all lanes; only acquire_ok qualifies a lane's payload.
No-ACK/quarantine responses remain zero. No ownership or cycle behavior changes.
"""
import argparse
from datetime import datetime
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes,replace_once


def main():
    """Keep the previous synchronized bank as a differential reference."""
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument('--baseline',type=Path,required=True)
    args=p.parse_args();fpga=Path(__file__).resolve().parents[1];base=args.baseline.resolve()
    if not base.is_relative_to(fpga/'build'):
        raise ValueError('Use a frozen baseline')
    before=json.loads((base/'sources.json').read_text())
    if hashes(base/'source')!=before:raise ValueError('Frozen baseline changed')
    run=fpga/'build/full_integration_20261013'/datetime.now().strftime('metadata_broadcast_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source',run/'source')
    name='rtl/memory/frame_pool_bank.sv';path=run/'source'/name;original=path.read_text()
    text=replace_once(original,' wire [IMMUTABLE_META_BITS-1:0] consumer_immutable[0:3];',
        ''' // One complete bus is qualified by each consumer's ACK. Multi-slot
 // arbitration admits one consumer; one-slot simultaneous ACKs all name slot0.
 wire [IMMUTABLE_META_BITS-1:0] accepted_immutable;
 wire [1:0] accepted_metadata_slot;''')
    text=replace_once(text,'''     // Restore the exact packed ABI around separately updated mutable fields.
     // Mutable fields are sampled at ACK; immutable payload was fetched
     // earlier and its exact generation/slot revalidated before this ACK.
     acq_meta[META_BITS*c+:META_BITS]=expand_metadata(consumer_immutable[c],
      capture_last[selected[c]],metadata_errors[selected[c]]);''',
        '''     // The validated descriptor is reconstructed once below. Slot and
     // generation remain consumer-specific and have their original qualifiers.''')
    text=replace_once(text,'''  rsp[`FM_RSP_ACQUIRE_OK]=acq_ok; rsp[`FM_RSP_ACQUIRE_SLOTS]=acq_slots;''',
        '''  // All accepted consumers reference this same immutable payload and
  // mutable slot. Inactive lanes may mirror it and must never be consumed
  // without acquire_ok; no-ACK and fabric quarantine still expose zeros.
  if(|acq_ok)acq_meta={4{expand_metadata(accepted_immutable,
    capture_last[accepted_metadata_slot],metadata_errors[accepted_metadata_slot])}};
  rsp[`FM_RSP_ACQUIRE_OK]=acq_ok; rsp[`FM_RSP_ACQUIRE_SLOTS]=acq_slots;''')
    text=replace_once(text,'''  // Invalid addresses remain unknown internally, as in the original array;
  // existing ownership/SEAL validity gates exclude them from all responses.
  genvar single_consumer;
  for(single_consumer=0;single_consumer<4;single_consumer=single_consumer+1) begin : consumer_read
   assign consumer_immutable[single_consumer]=(selected[single_consumer]==0)?
    held_descriptor:{IMMUTABLE_META_BITS{1'bx}};
  end''',
        '''  // Every accepted consumer of a one-slot bank necessarily owns slot0.
  // Keep the complete payload shared; the public ACK masks invalid storage.
  assign accepted_immutable=held_descriptor;
  assign accepted_metadata_slot=0;''')
    text=replace_once(text,'''  genvar shared_consumer;
  for(shared_consumer=0;shared_consumer<4;shared_consumer=shared_consumer+1) begin : consumer_read
   assign consumer_immutable[shared_consumer]=read_payload;''',
        '''  assign accepted_immutable=read_payload;
  assign accepted_metadata_slot=fetch_slot;
  genvar shared_consumer;
  for(shared_consumer=0;shared_consumer<4;shared_consumer=shared_consumer+1) begin : consumer_read''')
    if 'consumer_immutable' in text:raise ValueError('Old descriptor path remains')
    path.write_text(text)
    (run/'original_frame_pool_bank.sv').write_text(original)
    pkg=run/'source/rtl/memory/frame_manager_pkg.sv'
    pkg.write_text(replace_once(pkg.read_text(),'''  logic [4*META_BITS-1:0] acquire_meta;''',
        '''  // Each metadata lane is valid only with its acquire_ok bit. An
  // inactive lane may mirror another accepted lane; no ACK exposes all zeros.
  logic [4*META_BITS-1:0] acquire_meta;'''))
    after=hashes(run/'source');changed={n for n in before if before[n]!=after[n]}
    if changed!={name,'rtl/memory/frame_manager_pkg.sv'}:raise ValueError('Unexpected changes')
    (run/'sources.json').write_text(json.dumps(after,indent=2))
    (run/'preparation.json').write_text(json.dumps(dict(baseline=str(base),candidate=str(run),changed=sorted(changed),
        functional_pass=False,cycle_equivalent=False,programmed=False,
        semantics='Only inactive metadata lanes while another lane ACKs may differ; every valid descriptor and ownership handshake must match'),indent=2))
    shutil.copyfile(__file__,run/'preparation_script.py');print(run,flush=True)


if __name__=='__main__':
    main()

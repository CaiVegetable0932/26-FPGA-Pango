"""Compose the verified fixed-lane packer with the earlier DMA candidate.

Keep that baseline's asynchronous descriptor storage and all frame ownership
semantics. This isolates the packer benefit from the later metadata DRM changes;
resource and routing benefit still require fresh native evidence.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
from prepare_address_timing_repair import hashes


def main():
    """Freeze a one-file composition and bind every reusable proof input."""
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline', type=Path, required=True)
    parser.add_argument('--pack-candidate', type=Path, required=True)
    parser.add_argument('--additional-proof', type=Path, action='append', default=[])
    args = parser.parse_args()
    fpga = Path(__file__).resolve().parents[1]
    base, pack = args.baseline.resolve(), args.pack_candidate.resolve()
    if not all(p.is_relative_to(fpga/'build') for p in (base, pack)):
        raise ValueError('Frozen FPGA source candidates required')
    before = json.loads((base/'sources.json').read_text())
    if hashes(base/'source') != before:
        raise ValueError('Baseline source changed')
    name = 'rtl/memory/dma_pixel_pack.v'
    # The original packer reference was saved through text I/O. Require equal
    # normalized text, accounting only for CRLF/LF, and retain both byte hashes.
    original = pack/'original_dma_pixel_pack.v'
    if original.read_text() != (base/'source'/name).read_text():
        raise ValueError('Packer proof reference differs from this baseline')
    run = fpga/'build/full_integration_20261013'/datetime.now().strftime('dma_pack_repair_%Y%m%d_%H%M%S_%f')
    shutil.copytree(base/'source', run/'source')
    shutil.copyfile(pack/'source'/name, run/'source'/name)
    for n in ('original_frame_pixel_writer.sv', 'original_geometry_tile_refill.sv', 'original_ddr_native_dma.v'):
        shutil.copyfile(base/n, run/n)
    after = hashes(run/'source')
    if {n for n in before if before[n] != after[n]} != {name}:
        raise ValueError('Unexpected source changes')
    proofs = [pack, *(p.resolve() for p in args.additional_proof)]
    for path in proofs:
        result = json.loads((path/'result.json').read_text())
        if not all(result.get(k) for k in ('passed', 'cycle_equivalent', 'inputs_intact')):
            raise ValueError('Reusable proof did not pass: '+str(path))
        for source, digest in result['inputs'].items():
            source = Path(source)
            if hashlib.sha256(source.read_bytes()).hexdigest() != digest:
                raise ValueError('Reusable proof input changed: '+str(source))
            if '/source/rtl/' in source.as_posix():
                relative = 'rtl/'+source.as_posix().split('/source/rtl/', 1)[1]
                if after.get(relative) != digest:
                    raise ValueError('Reusable proof is not bound to composed RTL: '+relative)
    (run/'sources.json').write_text(json.dumps(after, indent=2)+'\n')
    record = dict(baseline=str(base), pack_candidate=str(pack), changed=[name],
        additional_proofs=[str(p) for p in proofs], reusable_proof_inputs_intact=True,
        reference_text_equal=True, reference_sha256=hashlib.sha256(original.read_bytes()).hexdigest(),
        baseline_pack_sha256=before[name], functional_pass=False,
        main_differential_required=True, full_model_required=True,
        native_synthesis_started=False, programmed=False)
    (run/'preparation.json').write_text(json.dumps(record, indent=2)+'\n')
    shutil.copyfile(__file__, run/'preparation_script.py')
    print(run, flush=True)


if __name__ == '__main__':
    main()

"""Localize the measured wait-statistics timing cone without changing cycles."""
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil


def main():
    """Compare each client's counter locally, then gate its existing grant edge.

    The routed isolated baseline's worst setup cone runs from done[0] through
    chosen and two variable-index 32-bit statistics selectors to other clients'
    max_wait_cycles enables. Parallel local comparisons remove those selectors
    from the grant path; arbitration, counters and visible update edges stay
    unchanged. No telemetry precision is reduced and no extra cycle is added.
    """
    fpga=Path(__file__).resolve().parents[1]
    baseline=fpga/'build/full_integration_20261013/delay_20261019_163458_368603'
    names=json.loads((baseline/'sources.json').read_text(encoding='utf-8'))
    run=fpga/'build/route_optimization'/datetime.now().strftime('dma_local_wait_stats_%Y%m%d_%H%M%S_%f')
    source=run/'source';source.mkdir(parents=True)
    hashes={}
    for name in names:
        dest=source/name;dest.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(fpga/name,dest);hashes[name]=hashlib.sha256(dest.read_bytes()).hexdigest()
    target=source/'rtl/memory/ddr_native_dma.v'
    original=target.read_bytes();(run/'original_ddr_native_dma.v').write_bytes(original)
    text=original.decode('utf-8').replace('\r\n','\n')
    old='''     if(wait_cycles[chosen[CLIENT_BITS-1:0]]>max_wait_cycles[chosen[CLIENT_BITS-1:0]*32+:32])
      max_wait_cycles[chosen[CLIENT_BITS-1:0]*32+:32]<=wait_cycles[chosen[CLIENT_BITS-1:0]];'''
    anchor='''    // Do not withdraw a VALID address, even if cancelled before acceptance.'''
    new='''    // Compare local telemetry before grant selection. Constant client slices
    // avoid a central read/compare/write mux on the arbitration-to-CE path.
    // Read the same pre-edge wait count as the original IDLE grant update.
    if(state==IDLE && chosen==i && !fault && controller_ready && !cancel[i])begin
     if(wait_cycles[i]>max_wait_cycles[i*32+:32])
      max_wait_cycles[i*32+:32]<=wait_cycles[i];
    end
'''
    if text.count(old)!=1 or text.count(anchor)!=1:
        raise ValueError('DMA statistics cone differs from reviewed baseline')
    text=text.replace(old,'').replace(anchor,new+anchor)
    target.write_text(text,encoding='utf-8',newline='\n')
    hashes['rtl/memory/ddr_native_dma.v']=hashlib.sha256(target.read_bytes()).hexdigest()
    (run/'sources.json').write_text(json.dumps(hashes,indent=2),encoding='utf-8')
    (run/'candidate.json').write_text(json.dumps(dict(review_round=2,
        status='FUNCTIONAL_PROOF_REQUIRED_NOT_PROMOTED',
        changed_files=['rtl/memory/ddr_native_dma.v'],extra_latency_cycles=0,
        telemetry_width_preserved=True,arbitration_unchanged=True,
        physical_benefit_verified=False),indent=2),encoding='utf-8')
    shutil.copyfile(__file__,run/'prepare_script.py')
    print('DMA_LOCAL_WAIT_STATS',run)


if __name__=='__main__':main()

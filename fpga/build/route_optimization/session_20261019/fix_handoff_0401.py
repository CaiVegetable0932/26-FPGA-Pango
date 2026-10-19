"""Update current queue text in place while read-only GUI observers are open."""
from pathlib import Path
ROOT=Path(__file__).resolve().parents[4]
p=ROOT/'fpga/reports/route_optimization_handoff_20261020.md'
text=p.read_text(encoding='utf-8')
old=next(line for line in text.splitlines() if line.startswith('1. 先查真实账户额度'))
new='1. 先查真实账户额度、`native_phase.lock`和各运行的result/monitor，保持单PDS。writer三个seed已全部通过并合入；当前PDS为帧池8位计数候选的区域A/B，见其screen下最新regional_route。'
p.write_text(text.replace(old,new),encoding='utf-8',newline='\n')
# The mapped design must use the exact prefetched bridge from its functional
# proof, in addition to the adapter and original read bridge bindings.
p=ROOT/'fpga/scripts/probe_processing_domain_mapping.py';text=p.read_text(encoding='utf-8')
old="    run=fpga/'build/route_optimization'/datetime.now().strftime('proc150_mapping_%Y%m%d_%H%M%S_%f')"
new="""        if 'dma_read_cdc_prefetch.sv' in hashes and sha(integrated/'source/rtl/memory/dma_read_cdc_prefetch.sv')!=hashes['dma_read_cdc_prefetch.sv']:
            raise ValueError('Integration prefetch bridge mismatch')
"""+old
assert text.count(old)==1;p.write_text(text.replace(old,new),encoding='utf-8',newline='\n')

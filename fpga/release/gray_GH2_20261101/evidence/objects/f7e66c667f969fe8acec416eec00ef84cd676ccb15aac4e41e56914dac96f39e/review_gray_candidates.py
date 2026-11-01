"""Read completed candidate evidence without modifying any native build."""
from pathlib import Path
import argparse
from collections import Counter
import hashlib
import json
import re
from constraint_report import require_native_constraints


def inspect(syn, mapping=None):
    """Separate synthesis estimates and direct entity cells from routed signoff."""
    sha=lambda p:hashlib.sha256(p.read_bytes()).hexdigest()
    result=json.loads((syn/'result.json').read_text())
    manifest=json.loads((syn/'sources.json').read_text())
    if result.get('native_exit')!=0 or result.get('errors'):
        raise ValueError('Synthesis not successful')
    if not all(sha(syn/'source'/n)==h for n,h in manifest.items()):
        raise ValueError('SYN source drift')
    snr=(syn/'synthesize/pango_video_system.snr').read_text(errors='replace')
    resources={}
    for name,pattern in {'LUT':r'Total LUTs:\s*(\d+)','FF':r'Total Registers:\s*(\d+)',
                         'DRM':r'Total DRM =\s*([\d.]+)','APM':r'Total APMs =\s*([\d.]+)'}.items():
        resources[name]=float(re.search(pattern,snr)[1])
    # These are exclusive entity primitive counts, not inclusive module totals
    # or estimates of reclaimable routed resources.
    modules={};name=None
    with (syn/'synthesize/pango_video_system_syn.vm').open() as vm:
        for line in vm:
            found=re.match(r'module (\w+)',line)
            if found:
                n=found[1];name=n if n.startswith(('raw_pose_solver','dma_pixel_pack','raw_dma_reader','dma_byte_unpack')) else None
                if name:modules[name]=Counter()
            elif line.startswith('endmodule'):name=None
            elif name:
                cell=re.match(r'\s*(GTP_\w+)\s',line)
                if cell:modules[name][cell[1]]+=1
    review={'syn':str(syn),'source_count':len(manifest),'sources_intact':True,
            'synthesis_resources':resources,'direct_entity_cells':modules,
            'processing_timing_summary_lines':[line for line in snr.splitlines() if re.match(r'\s*processing_clk\s',line) and 'get_' not in line][:10],
            'synthesis_report_sha256':sha(syn/'synthesize/pango_video_system.snr'),
            'routed_timing_verified':False}
    if mapping:
        mr=json.loads((mapping/'result.json').read_text())
        if mr.get('native_exit')!=0 or mr.get('errors') or not mr.get('syn_intact'):
            raise ValueError('MAP not successful/intact')
        mm=json.loads((mapping/'sources.json').read_text())
        if mm!=manifest or not all(sha(mapping/'source'/n)==h for n,h in mm.items()):
            raise ValueError('MAP source mismatch')
        review['mapping']=str(mapping)
        review['constraints']=require_native_constraints(mapping)
        review['mapped_lut_gate']=mr['mapped_lut_gate']
        # MAP can remove additional registers after SYN. Parse its own DMR
        # table so resource comparisons never pair MAP LUT with SYN FF counts.
        dmr=(mapping/'device_map/pango_video_system.dmr').read_text(errors='replace')
        review['mapping_resources']={
            k:float(re.search(r'^\|\s*'+re.escape(k)+r'\s*\|\s*([\d.]+)',dmr,re.M)[1])
            for k in ('LUT','FF','APM','DRM','Distributed RAM')}
    return review


def main():
    """One bounded read; incomplete stages remain pending and are never guessed."""
    ap=argparse.ArgumentParser(description=__doc__);ap.add_argument('--state',type=Path,required=True)
    ap.add_argument('--out',type=Path,required=True);args=ap.parse_args()
    f=Path(__file__).resolve().parents[1]
    base=inspect(f/'build/full_integration_20261013/board_20261031_013458_351679',
                 f/'build/full_integration_20261013/board_postsyn_20261031_015805_334340')
    state=json.loads(args.state.read_text());review={'baseline':base,'candidates':{}}
    for label,item in state['candidates'].items():
        if 'synthesis' not in item or not (Path(item['synthesis'])/'result.json').exists():
            review['candidates'][label]={'status':'PENDING'};continue
        syn=Path(item['synthesis']);mapping=Path(item['mapping']) if 'mapping' in item else None
        if mapping and not (mapping/'result.json').exists():mapping=None
        r=inspect(syn,mapping)
        r['synthesis_resource_delta_vs_committed']={k:v-base['synthesis_resources'][k] for k,v in r['synthesis_resources'].items()}
        if 'mapping_resources' in r:
            r['mapping_resource_delta_vs_committed']={
                k:v-base['mapping_resources'][k] for k,v in r['mapping_resources'].items()}
        review['candidates'][label]=r
    args.out.parent.mkdir(parents=True,exist_ok=True)
    args.out.write_text(json.dumps(review,indent=2),encoding='utf-8')
    print(args.out)


if __name__=='__main__':main()

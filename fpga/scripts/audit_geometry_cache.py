"""Full-frame calibrated access traces: tile shape/working-set/bus-padding comparison.

This is an offline transaction oracle. Timings derived from service contracts are
budgets, not measured DDR or frame rates. All source/refill bytes remain RGB888.
"""
import argparse
import json
import sys
from pathlib import Path
import numpy as np
FPGA=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(FPGA/'model'))
from isp_geometry import Calibration,map_fixed,TileCacheModel


def main():
    """Feed exactly the same valid-coordinate stream to each cache candidate."""
    p=argparse.ArgumentParser();p.add_argument('--angles',type=float,nargs='+',default=[0,15,45])
    p.add_argument('--replacement',choices=['round_robin','lru'],default='round_robin')
    p.add_argument('--output',default=str(FPGA/'build/isp_geometry/cache_audit.json'))
    p.add_argument('--calibration',default=str(FPGA.parent/'host/reports/rgb33-calibration-20261010/pinhole_k1_k2_p1_p2.json'))
    args=p.parse_args();output=Path(args.output).resolve()
    if not output.is_relative_to(FPGA/'build'):raise ValueError('output must be within fpga/build')
    output.parent.mkdir(parents=True,exist_ok=True);results=[]
    for angle in args.angles:
        c=Calibration.load(args.calibration,angle)
        candidates=[TileCacheModel(c.width,c.height,tile=shape,stride=6144,replacement=args.replacement) for shape in ((16,16),(32,8),(8,32))]
        pixels=0
        # Full 16x16 output-tile traversal, including last partial tile row.
        for by in range(0,c.height,16):
            u,v=np.meshgrid(np.arange(c.width,dtype=np.int64),np.arange(by,min(by+16,c.height),dtype=np.int64))
            qu,qv,mask,_,_=map_fixed(u,v,c)
            for bx in range(0,c.width,16):
                tu=qu[:,bx:bx+16].ravel();tv=qv[:,bx:bx+16].ravel();tm=mask[:,bx:bx+16].ravel()
                pixels+=len(tu)
                for su,sv,valid in zip(tu,tv,tm):
                    if valid:
                        for candidate in candidates:candidate.access(int(su),int(sv))
        for cache in candidates:
            r=dict(angle_deg=angle,tile=[cache.tw,cache.th],slots=128,ways=4,sets=32,replacement=args.replacement,
                   output_pixels=pixels,hit_tile_queries=cache.hits,miss_tile_queries=cache.misses,
                   actual_aligned_bus_bytes=cache.bus_bytes,g=cache.bus_bytes/(3*pixels),duplicate_neighbours=cache.duplicates,
                   rgb888_cache_data_bytes=128*cache.tw*cache.th*3,
                   rgbx32_candidate_data_bytes=128*cache.tw*cache.th*4)
            # Both candidates have the SAME 128 slots, so RGBX padding alone does
            # not improve hit rate. Compare physical RAM mapping via PDS separately.
            results.append(r);print(json.dumps(r),flush=True)
        output.write_text(json.dumps(dict(scope='full-frame offline tile transaction model; no DDR timing proof',
                source=args.calibration,source_sha256=c.source_sha256,source_status=c.source_status,
                source_stride=6144,hardware_tested=False,cases=results),indent=2),encoding='utf-8')


if __name__=='__main__':main()

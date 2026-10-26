"""Compare cache-way capacity on identical full-frame calibrated access traces.

This is an offline byte-count oracle, not measured DDR timing or board FPS.
The output traversal matches the selected 32x8 geometry tiles, including edges.
"""
import argparse
from datetime import datetime
import hashlib
import json
from pathlib import Path
import shutil
import sys
import numpy as np

FPGA = Path(__file__).resolve().parents[1]


def main():
    """Freeze the model/calibration and compare only associativity/capacity."""
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', type=Path, required=True)
    a = p.parse_args()
    candidate = a.candidate.resolve()
    if not candidate.is_relative_to(FPGA/'build/block_pressure_20261025'):
        raise ValueError('Isolated candidate required')
    run = candidate/datetime.now().strftime('cache_trace_%Y%m%d_%H%M%S_%f')
    run.mkdir()
    sources = [FPGA/'model/isp_geometry.py', FPGA.parent/'host/reports/rgb33-calibration-20261010/pinhole_k1_k2_p1_p2.json', Path(__file__)]
    for source in sources:
        shutil.copyfile(source, run/source.name)
    # Probe only the set-index function in a private oracle copy. The original
    # calibration, coordinate map, replacement policy and byte counting remain
    # identical. No production model file is edited by this experiment.
    model = run/'isp_geometry.py'
    text = model.read_text(encoding='utf-8')
    old = 'set_index=(tx ^ ty)%self.sets'
    if text.count(old) != 1:
        raise ValueError('Unexpected cache hash implementation')
    model.write_text(text.replace(old,'set_index=(tx ^ (ty << getattr(self, "hash_shift", 0)))%self.sets'),encoding='utf-8')
    sys.path.insert(0,str(run))
    from isp_geometry import Calibration, map_fixed, TileCacheModel
    hashes = {f.name:hashlib.sha256((run/f.name).read_bytes()).hexdigest() for f in sources}
    result = dict(passed=False, hardware_tested=False, scope='offline aligned-byte comparison; no DDR/FPS signoff', source_hashes=hashes, cases=[])
    print('CACHE_TRACE',run,flush=True)
    try:
        for angle in [0,15,45]:
            c = Calibration.load(run/sources[1].name,angle)
            configurations = [(32,4,0),(32,2,0),(64,2,0),(64,2,1),(64,2,2)]
            caches = []
            for s,w,shift in configurations:
                cache=TileCacheModel(c.width,c.height,tile=(32,8),sets=s,ways=w,stride=6144,replacement='round_robin')
                cache.hash_shift=shift
                caches.append(cache)
            pixels = 0
            for by in range(0,c.height,8):
                u,v = np.meshgrid(np.arange(c.width,dtype=np.int64),np.arange(by,min(by+8,c.height),dtype=np.int64))
                qu,qv,mask,_,_ = map_fixed(u,v,c)
                for bx in range(0,c.width,32):
                    tu,tv,tm = qu[:,bx:bx+32].ravel(),qv[:,bx:bx+32].ravel(),mask[:,bx:bx+32].ravel()
                    pixels += len(tu)
                    for su,sv,valid in zip(tu,tv,tm):
                        if valid:
                            for cache in caches:
                                cache.access(int(su),int(sv))
            row = dict(angle=angle,width=c.width,height=c.height,pixels=pixels,
                four_way=dict(misses=caches[0].misses,bus_bytes=caches[0].bus_bytes),
                two_way=dict(misses=caches[1].misses,bus_bytes=caches[1].bus_bytes),
                bus_ratio=caches[1].bus_bytes/caches[0].bus_bytes,
                two_way_128tile=dict(misses=caches[2].misses,bus_bytes=caches[2].bus_bytes),
                equal_capacity_bus_ratio=caches[2].bus_bytes/caches[0].bus_bytes,
                alternate_hashes=[dict(shift=shift,misses=cache.misses,bus_bytes=cache.bus_bytes,bus_ratio=cache.bus_bytes/caches[0].bus_bytes)
                                  for shift,cache in zip([1,2],caches[3:])])
            result['cases'].append(row)
            print(json.dumps(row),flush=True)
        result['passed'] = True
    finally:
        result['inputs_intact'] = all(hashlib.sha256((run/n).read_bytes()).hexdigest()==h for n,h in hashes.items())
        result['passed'] &= result['inputs_intact']
        (run/'result.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
        print('CACHE_TRACE_RESULT',run,flush=True)


if __name__ == '__main__':
    main()

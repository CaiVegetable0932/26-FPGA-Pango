"""Generate deterministic real-calibration/synthetic golden vectors and full-domain audit.

All outputs belong to fpga/build. Source calibration status/hash are preserved;
this program never treats software precision as an optical/hardware measurement.
"""
import argparse
import hashlib
import json
import math
from pathlib import Path
import sys
import numpy as np
FPGA=Path(__file__).resolve().parents[1]
sys.path.insert(0,str(FPGA/'model'))
from isp_geometry import Calibration,isp_fixed,lens_fixed,map_fixed,map_float,reciprocal_fixed,sample_rgb,TileCacheModel


def packed_coeff(c):
    """Verilog coefficient bus is field zero at the least-significant 32 bits."""
    return sum((x&0xffffffff)<<(32*i) for i,x in enumerate(c.coefficients()))


def main():
    """Chunk whole-domain scans to bound RAM use, then produce RTL stress streams."""
    parser=argparse.ArgumentParser()
    parser.add_argument('--output',default=str(FPGA/'build/isp_geometry/vectors'))
    parser.add_argument('--calibration',default=str(FPGA.parent/'host/reports/rgb33-calibration-20261010/pinhole_k1_k2_p1_p2.json'))
    args=parser.parse_args();out=Path(args.output).resolve()
    if not out.is_relative_to(FPGA/'build'):raise ValueError('outputs must remain within fpga/build')
    out.mkdir(parents=True,exist_ok=True);rng=np.random.default_rng(61012)
    cases=[Calibration.load(args.calibration,a) for a in (0,15,-15,45,90)]
    audit=[]
    for angle,c in zip((0,15,-15,45,90),cases):
        square_sum=0.0;count=0;maximum=0.0;overflow=0;mask_difference=0;stage_ranges={}
        for start in range(0,c.height,16):
            u,v=np.meshgrid(np.arange(c.width,dtype=np.int64),np.arange(start,min(c.height,start+16),dtype=np.int64))
            fu,fv=map_float(u,v,c);qu,qv,mask,ok,stages=map_fixed(u,v,c)
            domain=(fu>=0)&(fv>=0)&(fu<=c.width-1)&(fv<=c.height-1)
            error=np.hypot(qu/4096-fu,qv/4096-fv)
            square_sum+=float(np.sum(error[domain]**2));count+=int(np.sum(domain));maximum=max(maximum,float(np.max(error[domain],initial=0)))
            overflow+=int(np.sum(~ok));mask_difference+=int(np.sum(domain!=mask))
            for name,value in stages.items():
                lo,hi=int(np.min(value)),int(np.max(value))
                old=stage_ranges.get(name,(lo,hi));stage_ranges[name]=(min(old[0],lo),max(old[1],hi))
        row=dict(angle_deg=angle,full_pixels=c.width*c.height,valid_float_pixels=count,rms_px=math.sqrt(square_sum/count),max_px=maximum,
                 overflow_pixels=overflow,mask_difference_pixels=mask_difference,stage_integer_ranges=stage_ranges)
        row['passed']=row['rms_px']<=.05 and maximum<=.25 and overflow==0
        audit.append(row)
    # Lens pipeline golden stresses all angles, borders, saturation and random stalls.
    with (out/'lens.txt').open('w') as f:
        for c in cases:
            a=c.coefficients()[:6]
            for n in range(1500):
                u,v=(int(rng.integers(c.width)),int(rng.integers(c.height)))
                x=((a[0]*u+a[1]*v+a[2])+32)>>6;y=((a[3]*u+a[4]*v+a[5])+32)>>6
                qu,qv,mask,ok,_=lens_fixed(np.int64(x),np.int64(y),c)
                f.write(f'{packed_coeff(c):0112x} {x&0xffffff:06x} {y&0xffffff:06x} {int(qu)&0xfffffff:07x} {int(qv)&0xfffffff:07x} {int(mask)} {int(ok)}\n')
    # RAW captures are deterministic SYNTHETIC evidence. Parameters cover all phases,
    # two-pixel borders, odd widths and gain/black extremes; frame-by-frame files.
    isp_cases=[]
    for index,(w,h,phase) in enumerate([(w,h,p) for p in range(4) for w,h in [(2,2),(9,7),(16,8)]]+[(9,7,0),(9,7,3)]):
        black=tuple(int(x) for x in rng.integers(0,65,4));gains=tuple(int(x) for x in rng.integers(1024,18000,4))
        if index==12:black=(255,)*4;gains=(65535,)*4
        if index==13:black=(0,)*4;gains=(0,65535,65535,0)
        raw=rng.integers(0,256,(h,w),dtype=np.uint8);gold=isp_fixed(raw,phase,black,gains)
        raw.tofile(out/f'isp_{index}.raw');gold.tofile(out/f'isp_{index}.rgb')
        with (out/f'isp_{index}.txt').open('w') as f:
            for r,p in zip(raw.flatten(),gold.reshape(-1,3)):f.write(f'{int(r):02x} {int.from_bytes(bytes(p),"big"):06x}\n')
        isp_cases.append(dict(width=w,height=h,bayer=phase,black=black,gains=gains,synthetic=True))
    (out/'isp_cases.txt').write_text('\n'.join(f'{c["width"]} {c["height"]} {c["bayer"]} '+f'{sum(x<<(8*i) for i,x in enumerate(c["black"])):08x} '+f'{sum(x<<(16*i) for i,x in enumerate(c["gains"])):016x}' for c in isp_cases)+'\n')
    # Same nonlinear curve used by pre/post reference; masks must override lut[0].
    lut=np.array([math.floor(255*(i/255)**.7+.5) for i in range(256)],dtype=np.uint8)
    (out/'gamma.hex').write_text('\n'.join(f'{int(x):02x}' for x in lut)+'\n')
    with (out/'enhance.txt').open('w') as f:
        for mode in range(3):
            for n in range(600):
                samples=rng.integers(0,256,(4,3),dtype=np.uint8);a,b=map(int,rng.integers(0,4096,2));mask=n%11!=0
                # 2x2 image samples arrange P00,P10,P01,P11 in raster order.
                gold,_=sample_rgb(samples.reshape(2,2,3),a,b,mode,lut)
                if not mask:gold[:]=0
                bus=sum(int.from_bytes(bytes(p),'big')<<(24*i) for i,p in enumerate(samples))
                f.write(f'{mode} {bus:024x} {a:03x} {b:03x} {int(mask)} {int.from_bytes(bytes(gold),"big"):06x}\n')
    # Projective normalization golden, including rejected depths and representable boundaries.
    with (out/'perspective.txt').open('w') as f:
        for n in range(2500):
            den=int(rng.integers(16384,(1<<35)))
            if n<8:den=(0,-1,16383,16384,1<<26,(1<<39)-1,65535,1<<30)[n]
            q0=int(rng.integers(-(1<<29),1<<29));q1=int(rng.integers(-(1<<29),1<<29))
            # Q34 exponent recovery feeds full 88-bit products in the RTL;
            # shift 40 returns Q20 rays with the same positive-half rounding.
            inv,ok=reciprocal_fixed(den);x=(q0*inv+(1<<39))>>40;y=(q1*inv+(1<<39))>>40
            ok=ok and -(1<<23)<=x<(1<<23) and -(1<<23)<=y<(1<<23)
            f.write(f'{q0&((1<<40)-1):010x} {q1&((1<<40)-1):010x} {den&((1<<40)-1):010x} {x&0xffffff:06x} {y&0xffffff:06x} {int(ok)}\n')
    result=dict(scope='software arithmetic, full 1080p domain; no optical/board/PnR claims',source=str(Path(args.calibration).resolve()),
                source_sha256=cases[0].source_sha256,source_status=cases[0].source_status,isp_cases=isp_cases,coordinate_cases=audit,
                passed=all(r['passed'] for r in audit),hardware_tested=False)
    (out/'model_audit.json').write_text(json.dumps(result,indent=2),encoding='utf-8')
    print(json.dumps({k:v for k,v in result.items() if k not in ('isp_cases',)},indent=2))
    if not result['passed']:raise SystemExit('coordinate error/overflow requirements failed')


if __name__=='__main__':main()

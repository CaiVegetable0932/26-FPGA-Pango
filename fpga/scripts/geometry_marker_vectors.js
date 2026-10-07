/* Purpose: derive independent golden coordinates/colors directly from the
 * canonical browser API. Outputs are simulation vectors, not uploaded FPGA maps. */
const fs=require('fs'),path=require('path');
const api=require('../../host/web/fisheye-preview.js');
const target=process.argv[2];
const p=api.preset(),f=1920/(2*Math.tan(p.output_fov_deg*Math.PI/360));
const words=[1/f,0,-959.5/f,0,1/f,-539.5/f,p.k1,p.k2,p.k3,p.k4,p.fx,p.fy,p.cx,p.cy];
const hex=n=>(BigInt(n)&0xffffffffn).toString(16).padStart(8,'0');
fs.writeFileSync(path.join(target,'marker_words.hex'),words.map((v,i)=>hex(Math.round(v*2**(i<10?26:16)))).join('\n')+'\n');
const rows=api.markerPixels(1920,1080).map(m=>{
 const dest=api.destinationPoint(p,1920,1080,...m.point);
 return [m.point[0],m.point[1],parseInt(m.color.slice(1),16),
   dest.point?Math.round(dest.point[0]*4096):-2147483648,
   dest.point?Math.round(dest.point[1]*4096):-2147483648,+dest.visible].map(hex).join('\n');
});
fs.writeFileSync(path.join(target,'marker_golden.hex'),rows.join('\n')+'\n');
console.log('MARKER_REFERENCE_GENERATED canonical JS pixels/colors and analytic fisheye');

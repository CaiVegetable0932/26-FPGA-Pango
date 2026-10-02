/* Numeric regression for manual software-reference mapping. Run with Node;
 * sampled coordinates are additionally checked against OpenCV in Python. */
"use strict";
const assert=require("node:assert/strict");
const fs=require("node:fs"),path=require("node:path");
const m=require("../web/fisheye-preview.js");
function close(actual,expected,tolerance=1e-10){assert.ok(Math.abs(actual-expected)<tolerance,`${actual} != ${expected}`);}

// Purpose: preserve center coordinates across capture-card resolution changes,
// and distinguish an equidistant zero-D model from pinhole identity mapping.
const p=m.normalize(m.preset("equidistant200"));
const k=m.scaledIntrinsics(p,1280,720);
close(k.cx,639.5);close(k.cy,359.5);
const center=m.sourcePoint(p,1280,720,639.5,359.5);
close(center[0],k.cx);close(center[1],k.cy);
const left=m.sourcePoint(p,1280,720,0,359.5),right=m.sourcePoint(p,1280,720,1279,359.5);
close(left[0]+right[0],1279);close(left[1],359.5);
assert.ok(Math.abs(left[0])>1);
const decentered=m.sourcePoint({...p,cx:p.cx+30},1280,720,639.5,359.5);
close(decentered[0]-center[0],20);
const changed=m.sourcePoint({...p,k1:0.03,fx:p.fx*1.1},1280,720,1279,719);
assert.ok(Math.abs(changed[0]-m.sourcePoint(p,1280,720,1279,719)[0])>10);

// Purpose: incomplete, folded, incompatible or degenerate inputs must never
// silently render a prior setting as though the new value had been accepted.
for(const patch of [{fx:0},{fy:NaN},{reference_width:1},{reference_height:1080.5},
  {output_fov_deg:200},{model:"pinhole_k1_k2_p1_p2"},{k1:-2},{k4:Infinity}])
  assert.throws(()=>m.normalize({...p,...patch}));
for(const name of ["user-reviewed200","equidistant200","equidistant180","equisolid200"])
  assert.doesNotThrow(()=>m.normalize(m.preset(name)));
const exported=m.exportSettings(p);
assert.equal(exported.fpga_compatible,false);assert.equal(exported.source_frame_id,null);
assert.equal(exported.parameters_origin,"manual_approximate");
assert.deepEqual(m.normalize(JSON.parse(JSON.stringify(exported)).parameters),p);

// Purpose: freeze the user's full screenshot settings, including asymmetric
// optics and output FOV, and prevent drift between defaults and importable JSON.
const reviewed=m.normalize(m.preset());
assert.deepEqual(reviewed,{model:"fisheye_equidistant",reference_width:1920,reference_height:1080,
  fx:770,fy:752,cx:945,cy:553,k1:0.121,k2:-0.118,k3:0,k4:0.036,output_fov_deg:139});
const config=JSON.parse(fs.readFileSync(path.join(__dirname,"../config/calibration/fisheye-user-reviewed-20261002.json"),"utf8"));
assert.deepEqual(m.normalize(config.parameters),reviewed);
assert.throws(()=>m.preset("missing"));

// Purpose: return independent reference points for OpenCV cross-validation,
// including asymmetric principal point, nonzero high-order terms and corners.
if(process.argv.includes("--coordinates")){
  const configs=[p,reviewed,m.normalize({...p,fx:640,fy:610,cx:972,cy:535,k1:0.03,k2:-0.002,k3:0.0001,k4:-0.000001}),m.normalize(m.preset("equisolid200"))];
  const points=[[0,0],[1279,0],[0,719],[1279,719],[639.5,359.5],[100,300],[1000,600]];
  console.log(JSON.stringify(configs.map(parameters=>({parameters,width:1280,height:720,
    points:points.map(output=>({output,source:m.sourcePoint(parameters,1280,720,...output)}))}))));
}else console.log("PASS fish-eye presets, pixel centers, asymmetric optics, input rejection and reference-only export");

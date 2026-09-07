/* Dependency-free pixel tests. Run: node host/tests/test_pixels.cjs */
"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),crypto=require("node:crypto");
const {renderPixels}=require("../web/pixels.js");
const results=[];
function test(name,fn){try{fn();results.push({name,passed:true});}catch(error){results.push({name,passed:false,error:String(error.stack)});}}
function render(values,meta={},mode="color"){
  return renderPixels(Uint8Array.from(values).buffer,{width:2,height:2,row_stride:2,pixel_format:"RAW8",bayer_code:1,...meta},mode);
}
for(const [code,values] of [[1,[200,40,60,10]],[2,[40,200,10,60]],[3,[40,10,200,60]],[4,[10,40,60,200]]]){
  test("RAW8 Bayer layout "+code,()=>assert.deepEqual([...new Uint8ClampedArray(render(values,{bayer_code:code}).pixels)],[200,50,10,255]));
}
test("Full-scale small RAW grayscale preserves samples",()=>assert.deepEqual(
  [...new Uint8ClampedArray(render([1,2,3,4],{},"gray").pixels)],[1,1,1,255,2,2,2,255,3,3,3,255,4,4,4,255]));
test("1080p Bayer downscale has independent color cell averages",()=>{
  const bytes=new Uint8Array(1920*1080);
  for(let y=0;y<1080;y++)for(let x=0;x<1920;x++)bytes[y*1920+x]=y%2?(x%2?10:60):(x%2?40:200);
  const meta={width:1920,height:1080,row_stride:1920,pixel_format:"RAW8",bayer_code:1};
  const color=renderPixels(bytes.buffer,meta,"color"),gray=renderPixels(bytes.buffer,meta,"gray");
  assert.equal(color.width,960);assert.equal(color.height,540);
  assert.deepEqual([...new Uint8ClampedArray(color.pixels).slice(0,4)],[200,50,10,255]);
  assert.deepEqual([...new Uint8ClampedArray(gray.pixels).slice(0,4)],[77,77,77,255]);
});
test("RGB888 order and integer grayscale",()=>{
  const rgb=render([255,0,0,0,255,0],{width:2,height:1,row_stride:6,pixel_format:"RGB888"});
  assert.deepEqual([...new Uint8ClampedArray(rgb.pixels)],[255,0,0,255,0,255,0,255]);
  const gray=render([255,0,0],{width:1,height:1,row_stride:3,pixel_format:"RGB888"},"gray");
  assert.deepEqual([...new Uint8ClampedArray(gray.pixels)],[77,77,77,255]);
});
test("Corrupt lengths, strides, dimensions, formats, and Bayer are rejected",()=>{
  for(const [bytes,meta] of [[[1,2],{}],[[1,2,3,4],{row_stride:3}],[[1],{width:0}],[[1,2,3,4],{bayer_code:0}],[[1,2,3,4],{pixel_format:"JPEG"}]]){
    assert.throws(()=>render(bytes,meta));
  }
});
test("Wider RAW preview remains bounded to 960 columns",()=>{
  const result=renderPixels(new ArrayBuffer(4096*4),{width:4096,height:4,row_stride:4096,pixel_format:"RAW8",bayer_code:1});
  assert.ok(result.width<=960);
  assert.equal(result.height,1);
});
const root=path.resolve(__dirname,".."),hashes={};
for(const file of ["web/pixels.js","web/preview-worker.js","web/app.js","web/index.html","web/app.css"]){
  hashes[file]=crypto.createHash("sha256").update(fs.readFileSync(path.join(root,file))).digest("hex");
}
const report={utc:new Date().toISOString(),node:process.version,platform:process.platform,tests_run:results.length,
  passed:results.every(r=>r.passed),browser_ui_qa:"not_performed",results,source_sha256:hashes};
fs.mkdirSync(path.join(root,"reports"),{recursive:true});
fs.writeFileSync(path.join(root,"reports/webui-frontend-tests.json"),JSON.stringify(report,null,2)+"\n");
for(const result of results)console.log((result.passed?"PASS ":"FAIL ")+result.name+(result.error?"\n"+result.error:""));
process.exitCode=report.passed?0:1;

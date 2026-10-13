/* Native RAW must bypass expansion only where reference pixels are unchanged. */
"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const {directPlan}=require("../web/preview-renderer.js");
test("1080p RAW preserves all four Bayer layouts as one-channel native texels",()=>{
  const bytes=new Uint8Array(1920*1080);
  for(const bayer_code of [1,2,3,4,0]){
    const meta={width:1920,height:1080,row_stride:1920,pixel_format:"RAW8",bayer_code};
    assert.deepEqual(directPlan(bytes,meta,"raw",1920),{width:1920,height:1080,kind:"GRAY8"});
    assert.equal(directPlan(bytes,meta,"raw",1919),null);
    assert.equal(directPlan(bytes,meta,"color",1920),null);
    assert.equal(directPlan(bytes,meta,"gray",1920),null);
  }
});
test("Bad lengths, strides and modes fail before submitting a texture",()=>{
  const meta={width:2,height:2,row_stride:2,pixel_format:"RAW8"};
  assert.throws(()=>directPlan(new Uint8Array(3),meta,"raw"));
  assert.throws(()=>directPlan(new Uint8Array(4),{...meta,row_stride:3},"raw"));
  assert.throws(()=>directPlan(new Uint8Array(4),meta,"invalid"));
});

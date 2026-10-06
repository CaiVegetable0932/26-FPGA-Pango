/* Framing-only tests: no mock footage, camera or hardware throughput claims. */
"use strict";
const assert=require("node:assert/strict"),{createDecoder}=require("../web/preview-stream.js");
function frame(id,bytes){
  const meta=Buffer.from(JSON.stringify({frame_id:String(id),pixel_format:"GRAY8"}));
  const head=Buffer.alloc(8);head.writeUInt32LE(meta.length);head.writeUInt32LE(bytes.length,4);
  return Buffer.concat([head,meta,Buffer.from(bytes)]);
}
const stream=Buffer.concat([frame(1,[1,2,3,4]),frame(2,[9,8])]);
// Every split includes boundaries inside lengths, UTF-8 metadata and pixels.
for(let split=1;split<stream.length;split++){
  const output=[],reader=createDecoder(job=>output.push([job.meta.frame_id,[...new Uint8Array(job.buffer)]]));
  reader.push(stream.subarray(0,split));reader.push(stream.subarray(split));reader.finish();
  assert.deepEqual(output,[["1",[1,2,3,4]],["2",[9,8]]]);
}
const byteReader=createDecoder(()=>{});for(const byte of stream)byteReader.push(Uint8Array.of(byte));byteReader.finish();
for(const [meta,pixels] of [[0,1],[4097,1],[1,0],[1,8388609]]){
  const head=Buffer.alloc(8);head.writeUInt32LE(meta);head.writeUInt32LE(pixels,4);
  assert.throws(()=>createDecoder(()=>{}).push(head),/帧长度/);
}
const partial=createDecoder(()=>{});partial.push(stream.subarray(0,stream.length-1));assert.throws(()=>partial.finish(),/中途结束/);
console.log("PASS binary preview framing: all split boundaries, limits, truncated frames");

/* Real worker credit/ACK ownership; no hardware or GPU performance claim. */
"use strict";
const {test}=require('node:test'),assert=require('node:assert/strict'),fs=require('node:fs'),vm=require('node:vm');
const parser=require('../web/preview-stream.js'),renderer=require('../web/preview-renderer.js');
function fixture(){
  let clock=0;const sockets=[],posts=[];
  class Socket{
    static OPEN=1;
    constructor(){this.readyState=0;this.sent=[];sockets.push(this);}
    send(value){this.sent.push(JSON.parse(value));}
    close(){this.readyState=3;this.onclose?.();}
    open(){this.readyState=1;this.onopen();}
    frame(key){
      const meta=Buffer.from(JSON.stringify({run_id:'r',key,width:4,height:4,row_stride:4,pixel_format:'RAW8',bayer_code:4}));
      const bytes=new Uint8Array(8+meta.length+16),head=new DataView(bytes.buffer);
      head.setUint32(0,meta.length,true);head.setUint32(4,16,true);bytes.set(meta,8);
      this.onmessage({data:bytes.buffer});
    }
  }
  const root={location:{href:'http://127.0.0.1:8765/preview-worker.js'},postMessage:value=>posts.push(value),
    PangoPreviewStream:parser,PangoPreviewRenderer:{...renderer,create:()=>({lost:()=>false,draw(){}})}};
  const context=vm.createContext({self:root,importScripts(){},URL,WebSocket:Socket,AbortController,
    performance:{now:()=>clock,timeOrigin:1000},setTimeout,Uint8Array,OffscreenCanvas:class{
      transferToImageBitmap(){return {close(){}};}
    }});
  vm.runInContext(fs.readFileSync(require.resolve('../web/preview-worker.js'),'utf8'),context);
  root.onmessage({data:{type:'init-live',bitmap:true,pull:true}});
  const start=generation=>root.onmessage({data:{type:'start-live',mode:'raw',scale:2,displayWidth:640,run_id:'r',generation}});
  const ack=generation=>root.onmessage({data:{type:'preview-painted',generation}});
  return {root,sockets,posts,start,ack,advance:ms=>{clock+=ms;},bitmaps:()=>posts.filter(p=>p.bitmap)};
}
test('One prefetched RAW overlaps paint, while another bitmap waits for ACK',()=>{
  const f=fixture();f.start(1);const s=f.sockets[0];s.open();assert.equal(s.sent.length,1);
  s.frame('1');assert.equal(f.bitmaps().length,1);assert.equal(s.sent.length,2);
  s.frame('2');assert.equal(f.bitmaps().length,1);assert.equal(s.sent.length,2);
  const queue=f.posts.filter(p=>p.type==='preview-queue').at(-1);
  assert.equal(queue.executing,1);assert.equal(queue.pending,1);assert.equal(queue.pendingBytes,16);
  f.ack(1);assert.equal(f.bitmaps().length,2);assert.equal(s.sent.length,3);
  s.frame('3');assert.equal(f.bitmaps().length,2);assert.equal(s.sent.length,3);
  f.root.onmessage({data:{type:'stop-live'}});
});
test('Late RAW is discarded before GPU work and next credit uses its source key',()=>{
  const f=fixture();f.start(1);const s=f.sockets[0];s.open();s.frame('1');s.frame('2');
  f.advance(101);f.ack(1);assert.equal(f.bitmaps().length,1);assert.equal(s.sent.at(-1).after,'2');
  s.frame('3');assert.equal(f.bitmaps().length,2);assert.equal(f.bitmaps().at(-1).meta.key,'3');
  assert.equal(f.bitmaps().at(-1).previewDroppedBeforeGpu,1);
  f.root.onmessage({data:{type:'stop-live'}});
});
test('Stop drops old pending RAW; a late ACK cannot release a new generation',async()=>{
  const f=fixture();f.start(1);const old=f.sockets[0];old.open();old.frame('1');old.frame('2');
  f.root.onmessage({data:{type:'stop-live'}});f.start(2);const current=f.sockets[1];current.open();current.frame('3');current.frame('4');
  f.ack(1);assert.equal(f.bitmaps().length,2);assert.equal(current.sent.length,2);
  f.ack(2);assert.equal(f.bitmaps().length,3);assert.equal(f.bitmaps().at(-1).meta.key,'4');
  f.root.onmessage({data:{type:'stop-live'}});await new Promise(resolve=>setImmediate(resolve));
});

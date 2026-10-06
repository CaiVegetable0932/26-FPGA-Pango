/* Bounded incremental framing for a single local binary preview connection. */
(function(root){
  "use strict";
  function createDecoder(onFrame,now=()=>performance.now()){
    let part="header",buffer=new Uint8Array(8),used=0,meta=null,payloadBytes=0,started=now();
    const decoder=new TextDecoder();
    function push(chunk){
      let offset=0;
      while(offset<chunk.length){
        if(part==="header"&&used===0)started=now();
        const amount=Math.min(buffer.length-used,chunk.length-offset);
        buffer.set(chunk.subarray(offset,offset+amount),used);used+=amount;offset+=amount;
        if(used!==buffer.length)continue;
        if(part==="header"){
          const header=new DataView(buffer.buffer),metaBytes=header.getUint32(0,true);
          payloadBytes=header.getUint32(4,true);
          if(!metaBytes||metaBytes>4096||!payloadBytes||payloadBytes>8388608)throw Error("非法预览帧长度");
          part="meta";buffer=new Uint8Array(metaBytes);used=0;
        }else if(part==="meta"){
          meta=JSON.parse(decoder.decode(buffer));part="pixels";buffer=new Uint8Array(payloadBytes);used=0;
        }else{
          onFrame({buffer:buffer.buffer,meta,fetchMs:now()-started});
          part="header";buffer=new Uint8Array(8);used=0;meta=null;
        }
      }
    }
    return {push,finish(){if(part!=="header"||used)throw Error("预览连接在帧中途结束");}};
  }
  const api={createDecoder};root.PangoPreviewStream=api;
  if(typeof module!=="undefined")module.exports=api;
})(typeof self!=="undefined"?self:globalThis);

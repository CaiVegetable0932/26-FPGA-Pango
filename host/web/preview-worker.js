importScripts("/pixels.js","/preview-renderer.js","/preview-stream.js");
// A live bitmap keeps both pixel conversion and canvas uploads off the main
// thread. Archives and browsers without bitmap support retain the byte path.
let liveSurface=null,gpu=null,liveContext=null,bitmapMode=false;
let pullController=null,pullGeneration=0,pendingGrant=null;
function prepareSurface(){
  liveSurface=new OffscreenCanvas(1,1);
  try{gpu=self.PangoPreviewRenderer.create(liveSurface);}catch{gpu=null;}
  if(!gpu){liveSurface=new OffscreenCanvas(1,1);liveContext=liveSurface.getContext("2d",{alpha:false});}
}
function render(job){
  const {buffer,meta,mode,target,displayWidth,fetchMs,queueMs,generation,postedEpochMs}=job;
  // Worker scheduling delay is measured in the browser epoch domain only.
  const workerWaitMs=Number.isFinite(postedEpochMs)?Math.max(0,performance.timeOrigin+performance.now()-postedEpochMs):null;
  try{
    const start=performance.now();
    // Purpose: let pure pixel conversion choose Bayer-cell anti-aliasing only
    // when the live canvas will be displayed smaller than the sensor frame.
    // Source metadata stays native 1080p; only explicit derivative geometry
    // describes the smaller display payload. It never rewrites source identity.
    const renderMeta=meta.preview_derivative?{...meta,width:meta.preview_width,height:meta.preview_height,
      row_stride:meta.preview_row_stride,pixel_format:meta.preview_pixel_format}:meta;
    if(bitmapMode&&target==="live"){
      if(gpu?.lost()){
        prepareSurface();
      }
      // A validated native RAW sample maps to one grayscale texel. Color,
      // weighted RGB gray and reduced Bayer still retain the reference math.
      const bytes=new Uint8Array(buffer),direct=gpu?
        self.PangoPreviewRenderer.directPlan(bytes,renderMeta,mode,displayWidth):null;
      const result=direct||
        self.PangoPixels.renderPixels(buffer,renderMeta,mode,{displayWidth});
      const convertMs=performance.now()-start,paintStart=performance.now();
      if(gpu)gpu.draw(direct?bytes:new Uint8Array(result.pixels),result.width,result.height,direct?direct.kind:"RGBA8888");
      else{
        if(liveSurface.width!==result.width)liveSurface.width=result.width;
        if(liveSurface.height!==result.height)liveSurface.height=result.height;
        liveContext.putImageData(new ImageData(new Uint8ClampedArray(result.pixels),result.width,result.height),0,0);
      }
      const output={width:result.width,height:result.height,meta,target,mode,fetchMs,queueMs,workerWaitMs,generation,convertMs,
        workerPaintMs:performance.now()-paintStart,renderer:gpu?"worker-webgl":"worker-2d",
        previewDroppedBeforeGpu:job.previewDroppedBeforeGpu||0,
        uploadBytes:gpu?(direct?bytes.byteLength:result.pixels.byteLength):0,
        directTexture:!!direct};
      // Bitmap export may synchronize the driver even when draw submission
      // was cheap. Measure it separately from GL calls and UI delivery delay.
      const bitmapStart=performance.now(),bitmap=liveSurface.transferToImageBitmap();
      self.postMessage({...output,bitmap,bitmapTransferMs:performance.now()-bitmapStart,
        bitmapPostedEpochMs:performance.timeOrigin+performance.now()},[bitmap]);return output;
    }
    const result=self.PangoPixels.renderPixels(buffer,renderMeta,mode,{displayWidth});
    // Stage timings support real browser bottleneck checks, independent of
    // the frame-rate badges and without modifying original source evidence.
    self.postMessage({...result,meta,target,fetchMs,queueMs,workerWaitMs,generation,convertMs:performance.now()-start},[result.pixels]);
  }catch(error){self.postMessage({error:error.message,target,generation});throw error;}
}
async function pull(config){
  const controller=new AbortController();pullController?.abort();pullController=controller;
  const generation=++pullGeneration;let after="",pending=null,awaitingPaint=false,creditPending=false,droppedBeforeGpu=0,lastQueue="";
  const url=new URL("/api/preview-socket",self.location.href);url.protocol=url.protocol==="https:"?"wss:":"ws:";
  const socket=new WebSocket(url);socket.binaryType="arraybuffer";
  controller.signal.addEventListener("abort",()=>socket.close(),{once:true});
  try{
    await new Promise((resolve,reject)=>{
      let creditStarted=0;
      const active=()=>!controller.signal.aborted&&generation===pullGeneration;
      function reportQueue(){
        // Tiny state-change messages describe this worker's real ownership,
        // rather than misreport its pending RAW as an empty main-thread queue.
        const value={executing:Number(awaitingPaint),pending:Number(!!pending),networkCredit:Number(creditPending),
          pendingBytes:pending?.buffer.byteLength||0},key=JSON.stringify(value);
        if(key!==lastQueue){lastQueue=key;self.postMessage({type:"preview-queue",generation:config.generation,...value});}
      }
      async function grant(){
        if(!active()||socket.readyState!==WebSocket.OPEN||creditPending||pending)return;
        // One network credit overlaps one bitmap owned by the UI. At most one
        // unrendered RAW is held while waiting for its paint acknowledgement.
        creditPending=true;
        creditStarted=performance.now();
        socket.send(JSON.stringify({mode:config.mode,downscale:config.scale,after}));
        reportQueue();
      }
      function consume(job){
        const waited=performance.now()-job.receivedMs;
        // A delayed UI recovers to a fresh source frame instead of painting
        // a prefetched RAW that waited another tenth of a second for ACK.
        if(waited>100){droppedBeforeGpu++;void grant().catch(reject);return;}
        awaitingPaint=true;
        render({...job,mode:config.mode,target:"live",displayWidth:config.displayWidth,
          queueMs:waited,previewDroppedBeforeGpu:droppedBeforeGpu,generation:config.generation});
        pendingGrant={generation:config.generation,grant:()=>{
          if(!active())return;
          awaitingPaint=false;
          if(pending){const next=pending;pending=null;consume(next);}
          else void grant().catch(reject);
        }};
        // Receiving the next RAW need not wait for main-thread scheduling.
        // Rendering waits for ACK, so image bitmaps never queue up.
        void grant().catch(reject);
      }
      socket.onopen=()=>{void grant().catch(reject);};
      socket.onerror=()=>reject(Error("预览通道连接失败"));
      socket.onclose=resolve;
      socket.onmessage=event=>{
        if(!active())return;
        try{
          if(!creditPending)throw Error("未请求的预览响应");
          creditPending=false;
          if(typeof event.data==="string"){
            if(!JSON.parse(event.data).waiting)throw Error("非法预览控制消息");
            setTimeout(()=>{void grant().catch(reject);},100);return;
          }
          let job=null;
          const decoder=self.PangoPreviewStream.createDecoder(value=>{if(job)throw Error("每个额度只允许一帧");job=value;});
          decoder.push(new Uint8Array(event.data));decoder.finish();
          if(!job)throw Error("预览消息缺少完整帧");
          if(job.meta.run_id!==config.run_id){socket.close();return;}
          // Fetch/framing and GPU preparation stay off the main UI thread.
          // The UI acknowledges its final bitmap handoff before a new credit.
          after=job.meta.key;
          const next={...job,receivedMs:performance.now(),fetchMs:performance.now()-creditStarted};
          if(awaitingPaint){pending=next;reportQueue();}
          else consume(next);
        }catch(error){reject(error);}
      };
    });
  }catch(error){if(error.name!=="AbortError"&&generation===pullGeneration)self.postMessage({error:error.message,target:"live",generation:config.generation});}
  finally{pending=null;socket.close();self.postMessage({type:"preview-queue",generation:config.generation,
    executing:0,pending:0,networkCredit:0,pendingBytes:0});self.postMessage({type:"stream-end",generation:config.generation});}
}
self.onmessage=function(event){
  const value=event.data;
  if(value.type==="init-live"){
    bitmapMode=value.bitmap;
    if(bitmapMode)prepareSurface();return;
  }
  if(value.type==="start-live"){void pull(value);return;}
  if(value.type==="stop-live"){pullGeneration++;pendingGrant=null;pullController?.abort();return;}
  if(value.type==="preview-painted"){
    if(pendingGrant&&pendingGrant.generation===value.generation){const grant=pendingGrant.grant;pendingGrant=null;grant();}return;
  }
  try{render(value);}catch{/* Errors were already returned to the owning UI. */}
};

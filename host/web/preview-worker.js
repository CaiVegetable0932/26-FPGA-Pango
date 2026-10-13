importScripts("/pixels.js","/preview-renderer.js","/preview-stream.js");
// A live bitmap keeps both pixel conversion and canvas uploads off the main
// thread. Archives and browsers without bitmap support retain the byte path.
let liveSurface=null,gpu=null,liveContext=null,bitmapMode=false;
let pullController=null,pullGeneration=0,pullMode=false,pendingGrant=null;
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
        uploadBytes:gpu?(direct?bytes.byteLength:result.pixels.byteLength):0,
        directTexture:!!direct};
      const bitmap=liveSurface.transferToImageBitmap();
      self.postMessage({...output,bitmap},[bitmap]);return output;
    }
    const result=self.PangoPixels.renderPixels(buffer,renderMeta,mode,{displayWidth});
    // Stage timings support real browser bottleneck checks, independent of
    // the frame-rate badges and without modifying original source evidence.
    self.postMessage({...result,meta,target,fetchMs,queueMs,workerWaitMs,generation,convertMs:performance.now()-start},[result.pixels]);
  }catch(error){self.postMessage({error:error.message,target,generation});throw error;}
}
async function pull(config){
  const controller=new AbortController();pullController?.abort();pullController=controller;
  const generation=++pullGeneration;let after="";
  const url=new URL("/api/preview-socket",self.location.href);url.protocol=url.protocol==="https:"?"wss:":"ws:";
  const socket=new WebSocket(url);socket.binaryType="arraybuffer";
  controller.signal.addEventListener("abort",()=>socket.close(),{once:true});
  try{
    await new Promise((resolve,reject)=>{
      let creditStarted=0;
      const active=()=>!controller.signal.aborted&&generation===pullGeneration;
      async function grant(){
        if(!active()||socket.readyState!==WebSocket.OPEN)return;
        // Exactly one credit is outstanding on this persistent connection.
        creditStarted=performance.now();
        socket.send(JSON.stringify({mode:config.mode,downscale:config.scale,after}));
      }
      socket.onopen=()=>{void grant().catch(reject);};
      socket.onerror=()=>reject(Error("预览通道连接失败"));
      socket.onclose=resolve;
      socket.onmessage=event=>{
        if(!active())return;
        try{
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
          const output=render({...job,mode:config.mode,target:"live",displayWidth:config.displayWidth,
            fetchMs:performance.now()-creditStarted,queueMs:0,generation:config.generation});
          if(output)after=job.meta.key;
          if(output&&pullMode)pendingGrant={generation:config.generation,grant:()=>{void grant().catch(reject);}};
          else if(output)void grant().catch(reject);
          else setTimeout(()=>{void grant().catch(reject);},50);
        }catch(error){reject(error);}
      };
    });
  }catch(error){if(error.name!=="AbortError"&&generation===pullGeneration)self.postMessage({error:error.message,target:"live",generation:config.generation});}
  finally{socket.close();self.postMessage({type:"stream-end",generation:config.generation});}
}
self.onmessage=function(event){
  const value=event.data;
  if(value.type==="init-live"){
    bitmapMode=value.bitmap;pullMode=!!value.pull;
    if(bitmapMode)prepareSurface();return;
  }
  if(value.type==="start-live"){void pull(value);return;}
  if(value.type==="stop-live"){pullGeneration++;pendingGrant=null;pullController?.abort();return;}
  if(value.type==="preview-painted"){
    if(pendingGrant&&pendingGrant.generation===value.generation){const grant=pendingGrant.grant;pendingGrant=null;grant();}return;
  }
  try{render(value);}catch{/* Errors were already returned to the owning UI. */}
};

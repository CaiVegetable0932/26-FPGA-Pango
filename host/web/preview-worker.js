importScripts("/pixels.js","/preview-renderer.js");
// A live bitmap keeps both pixel conversion and canvas uploads off the main
// thread. Archives and browsers without bitmap support retain the byte path.
let liveSurface=null,gpu=null,liveContext=null,bitmapMode=false;
function prepareSurface(){
  liveSurface=new OffscreenCanvas(1,1);
  try{gpu=self.PangoPreviewRenderer.create(liveSurface);}catch{gpu=null;}
  if(!gpu){liveSurface=new OffscreenCanvas(1,1);liveContext=liveSurface.getContext("2d",{alpha:false});}
}
self.onmessage=function(event){
  if(event.data.type==="init-live"){
    bitmapMode=event.data.bitmap;if(bitmapMode)prepareSurface();return;
  }
  const {buffer,meta,mode,target,displayWidth,fetchMs,queueMs,generation}=event.data;
  try{
    const start=performance.now();
    // Purpose: let pure pixel conversion choose Bayer-cell anti-aliasing only
    // when the live canvas will be displayed smaller than the sensor frame.
    // Source metadata stays native 1080p; only explicit derivative geometry
    // describes the smaller display payload. It never rewrites source identity.
    const renderMeta=meta.preview_derivative?{...meta,width:meta.preview_width,height:meta.preview_height,
      row_stride:meta.preview_row_stride,pixel_format:meta.preview_pixel_format}:meta;
    if(bitmapMode&&target==="live"){
      if(gpu?.lost())prepareSurface();
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
      const bitmap=liveSurface.transferToImageBitmap();
      self.postMessage({width:result.width,height:result.height,bitmap,meta,target,fetchMs,queueMs,generation,convertMs,
        workerPaintMs:performance.now()-paintStart,renderer:gpu?"worker-webgl":"worker-2d",
        uploadBytes:gpu?(direct?bytes.byteLength:result.pixels.byteLength):0,
        directTexture:!!direct},[bitmap]);
      return;
    }
    const result=self.PangoPixels.renderPixels(buffer,renderMeta,mode,{displayWidth});
    // Stage timings support real browser bottleneck checks, independent of
    // the frame-rate badges and without modifying original source evidence.
    self.postMessage({...result,meta,target,fetchMs,queueMs,generation,convertMs:performance.now()-start},[result.pixels]);
  }catch(error){self.postMessage({error:error.message,target});}
};

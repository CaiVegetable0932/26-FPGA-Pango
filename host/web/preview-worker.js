importScripts("/pixels.js");
self.onmessage=function(event){
  const {buffer,meta,mode,target,displayWidth}=event.data;
  try{
    // Purpose: let pure pixel conversion choose Bayer-cell anti-aliasing only
    // when the live canvas will be displayed smaller than the sensor frame.
    const result=self.PangoPixels.renderPixels(buffer,meta,mode,{displayWidth});
    self.postMessage({...result,meta,target},[result.pixels]);
  }catch(error){self.postMessage({error:error.message,target});}
};

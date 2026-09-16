importScripts("/pixels.js");
self.onmessage=function(event){
  const {buffer,meta,mode,target}=event.data;
  try{
    const result=self.PangoPixels.renderPixels(buffer,meta,mode);
    self.postMessage({...result,meta,target},[result.pixels]);
  }catch(error){self.postMessage({error:error.message,target});}
};

/* Observed preview updates, composition submissions and stalls are separate.
   rVFC metadata may advance by multiple frames while the UI misses callbacks;
   those frames must never be backfilled into the observed preview rate. */
(function(root){
  "use strict";
  function createCounter(now=()=>performance.now()){
    let start=now(),frames=0;
    return {mark(count=1){frames+=Math.max(0,count);},reset(){start=now();frames=0;},
      sample(){const end=now(),dt=(end-start)/1000,fps=dt>0?frames/dt:0;start=end;frames=0;return fps;}};
  }
  function createVideoCounter(now=()=>performance.now()){
    let start,lastTime,lastMedia,lastTotal,frames,submitted,skipped,repeated,maxGap;
    function reset(){start=now();lastTime=lastMedia=lastTotal=null;frames=submitted=skipped=repeated=maxGap=0;}
    reset();
    return {reset,
      frame(meta){
        const time=now();
        // Repeated timestamps are not new observed frames. A counter rollback
        // denotes a decoder/source reset, and cannot produce a catch-up burst.
        if(lastTotal!==null&&meta.presentedFrames<lastTotal)reset();
        if(lastTotal!==null&&Number.isFinite(meta.presentedFrames)){
          const delta=Math.max(0,meta.presentedFrames-lastTotal);
          submitted+=delta;skipped+=Math.max(0,delta-1);
        }
        lastTotal=meta.presentedFrames;
        if(!Number.isFinite(meta.mediaTime))return;
        if(lastMedia===meta.mediaTime){repeated++;return;}
        if(lastTime!==null)maxGap=Math.max(maxGap,time-lastTime);
        lastTime=time;lastMedia=meta.mediaTime;frames++;
      },
      sample(){
        const time=now(),seconds=(time-start)/1000,age=lastTime===null?time-start:time-lastTime;
        const result={fps:seconds>0?frames/seconds:0,submittedFps:seconds>0?submitted/seconds:0,
          frames,skipped,repeated,maxGapMs:Math.max(maxGap,age),ageMs:age,measurable:true};
        start=time;frames=submitted=skipped=repeated=maxGap=0;return result;
      }};
  }
  function videoMeter(video,onRate){
    const counter=createVideoCounter();
    let stopped=false,callback=null,source=null,active=false,quality=null,qualityTime=performance.now();
    // Hidden/paused previews do not count as displayed updates. This DOM walk
    // avoids pixel readback or synchronous layout on every native 1080p frame.
    function visible(){return !!video.srcObject&&!video.paused&&!video.hidden&&
      !(typeof document!=="undefined"&&document.hidden)&&!video.closest?.("[hidden]");}
    function synchronize(){
      const current=visible();
      if(source!==video.srcObject||active!==current){
        source=video.srcObject;active=current;counter.reset();
        quality=video.getVideoPlaybackQuality?.()||null;qualityTime=performance.now();
      }
    }
    function frame(now,meta){
      if(stopped)return;synchronize();if(active)counter.frame(meta);
      callback=video.requestVideoFrameCallback(frame);
    }
    const hasCallback=typeof video.requestVideoFrameCallback==="function";
    if(hasCallback)callback=video.requestVideoFrameCallback(frame);
    // A timer expires stalled rates to zero. Decode counts remain explicitly
    // labelled as decode rates, including when rVFC is unavailable.
    const timer=setInterval(()=>{
      synchronize();
      const info=counter.sample(),time=performance.now(),current=video.getVideoPlaybackQuality?.(),seconds=(time-qualityTime)/1000;
      info.measurable=hasCallback;
      info.decodeFps=active&&quality&&current&&seconds>0?
        Math.max(0,(current.totalVideoFrames-current.droppedVideoFrames)-(quality.totalVideoFrames-quality.droppedVideoFrames))/seconds:0;
      info.decoderDrops=active&&quality&&current?Math.max(0,current.droppedVideoFrames-quality.droppedVideoFrames):0;
      quality=current||null;qualityTime=time;
      if(!active){info.fps=info.submittedFps=info.maxGapMs=info.ageMs=0;info.frames=info.skipped=info.repeated=0;}
      onRate(hasCallback?info.fps:null,info);
    },1000);
    return {destroy(){stopped=true;clearInterval(timer);if(callback!==null)video.cancelVideoFrameCallback?.(callback);
      onRate(0,{measurable:hasCallback,decodeFps:0,skipped:0,decoderDrops:0,maxGapMs:0,ageMs:0});}};
  }
  const api={createCounter,createVideoCounter,videoMeter};root.PangoPreviewRate=api;
  if(typeof module!=="undefined")module.exports=api;
})(typeof self!=="undefined"?self:globalThis);

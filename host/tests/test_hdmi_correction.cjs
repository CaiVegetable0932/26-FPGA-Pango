/* Offline lifecycle/timing fixtures for the HDMI software-reference toggle.
 * No device, real MediaStream, receiver, or hardware service is accessed. */
"use strict";
const assert=require("node:assert/strict");
const math=require("../web/fisheye-preview.js");
const {createCorrectionView}=require("../web/video-input-ui.js");
const results=[];
function test(name,fn){try{fn();results.push({name,passed:true});}catch(error){results.push({name,passed:false,error:error.stack});}}

// Simulate only media metadata and a renderer boundary. Read-only srcObject
// and throwing media entry points catch accidental capture/reopen operations.
function fixture(saved=null,{videoFrames=false,maxFps=60,decoderCounter=false}={}){
  let time=0,id=0,timer=null,source={getVideoTracks:()=>[{readyState:"live",muted:false}]};
  const frames=new Map(),events=new Map(),canvasEvents=new Map(),renders=[],states=[],rates=[],errors=[];
  const video={currentTime:0,videoWidth:1920,videoHeight:1080,readyState:2,paused:false,closest:()=>null};
  Object.defineProperty(video,"srcObject",{get:()=>source,set(){throw Error("The toggle must not replace a stream");}});
  const environment={performance:{now:()=>time},document:{hidden:false},
    navigator:{mediaDevices:{getUserMedia(){throw Error("The toggle must not open capture");}}},
    requestAnimationFrame(fn){if(videoFrames)throw Error("Use decoded video callbacks instead of RAF polling");
      frames.set(++id,fn);return id;},cancelAnimationFrame(key){frames.delete(key);},
    setInterval(fn){timer=fn;return 1;},clearInterval(){timer=null;},
    addEventListener(key,fn){events.set(key,fn);},removeEventListener(key){events.delete(key);}};
  const canvas={hidden:false,dataset:{},addEventListener(key,fn){canvasEvents.set(key,fn);},removeEventListener(key){canvasEvents.delete(key);}};
  let rendererCount=0,clearCount=0,disposeCount=0,renderError=null;
  // Optional decoder/video callback boundaries distinguish a advancing media
  // clock from a new decoded picture without any real camera or browser.
  let decoded=0;
  if(videoFrames){video.requestVideoFrameCallback=fn=>{frames.set(++id,fn);return id;};
    video.cancelVideoFrameCallback=key=>frames.delete(key);}
  if(decoderCounter)video.getVideoPlaybackQuality=()=>({totalVideoFrames:decoded,droppedVideoFrames:0});
  const renderer={kind:"WebGL",maxFps,render(input,parameters){
    if(renderError)throw renderError;renders.push({input,parameters:{...parameters},time,media:input.currentTime});
  },clear(){clearCount++;},dispose(){disposeCount++;}};
  const storage={getItem(key){assert.equal(key,math.STORAGE_KEY);return saved;}};
  const view=createCorrectionView({video,canvas,storage,environment,
    math:{...math,createRenderer(){rendererCount++;return renderer;}},
    onState:state=>states.push(state),onRate:(fps,info)=>rates.push({fps,...info}),onError:error=>errors.push(error.message)});
  return {view,video,canvas,environment,frames,events,canvasEvents,renders,states,rates,errors,
    at(value){time=value;},tick(){if(timer)timer();},step(value,media=video.currentTime,decodeCount=decoded){
      time=value;video.currentTime=media;decoded=decodeCount;const entry=frames.entries().next().value;
      if(entry){frames.delete(entry[0]);entry[1](time,videoFrames?{mediaTime:media}:undefined);}
    },setSaved(value){saved=value;},storageEvent(key=math.STORAGE_KEY){events.get("storage")?.({key});},
    replaceSource(){source={getVideoTracks:()=>[{readyState:"live",muted:false}]};},
    fail(){renderError=Error("fixture GPU failure");},
    get rendererCount(){return rendererCount;},get clearCount(){return clearCount;},get disposeCount(){return disposeCount;}};
}

test("Closed input can select either mode without creating a renderer or requesting capture",()=>{
  const f=fixture();assert.equal(f.view.getState().mode,"original");assert.equal(f.canvas.hidden,true);
  f.view.toggle();assert.equal(f.view.getState().mode,"corrected");assert.equal(f.canvas.hidden,true);
  assert.equal(f.frames.size,0);f.view.toggle();assert.equal(f.rendererCount,0);f.view.destroy();
});
test("Correction reuses the source object and exactly the calibration page's saved parameters",()=>{
  const parameters=math.normalize({...math.preset(),fx:810,output_fov_deg:120});
  const f=fixture(JSON.stringify(math.exportSettings(parameters)));
  f.view.setSource(true);f.view.toggle();f.step(0,0);
  assert.equal(f.renders[0].input,f.video);assert.deepEqual(f.renders[0].parameters,parameters);
  assert.equal(f.view.getState().origin,"calibration");assert.equal(f.canvas.hidden,false);
  assert.equal(f.canvas.dataset.processingLocation,"pc_software_reference");
  assert.equal(f.video.videoWidth,1920);assert.equal(f.video.videoHeight,1080);
  f.view.toggle();assert.equal(f.canvas.hidden,true);assert.equal(f.frames.size,0);f.view.destroy();
});
test("GPU budget admits every 30 FPS input picture and counts actual correction draws",()=>{
  const f=fixture();f.view.setSource(true);f.view.toggle();
  for(let i=0;i<30;i++)f.step(i*1000/30,i/30);
  f.at(1000);f.tick();assert.equal(f.rates.at(-1).fps,f.renders.length);
  assert.equal(f.renders.length,30);assert.equal(f.frames.size,1);
  assert.equal(f.renders[1].media,1/30);
  const count=f.renders.length,heldMedia=f.renders.at(-1).media;
  for(let i=0;i<60;i++)f.step(1000+i*20,heldMedia);
  f.at(2200);f.tick();assert.equal(f.renders.length,count);assert.equal(f.rates.at(-1).fps,0);
  assert.ok(f.rates.at(-1).ageMs>1000);f.view.destroy();
});
test("Video callbacks reject duplicate decoded timestamps and stalled input clears without another callback",()=>{
  const f=fixture(null,{videoFrames:true});f.view.setSource(true);f.view.toggle();
  for(let i=0;i<30;i++)f.step(i*1000/30,i/30);
  assert.equal(f.renders.length,30);const count=f.renders.length,held=29/30;
  f.step(1100,held);assert.equal(f.renders.length,count);
  f.at(2800);f.tick();assert.equal(f.view.getState().hasFrame,false);
  f.at(3800);f.tick();assert.equal(f.rates.at(-1).fps,0);
  f.view.toggle();assert.equal(f.frames.size,0);f.view.destroy();
});
test("Legacy RAF uses decoder progress rather than an advancing clock to avoid duplicate frame counts",()=>{
  const f=fixture(null,{decoderCounter:true});f.view.setSource(true);f.view.toggle();
  f.step(0,0,1);f.step(100,.1,1);assert.equal(f.renders.length,1);
  f.step(200,.2,2);assert.equal(f.renders.length,2);f.view.destroy();
});
test("CPU fallback still skips intermediate pictures within its bounded work budget",()=>{
  const f=fixture(null,{videoFrames:true,maxFps:8});f.view.setSource(true);f.view.toggle();
  for(let i=0;i<30;i++)f.step(i*1000/30,i/30);
  assert.ok(f.renders.length<=8);assert.equal(f.renders[1].media,4/30);
  f.view.destroy();assert.equal(f.frames.size,0);
});
test("Calibration storage edits update live parameters and invalid settings disclose default fallback",()=>{
  const f=fixture();f.view.setSource(true);f.view.toggle();f.step(0,0);
  const parameters=math.normalize({...math.preset(),fy:820,k1:.08});
  f.setSaved(JSON.stringify(math.exportSettings(parameters)));f.storageEvent();f.step(100,1);
  assert.deepEqual(f.renders.at(-1).parameters,parameters);
  f.setSaved('{"schema":"pango.fisheye-preview.v1","parameters":{"fx":0}}');f.storageEvent();f.step(200,2);
  assert.deepEqual(f.renders.at(-1).parameters,math.loadSettings({getItem:()=>null}).parameters);
  assert.equal(f.view.getState().origin,"default");assert.ok(f.view.getState().parameterError);
  f.setSaved(null);f.storageEvent(null);assert.equal(f.view.getState().parameterError,"");f.view.destroy();
});
test("Disconnect and source replacement clear the old image and correction rate",()=>{
  const f=fixture();f.view.setSource(true);f.view.toggle();f.step(0,0);f.step(100,.1);
  const clears=f.clearCount;f.view.setSource(false);assert.ok(f.clearCount>clears);
  assert.equal(f.canvas.hidden,true);assert.equal(f.frames.size,0);assert.equal(f.rates.at(-1).fps,0);
  f.at(1500);f.replaceSource();f.view.setSource(true);f.step(1500,0);f.at(2500);f.tick();
  assert.equal(f.rates.at(-1).fps,1);assert.equal(f.view.getState().hasFrame,true);f.view.destroy();
});
test("Hidden views stop drawing and cannot retain a prior correction FPS",()=>{
  const f=fixture();f.view.setSource(true);f.view.toggle();f.step(0,0);
  // Background tabs may deliver no animation callback at all.
  f.environment.document.hidden=true;f.at(1000);f.tick();assert.equal(f.rates.at(-1).fps,0);
  assert.equal(f.view.getState().hasFrame,false);assert.equal(f.renders.length,1);
  f.environment.document.hidden=false;f.step(2000,2);assert.equal(f.renders.length,2);f.view.destroy();
});
test("Renderer failure exposes labelled original and destroy releases callbacks and GPU resources",()=>{
  const f=fixture();f.view.setSource(true);f.view.toggle();f.step(0,0);f.fail();f.step(100,1);
  assert.equal(f.view.getState().mode,"original");assert.equal(f.canvas.hidden,true);
  assert.equal(f.errors[0],"fixture GPU failure");assert.equal(f.frames.size,0);
  f.view.destroy();assert.equal(f.disposeCount,1);assert.equal(f.events.size,0);assert.equal(f.canvasEvents.size,0);
});

// These results certify software fixtures only, with hardware intentionally absent.
for(const result of results)console.log((result.passed?"PASS ":"FAIL ")+result.name+(result.error?"\n"+result.error:""));
process.exitCode=results.every(result=>result.passed)?0:1;

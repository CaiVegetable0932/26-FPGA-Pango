/* Timing fixtures reproduce missed callbacks and stalls without fake hardware claims. */
"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm"),path=require("node:path");
const {createVideoCounter}=require("../web/preview-rate.js"),results=[];
function test(name,fn){try{fn();results.push({name,passed:true});}catch(e){results.push({name,passed:false,error:e.stack});}}
test("Missed callbacks are not backfilled from compositor totals",()=>{
  let now=0;const c=createVideoCounter(()=>now);
  for(let i=0;i<6;i++){now=i*200;c.frame({presentedFrames:1+i*6,mediaTime:i/5});}
  const s=c.sample();assert.equal(s.fps,6);assert.equal(s.submittedFps,30);assert.equal(s.skipped,25);assert.equal(s.maxGapMs,200);
});
test("Repeated media timestamps do not create observed new frames",()=>{
  let now=0;const c=createVideoCounter(()=>now);
  for(let i=0;i<30;i++){now=i*1000/30;c.frame({presentedFrames:i+1,mediaTime:1});}
  now=1000;const s=c.sample();assert.equal(s.frames,1);assert.equal(s.repeated,29);assert.equal(s.maxGapMs,1000);
  now=2000;assert.equal(c.sample().fps,0);
  assert.equal(c.sample().totalFrames,1);
});
test("A burst with a 30 FPS average still exposes its long update gap",()=>{
  let now=0;const c=createVideoCounter(()=>now);
  for(let i=0;i<30;i++){now=i<15?i*20:500+(i-15)*20;c.frame({presentedFrames:i+1,mediaTime:i/30});}
  now=1000;const s=c.sample();assert.equal(s.fps,30);assert.equal(s.maxGapMs,220);
});
test("Decoder counter rollback resets history without negative or huge rates",()=>{
  let now=0;const c=createVideoCounter(()=>now);c.frame({presentedFrames:10000,mediaTime:300});
  now=500;c.frame({presentedFrames:1,mediaTime:0});now=1500;
  const s=c.sample();assert.equal(s.fps,1);assert.equal(s.skipped,0);assert.equal(s.submittedFps,0);
});
function fixture(withCallback=true){
  let now=0,id=0,timer=null;const callbacks=new Map(),rates=[];
  const video={srcObject:{},paused:false,hidden:false,quality:{totalVideoFrames:0,droppedVideoFrames:0},
    getVideoPlaybackQuality(){return {...this.quality};},closest(){return null;},
    cancelVideoFrameCallback(key){callbacks.delete(key);}};
  if(withCallback)video.requestVideoFrameCallback=fn=>{callbacks.set(++id,fn);return id;};
  const context={module:{exports:{}},performance:{now:()=>now},document:{hidden:false},
    setInterval(fn){timer=fn;return 1;},clearInterval(){timer=null;}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../web/preview-rate.js"),"utf8"),context);
  const meter=context.module.exports.videoMeter(video,(fps,info)=>rates.push({fps,info}));
  return {video,rates,meter,callbacks,at(t){now=t;},tick(){timer();},frame(meta){
    const [key,fn]=callbacks.entries().next().value;callbacks.delete(key);fn(now,meta);}};
}
test("Browser meter separates observed updates from playback-quality totals",()=>{
  const f=fixture();f.frame({presentedFrames:1,mediaTime:0});f.at(400);f.frame({presentedFrames:13,mediaTime:.4});
  f.video.quality={totalVideoFrames:30,droppedVideoFrames:4};f.at(1000);f.tick();
  const r=f.rates.at(-1);assert.equal(r.fps,2);assert.equal(r.info.skipped,11);assert.equal(r.info.playbackTotalFps,30);assert.equal(r.info.playbackDrops,4);assert.equal(r.info.qualityConsistent,true);
  f.at(2000);f.tick();assert.equal(f.rates.at(-1).fps,0);assert.equal(f.rates.at(-1).info.ageMs,1600);
  f.meter.destroy();assert.equal(f.callbacks.size,0);
});
test("Source replacement, hidden and paused previews cannot carry old counts",()=>{
  const f=fixture();f.frame({presentedFrames:1,mediaTime:0});f.at(200);f.frame({presentedFrames:7,mediaTime:.2});
  f.video.srcObject={};f.at(500);f.frame({presentedFrames:1,mediaTime:0});f.at(1500);f.tick();
  assert.equal(f.rates.at(-1).fps,1);assert.equal(f.rates.at(-1).info.skipped,0);
  f.video.hidden=true;f.at(2500);f.tick();assert.equal(f.rates.at(-1).fps,0);
  f.video.hidden=false;f.video.paused=true;f.at(3500);f.tick();assert.equal(f.rates.at(-1).fps,0);f.meter.destroy();
});
test("Without frame callbacks the UI cannot mistake quality totals for preview FPS",()=>{
  const f=fixture(false);f.tick();f.video.quality={totalVideoFrames:30,droppedVideoFrames:5};f.at(1000);f.tick();
  assert.equal(f.rates.at(-1).fps,null);assert.equal(f.rates.at(-1).info.playbackTotalFps,30);assert.equal(f.rates.at(-1).info.measurable,false);f.meter.destroy();
});
test("All frames flagged dropped cannot claim zero decoded FPS over real callbacks",()=>{
  // Reproduce the actual Hagibis/Chromium quality-counter contradiction.
  const f=fixture();f.frame({presentedFrames:1,mediaTime:0});
  f.at(500);f.frame({presentedFrames:16,mediaTime:.5});
  f.video.quality={totalVideoFrames:30,droppedVideoFrames:30};f.at(1000);f.tick();
  const r=f.rates.at(-1);assert.equal(r.fps,2);assert.equal(r.info.playbackTotalFps,30);
  assert.equal(r.info.qualityConsistent,false);assert.equal(r.info.decodeFps,undefined);f.meter.destroy();
});
// This report describes software fixtures only; runtime hardware proof is separate.
const report={tests_run:results.length,passed:results.every(r=>r.passed),hardware_acceptance:"not_performed",results};
fs.writeFileSync(path.join(__dirname,"../reports/preview-rate-tests.json"),JSON.stringify(report,null,2)+"\n");
for(const r of results)console.log((r.passed?"PASS ":"FAIL ")+r.name+(r.error?"\n"+r.error:""));
process.exitCode=report.passed?0:1;

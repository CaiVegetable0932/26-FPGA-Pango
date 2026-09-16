/* Software-only MediaDevices/DOM fixtures. Never accesses a camera or capture card. */
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm"),crypto=require("node:crypto");
const {createController,STORAGE_KEY}=require("../web/video-input.js");
class Events{
  constructor(){this.listeners=new Map();}
  addEventListener(event,fn){if(!this.listeners.has(event))this.listeners.set(event,new Set());this.listeners.get(event).add(fn);}
  removeEventListener(event,fn){this.listeners.get(event)?.delete(fn);}
  async fire(event){for(const fn of this.listeners.get(event)||[])await fn({target:this,preventDefault(){}});}
}
function capture(id="card"){
  const track=new Events();Object.assign(track,{readyState:"live",muted:false,stops:0,label:"Hagibis",stop(){this.stops++;this.readyState="ended";},getSettings(){return {deviceId:id,width:1920,height:1080,frameRate:30};}});
  return {track,getTracks:()=>[track],getVideoTracks:()=>[track]};
}
const tick=()=>new Promise(resolve=>setImmediate(resolve));
function deferred(){let resolve,reject;const promise=new Promise((r,j)=>{resolve=r;reject=j;});return {resolve,reject,promise};}
function fixture(){
  const media=new Events(),calls=[],values=new Map(),states=[];
  media.devices=[{kind:"videoinput",deviceId:"card",label:"Hagibis"},{kind:"videoinput",deviceId:"webcam",label:"Built-in camera"},{kind:"audioinput",deviceId:"mic",label:"Microphone"}];
  media.enumerateDevices=async()=>media.devices;
  media.getUserMedia=async constraint=>{calls.push(constraint);return media.next?media.next(constraint):capture(constraint.video?.deviceId?.exact||"card");};
  const storage={getItem:key=>values.get(key)||null,setItem:(key,value)=>values.set(key,value)};
  const video={srcObject:null,muted:false,play:async()=>{},pause(){}};
  const controller=createController({mediaDevices:media,storage,video,onState:state=>states.push(state)});
  return {media,calls,storage,values,video,controller,states};
}
const results=[];
async function test(name,fn){try{await fn();results.push({name,passed:true});}catch(error){results.push({name,passed:false,error:error.stack});}}
(async()=>{
  await test("Enumerates video devices only without opening hardware",async()=>{
    const f=fixture();const state=await f.controller.refresh();
    assert.deepEqual(state.devices.map(d=>d.deviceId),["card","webcam"]);assert.equal(state.refreshing,false);assert.equal(f.calls.length,0);f.controller.destroy();
  });
  await test("Saving and restoring a device works with no input signal and no stream",async()=>{
    const f=fixture();await f.controller.refresh();f.controller.configure("card");
    assert.equal(f.calls.length,0);assert.equal(f.video.srcObject,null);assert.equal(f.controller.getState().status,"configured");
    const restored=createController({mediaDevices:f.media,storage:f.storage});assert.equal(restored.getState().selected.deviceId,"card");assert.equal(restored.getStream(),null);
    assert.equal(JSON.parse(f.values.get(STORAGE_KEY)).version,1);restored.destroy();f.controller.destroy();
  });
  await test("Opening uses exact saved ID and audio false; identity stays unverified",async()=>{
    const f=fixture();await f.controller.refresh();f.controller.configure("card");const state=await f.controller.open();
    assert.deepEqual(f.calls,[{audio:false,video:{deviceId:{exact:"card"}}}]);
    assert.equal(state.pending,false);assert.equal(state.status,"open");assert.equal(state.source_frame_id,null);assert.equal(state.pairing_status,"unverified");
    assert.equal(state.signal_validation,"not_performed");assert.equal(f.video.srcObject,f.controller.getStream());
    assert.throws(()=>f.controller.configure("webcam"),/关闭设备/);
    const opened=f.controller.getStream();f.controller.close();assert.equal(opened.track.stops,1);assert.equal(f.video.srcObject,null);assert.equal(f.controller.getState().selected.deviceId,"card");f.controller.destroy();
  });
  await test("Missing device fails without falling back to the built-in camera",async()=>{
    const f=fixture();await f.controller.refresh();f.controller.configure("card");
    f.media.next=()=>Promise.reject(Object.assign(Error(),{name:"NotFoundError"}));const state=await f.controller.open();
    assert.equal(f.calls.length,1);assert.equal(f.calls[0].video.deviceId.exact,"card");assert.equal(state.status,"error");assert.equal(state.selected.deviceId,"card");assert.equal(f.controller.getStream(),null);f.controller.destroy();
  });
  await test("Permission denial and busy-device errors retain saved configuration",async()=>{
    for(const name of ["NotAllowedError","NotReadableError","OverconstrainedError"]){
      const f=fixture();await f.controller.refresh();f.controller.configure("card");f.media.next=async()=>{throw Object.assign(Error(),{name});};
      const state=await f.controller.open();assert.equal(state.status,"error");assert.equal(state.pending,false);assert.equal(state.selected.deviceId,"card");f.controller.destroy();
    }
  });
  await test("Permission enumeration always releases its temporary stream",async()=>{
    for(const enumerationFails of [false,true]){
      const f=fixture(),temporary=capture();f.media.next=async()=>temporary;
      if(enumerationFails)f.media.enumerateDevices=async()=>{throw Error("enumeration unavailable");};
      await f.controller.authorize();assert.equal(temporary.track.stops,1);assert.equal(f.controller.getStream(),null);assert.equal(f.video.srcObject,null);
      assert.equal(f.calls[0].audio,false);assert.equal(f.controller.getState().pending,false);f.controller.destroy();
    }
  });
  await test("Cancel during a pending device request discards and stops a late stream",async()=>{
    const f=fixture(),pending=deferred(),incoming=capture();await f.controller.refresh();f.controller.configure("card");f.media.next=()=>pending.promise;
    const opening=f.controller.open();f.controller.close();await assert.rejects(()=>f.controller.open(),/上一次设备请求/);
    pending.resolve(incoming);const state=await opening;assert.equal(state.pending,false);assert.equal(incoming.track.stops,1);assert.equal(f.controller.getStream(),null);assert.equal(state.status,"configured");f.controller.destroy();
  });
  await test("Cancel permission request or close page releases late authorization tracks",async()=>{
    for(const destroy of [false,true]){
      const f=fixture(),pending=deferred(),temporary=capture();f.media.next=()=>pending.promise;const permission=f.controller.authorize();
      if(destroy)f.controller.destroy();else f.controller.close();pending.resolve(temporary);await permission;
      assert.equal(temporary.track.stops,1);assert.equal(f.controller.getStream(),null);f.controller.destroy();
    }
  });
  await test("Muted and ended tracks update state without claiming a verified signal",async()=>{
    const f=fixture();await f.controller.refresh();f.controller.configure("card");await f.controller.open();const stream=f.controller.getStream();
    await stream.track.fire("mute");assert.equal(f.controller.getState().status,"waiting");
    await stream.track.fire("unmute");assert.equal(f.controller.getState().status,"open");assert.equal(f.controller.getState().signal_validation,"not_performed");
    await stream.track.fire("ended");assert.equal(f.controller.getState().status,"disconnected");assert.equal(f.video.srcObject,null);f.controller.destroy();
  });
  await test("Device removal stops current tracks and retains the user's exact choice",async()=>{
    const f=fixture();await f.controller.refresh();f.controller.configure("card");await f.controller.open();const active=f.controller.getStream();
    f.media.devices=f.media.devices.filter(d=>d.deviceId!=="card");await f.media.fire("devicechange");await tick();
    assert.equal(f.controller.getState().status,"disconnected");assert.equal(active.track.stops,1);assert.equal(f.controller.getState().selected.deviceId,"card");assert.equal(f.calls.length,1);f.controller.destroy();
  });
  await test("Unexpected device identity and playback failure release tracks",async()=>{
    for(const mismatch of [false,true]){
      const f=fixture(),incoming=capture(mismatch?"wrong-camera":"card");await f.controller.refresh();f.controller.configure("card");f.media.next=async()=>incoming;
      if(!mismatch)f.video.play=async()=>{throw Error("autoplay blocked");};
      await f.controller.open();await tick();assert.equal(f.controller.getState().status,"error");assert.ok(incoming.track.stops>0);assert.equal(f.video.srcObject,null);f.controller.destroy();
    }
  });
  await test("Blocked or corrupt browser storage does not prevent current-page configuration",async()=>{
    const f=fixture();f.values.set(STORAGE_KEY,"invalid JSON");
    const c=createController({mediaDevices:f.media,storage:{getItem:()=>"invalid JSON",setItem:()=>{throw Error("storage blocked");}}});
    await c.refresh();const state=c.configure("card");assert.equal(state.persistent,false);assert.equal(state.selected.deviceId,"card");assert.equal(f.calls.length,0);c.destroy();f.controller.destroy();
  });
  await test("Latest enumeration wins and unsupported contexts never request capture",async()=>{
    const f=fixture(),old=deferred();f.media.enumerateDevices=()=>old.promise;const first=f.controller.refresh();
    f.media.enumerateDevices=async()=>[{kind:"videoinput",deviceId:"new",label:"New card"}];await f.controller.refresh();old.resolve([]);await first;
    assert.equal(f.controller.getState().devices[0].deviceId,"new");f.controller.destroy();
    const c=createController({mediaDevices:f.media,secureContext:false});assert.equal(c.getState().status,"unsupported");await assert.rejects(()=>c.open(),/系统浏览器/);assert.equal(f.calls.length,0);c.destroy();
  });
  await test("Destroyed active adapter releases every track and removes hotplug listeners",async()=>{
    const f=fixture();await f.controller.refresh();f.controller.configure("card");await f.controller.open();const active=f.controller.getStream();f.controller.destroy();
    assert.equal(active.track.stops,1);assert.equal(f.video.srcObject,null);assert.equal(f.media.listeners.get("devicechange").size,0);
  });
  await test("Device UI separates save from open and keeps unsaved choices from opening another source",async()=>{
    class Element extends Events{
      constructor(tag="div"){super();Object.assign(this,{tag,value:"",textContent:"",children:[],hidden:false,disabled:false,className:"",srcObject:null});}
      replaceChildren(...children){this.children=children;this.value=children[0]?.value||"";}
      pause(){} async play(){}
    }
    const f=fixture(),elements=new Map(),messages=[];
    const document={getElementById(id){if(!elements.has(id))elements.set(id,new Element());return elements.get(id);},createElement:tag=>new Element(tag)};
    const context={window:{PangoVideoInput:{createController},localStorage:f.storage,isSecureContext:true},navigator:{mediaDevices:f.media},document};
    vm.createContext(context);vm.runInContext(fs.readFileSync(path.join(__dirname,"../web/video-input-ui.js"),"utf8"),context);
    const ui=context.window.PangoVideoInputUI.create({toast:message=>messages.push(message)}),$=id=>document.getElementById(id);
    assert.equal(f.calls.length,0);await ui.refresh();$("capture-device").value="card";await $("capture-device").fire("change");
    assert.equal($("capture-save").disabled,false);assert.equal($("capture-open").disabled,true);await $("capture-save").fire("click");
    assert.equal(f.calls.length,0);assert.equal($("capture-open").disabled,false);assert.equal($("capture-selected").textContent,"Hagibis");
    $("capture-device").value="webcam";await $("capture-device").fire("change");assert.equal($("capture-open").disabled,true);
    $("capture-device").value="card";await $("capture-device").fire("change");await $("capture-open").fire("click");
    assert.equal($("capture-video").hidden,false);assert.equal($("capture-empty").hidden,true);assert.equal($("capture-device").disabled,true);
    assert.match($("capture-format").textContent,/协商 30 FPS/);assert.equal(f.calls[0].audio,false);
    const stream=ui.controller.getStream();await $("capture-preview-close").fire("click");assert.equal(stream.track.stops,1);assert.equal($("capture-video").hidden,true);
    ui.destroy();f.controller.destroy();assert.equal($("capture-open").listeners.get("click").size,0);
  });
  const root=path.resolve(__dirname,".."),files=["web/video-input.js","web/video-input-ui.js","tests/test_video_input.cjs"];
  const report={utc:new Date().toISOString(),node:process.version,tests_run:results.length,passed:results.every(r=>r.passed),
    test_environment:"Node.js MediaDevices, MediaStreamTrack and DOM fixtures",browser_ui_qa:"not_performed",hardware_capture:"not_performed",signal_validation:"not_performed",results,
    source_sha256:Object.fromEntries(files.map(name=>[name,crypto.createHash("sha256").update(fs.readFileSync(path.join(root,name))).digest("hex")]))};
  fs.writeFileSync(path.join(root,"reports/video-input-frontend-tests.json"),JSON.stringify(report,null,2)+"\n");
  for(const result of results)console.log((result.passed?"PASS ":"FAIL ")+result.name+(result.error?"\n"+result.error:""));
  process.exitCode=report.passed?0:1;
})();

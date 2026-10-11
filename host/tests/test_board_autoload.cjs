/* No FPGA/video API is available in this fixture: only persistent settings and reads. */
"use strict";
const test=require("node:test"),assert=require("node:assert/strict");
const {create}=require("../web/board-autoload.js");
function fixture(){
  class Node{constructor(){this.value="";this.checked=false;this.disabled=false;this.events={};}
    addEventListener(name,fn){this.events[name]=fn;}removeEventListener(name){delete this.events[name];}fire(){return this.events.click?.();}}
  const nodes=new Map(),$=id=>{if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);};
  let timer,release,fail=false;
  const calls=[],settings={enabled:false,preset_path:"config/calibration/rgb33.json",rotation_deg:0,enhance:true,mode:"corrected",markers:false,diameter:10};
  let state={settings,message:"disabled",active_version:null,displayed_version:null};
  const environment={document:{getElementById:$},setTimeout(fn){timer=fn;return 1;},clearTimeout(){timer=null;}};
  const app=create({environment,request:async(route,data)=>{
    calls.push({route,data});if(fail)throw Error("missing preset");
    if(route==="/api/board/autoload/preset")return {preset:{parameters:{fx:831}},preset_sha256:"sha",settings};
    assert.equal(route,"/api/board/autoload");
    if(data){if(release)return release(data);state={...state,settings:data,message:"saved"};}
    return state;
  }});
  return {app,$,calls,tick:()=>timer?.(),fail(){fail=true;},defer(fn){release=fn;}};
}
test("Opening/polling does not opt in, upload or overwrite pending form edits",async()=>{
  const f=fixture();await f.app.init();assert.equal(f.$("autoload-enabled").checked,false);
  f.$("autoload-preset").value="config/calibration/changed.json";await f.tick();
  assert.equal(f.$("autoload-preset").value,"config/calibration/changed.json");
  assert.ok(f.calls.every(call=>call.data===undefined));f.app.destroy();
});
test("Explicit settings are persisted once; duplicate clicks and failures are bounded",async()=>{
  const f=fixture();await f.app.init();f.$("autoload-enabled").checked=true;
  f.$("autoload-rotation").value="3";f.$("autoload-diameter").value="12";
  let resolve;f.defer(()=>new Promise(done=>resolve=done));const pending=f.$("autoload-save").fire();
  assert.equal(f.$("autoload-save").disabled,true);await f.$("autoload-save").fire();
  assert.equal(f.calls.filter(call=>call.data).length,1);
  const saved=f.calls.at(-1).data;assert.equal(saved.enabled,true);assert.equal(saved.rotation_deg,3);assert.equal(saved.diameter,12);
  resolve({settings:saved,message:"saved"});await pending;assert.equal(f.$("autoload-save").disabled,false);
  f.fail();await f.$("autoload-save").fire();assert.match(f.$("autoload-status").textContent,/missing preset/);f.app.destroy();
});
test("Preset review is explicit GET only, not a board write or capture restart",async()=>{
  const f=fixture();await f.app.init();f.$("fpga-parameters").value="operator edit";
  await f.tick();assert.equal(f.$("fpga-parameters").value,"operator edit");
  await f.$("autoload-load").fire();assert.deepEqual(JSON.parse(f.$("fpga-parameters").value),{parameters:{fx:831}});
  assert.match(f.$("autoload-status").textContent,/不代表板上/);assert.ok(f.calls.every(call=>call.data===undefined));f.app.destroy();
});

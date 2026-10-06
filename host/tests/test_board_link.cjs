/* Verify that Ethernet recovery never reopens/closes the independent HDMI stream. */
"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),vm=require("node:vm"),path=require("node:path");
class Element{
  constructor(){this.value="";this.disabled=false;this.checked=false;this.listeners=new Map();}
  addEventListener(event,fn){this.listeners.set(event,fn);}
  replaceChildren(){this.value="";}add(){}
  async click(){return this.listeners.get("click")();}
}
(async()=>{
  const nodes=new Map(),$=id=>{if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);};
  let timer,state,resolveReset,resetCalls=0,hdmiCalls=0;const messages=[];
  const defaults={port:"CP2102",interface:"ethernet",source_ip:"192.168.80.3",source_mac:"02:00:00:00:00:01",peer_port:50000,source_port:50001,auto_start:true};
  state={busy:false,phase:"ready",message:"ready",profile:defaults};
  const context={document:{getElementById:$,querySelector:()=>null},Option:function(label,value){this.value=value;},
    localStorage:{getItem:()=>null},setTimeout(fn){timer=fn;return 1;},clearTimeout(){}};
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../web/board-link.js"),"utf8"),context);
  const app=context.PangoBoardLink.create({toast:(...args)=>messages.push(args),video:{getState:()=>({stream_open:true}),
    refresh(){hdmiCalls++;},open(){hdmiCalls++;},close(){hdmiCalls++;}},request:async(route,data)=>{
      if(route.endsWith("/devices"))return {ports:[{port:"CP2102",label:"board"}],interfaces:[{name:"ethernet",ip:"192.168.80.2",prefix:24,mac:"02:11:22:33:44:55"}],errors:[]};
      if(route.endsWith("/status"))return state;
      if(route.endsWith("/reset-ethernet")){resetCalls++;assert.equal(Object.keys(data).length,0);return new Promise(resolve=>resolveReset=resolve);}
      throw Error("Unexpected route: "+route);
    }});
  await app.init();await Promise.resolve();
  $("board-source-ip").value="10.20.30.40";$("board-peer-port").value="12345";
  const pending=$("board-reset-ethernet").click();assert.equal($("board-start").disabled,true);assert.equal($("board-source-ip").disabled,true);
  await $("board-reset-ethernet").click();assert.equal(resetCalls,1);
  // A poll arriving before the POST reply must not unlock the reset button.
  await timer();assert.equal($("board-reset-ethernet").disabled,true);
  state={...state,busy:true};resolveReset(state);await pending;
  assert.equal($("board-source-ip").value,"10.20.30.40");
  state={...state,busy:false,profile:defaults};await timer();
  assert.equal($("board-source-ip").value,"192.168.80.3");assert.equal(Number($("board-peer-port").value),50000);
  assert.equal($("board-interface").value,"ethernet");assert.equal($("board-auto").checked,true);
  assert.equal($("board-reset-ethernet").disabled,false);assert.equal(hdmiCalls,0);assert.match(messages.at(-1)[0],/HDMI/);
  app.destroy();console.log("PASS Ethernet defaults replace form edits after completion without touching HDMI; duplicate clicks and POST/poll race are blocked");
})().catch(e=>{console.error(e);process.exitCode=1;});

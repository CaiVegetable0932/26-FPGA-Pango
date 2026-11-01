/* Run the actual MCU page controller with a minimal DOM and asynchronous API.
 * Pending/final messages and button behavior must survive normal status polls. */
"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
class Element{
  constructor(){this.value="";this.disabled=false;this.dataset={};this.listeners={};this.valid=true;}
  addEventListener(name,callback){this.listeners[name]=callback;}
  reportValidity(){return this.valid;}
  replaceChildren(){}
}
(async()=>{
  const nodes=new Map(),$=id=>{if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);};
  const buttons=["read","move","home","zero","disconnect"].map(action=>{const b=new Element();b.dataset.mcu=action;return b;});
  const button=action=>buttons.find(b=>b.dataset.mcu===action),calls=[],messages=[];
  let state={connected:false,angles:null},timer;
  const context={document:{querySelectorAll:()=>buttons,createElement:()=>new Element()},
    window:{addEventListener(){}},$,text:(id,value)=>{$(id).textContent=value;},
    toast:message=>messages.push(message),setTimeout:fn=>{timer=fn;return 1;},clearTimeout(){},
    request:async(route,data)=>{
      calls.push({route,data});
      if(route==="/api/mcu/zero")state={...state,zero_operation:{status:"pending",message:"姿态零位登记中"}};
      if(route==="/api/mcu/disconnect")state={connected:false};
      return state;
    }};
  const source=fs.readFileSync(path.join(__dirname,"../web/app.js"),"utf8");
  const start=source.indexOf("  // MCU feedback is cached"),end=source.indexOf("  // Optional WebMCP surface",start);
  assert(start>=0&&end>start);
  vm.runInNewContext(source.slice(start,end)+"\nglobalThis.api={renderMCU,mcuAction,pollMCU};",context);
  await context.api.pollMCU();assert(button("move").disabled);
  state={connected:true,angles:{pitch:1.234,yaw:-5.678},age_ms:5,state:{motion_state:0,fault_code:0},
    last_command:{message:"旧运动已接受"}};
  context.api.renderMCU(state);assert.equal($("mcu-current-pitch").textContent,"1.234°");
  await context.api.mcuAction("zero");await Promise.resolve();
  assert.match($("mcu-message").textContent,/登记中/);
  for(const action of ["zero","home","move"])assert(button(action).disabled);
  assert(!button("read").disabled);assert(!button("disconnect").disabled);
  state={...state,zero_operation:{status:"completed",message:"姿态零位登记完成"}};
  await context.api.pollMCU();assert.match($("mcu-message").textContent,/登记完成/);assert(!button("move").disabled);
  state={...state,zero_operation:{status:"failed",message:"MCU 拒绝：NOT_READY"}};
  await timer();assert.match($("mcu-message").textContent,/NOT_READY/);
  $("mcu-pitch").valid=false;const before=calls.length;button("move").listeners.click();assert.equal(calls.length,before);
  await context.api.mcuAction("disconnect");await Promise.resolve();assert(button("move").disabled);
  assert.equal(messages.length,0);
  console.log("PASS MCU async zero pending/final states, action gates, polling, fine feedback and disconnect");
})().catch(error=>{console.error(error);process.exitCode=1;});

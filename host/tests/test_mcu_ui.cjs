/* Run the actual MCU page controller with a minimal DOM and asynchronous API.
 * Pending/final messages, the ≥3° step gate, emergency-stop availability and
 * site axis naming must survive normal status polls. */
"use strict";
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm");
class Element{
  constructor(){this.value="";this.disabled=false;this.dataset={};this.listeners={};this.valid=true;this.textContent="";}
  addEventListener(name,callback){this.listeners[name]=callback;}
  reportValidity(){return this.valid;}
  replaceChildren(){}
}
(async()=>{
  const nodes=new Map(),$=id=>{if(!nodes.has(id))nodes.set(id,new Element());return nodes.get(id);};
  const buttons=["read","move","gantry","confirm","home","zero","stop","disconnect"]
    .map(action=>{const b=new Element();b.dataset.mcu=action;return b;});
  const button=action=>buttons.find(b=>b.dataset.mcu===action),calls=[],messages=[];
  let state={connected:false,angles:null},timer;
  // Let a click-triggered async action finish before asserting on its effects.
  const settle=()=>new Promise(resolve=>setImmediate(resolve));
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
  await context.api.pollMCU();
  for(const action of ["move","gantry","confirm","home","zero","stop"])assert(button(action).disabled);
  state={connected:true,angles:{pitch:1.234,yaw:-5.678},age_ms:5,
    state:{motion_state:0,fault_code:0,xyz_normalized_micro:[1000000,2000000,3000000]},
    last_command:{message:"旧运动已接受"}};
  context.api.renderMCU(state);
  assert.equal($("mcu-current-pitch").textContent,"1.234°");
  // Site naming: firmware axis 2 is site Z (dual motor), axis 3 site Y (extension).
  assert.equal($("mcu-current-y").textContent,"3.00%");
  assert.equal($("mcu-current-z").textContent,"2.00%");
  // Gantry payload keeps site naming; the backend reorders to firmware axes.
  $("mcu-x").value="20";$("mcu-y").value="30";$("mcu-z").value="40";$("mcu-rpm").value="12";
  calls.length=0;button("gantry").listeners.click();await settle();
  assert.deepEqual({...calls[0].data},{x:20,y:30,z:40,rpm:12});
  // The 3° gate rejects a 2.9° change without any HTTP request.
  calls.length=0;messages.length=0;
  $("mcu-pitch").value="4.134";$("mcu-yaw").value="-9";
  button("move").listeners.click();assert.equal(calls.length,0);
  assert.match($("mcu-message").textContent,/小于 3°/);assert.equal(messages.length,1);
  // Exactly 3° is accepted and reaches the API with the operator's values.
  calls.length=0;messages.length=0;$("mcu-pitch").value="4.234";
  button("move").listeners.click();await settle();
  assert.deepEqual({...calls[0].data},{pitch:4.234,yaw:-9});
  // Native range validation still blocks an out-of-range gantry input.
  calls.length=0;$("mcu-x").valid=false;button("gantry").listeners.click();
  assert.equal(calls.length,0);$("mcu-x").valid=true;
  // Zero registration keeps only the emergency stop reachable.
  await context.api.mcuAction("zero");await Promise.resolve();
  assert.match($("mcu-message").textContent,/登记中/);
  for(const action of ["zero","home","move","gantry","confirm"])assert(button(action).disabled);
  assert(!button("read").disabled);assert(!button("disconnect").disabled);
  assert(!button("stop").disabled);
  state={...state,zero_operation:{status:"completed",message:"姿态零位登记完成"}};
  await context.api.pollMCU();assert.match($("mcu-message").textContent,/登记完成/);assert(!button("move").disabled);
  state={...state,zero_operation:{status:"failed",message:"MCU 拒绝：NOT_READY"}};
  await timer();assert.match($("mcu-message").textContent,/NOT_READY/);
  $("mcu-pitch").valid=false;const before=calls.length;button("move").listeners.click();assert.equal(calls.length,before);
  await context.api.mcuAction("disconnect");await Promise.resolve();assert(button("move").disabled);
  assert.equal(messages.length,0);
  console.log("PASS MCU async zero pending/final states, 3° step gate, gantry payload, site axis naming and disconnect");
})().catch(error=>{console.error(error);process.exitCode=1;});

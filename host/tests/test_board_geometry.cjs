/* Wireframe clients exercise board endpoints/ownership without browser or hardware I/O. */
"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const fs=require("node:fs"),vm=require("node:vm"),path=require("node:path");
const {create,sourceMarkers}=require("../web/board-geometry.js"),math=require("../web/fisheye-preview.js");
const metadata=()=>({epoch:"123",session:1,revision:4,generation:9,flags:3,mode:"original",markers:true,diameter:10,
  displayed_param_version:2,metadata_verified:true,processing_location:"fpga",source_width:1920,source_height:1080,
  source_frame_id:null,pairing_status:"unverified",points:[{id:1,color:"#ff3864",source:[10,20],visible:true,
    get destination(){throw Error("Do not use destination points on uncorrected RAW");}},
    {id:2,color:"#00e5ff",source:[1919,0],visible:false}]});
const frame=()=>({source_mode:"hardware_unverified",stream_epoch:"123",sourceWidth:1920,sourceHeight:1080,width:960,height:540});

// Small DOM fixture records SVG geometry, forms and requests; it has no video
// opener or restart API, so unrelated actions fail immediately.
function fixture(){
  let layoutReads=0,bounds={width:640,height:480},resize=null;
  class Node{
    constructor(){this.value="";this.checked=false;this.disabled=false;this.dataset={};this.children=[];this.attrs={};this.listeners={};}
    addEventListener(event,fn){this.listeners[event]=fn;}removeEventListener(event){delete this.listeners[event];}
    setAttribute(key,value){this.attrs[key]=value;}toggleAttribute(key,on){if(on)this.attrs[key]="";else delete this.attrs[key];}
    append(node){this.children.push(node);}replaceChildren(...nodes){this.children=nodes;}
    getBoundingClientRect(){layoutReads++;return {...bounds};}
    fire(event="click"){return this.listeners[event]?.();}
  }
  const nodes=new Map(),$=id=>{if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);};
  const calls=[],owners=[];let current=metadata(),failure=null,clock=0,timer=null,write=null;
  const environment={document:{getElementById:$,createElementNS:()=>new Node(),hidden:false},performance:{now:()=>clock},
    PangoFisheyePreview:math,localStorage:{getItem:()=>null},setTimeout(fn){timer=fn;return 1;},clearTimeout(){timer=null;},
    ResizeObserver:class{constructor(fn){resize=fn;}observe(){}disconnect(){resize=null;}}};
  $("fpga-rotation").value="0";$("fpga-enhance").checked=true;
  const app=create({environment,videoUI:{setBoardMode(...args){owners.push(args);}},request:async(path,data)=>{
    calls.push({path,data});if(failure)throw Error(failure);
    if(path==="/api/board/markers")return current;
    if(path==="/api/board/view")return data?(write?write():{...current,revision:current.revision+1,...data}):current;
    if(path==="/api/board/geometry")return {version:3,parameters_verified:true};
    throw Error("Unexpected restart/capture request: "+path);
  }});
  return {app,$,calls,owners,set(value){current=value;},fail(value){failure=value;},at(value){clock=value;},
    tick:()=>timer?.(),defer(fn){write=fn;},layoutReads:()=>layoutReads,
    resize(width,height){bounds={width,height};resize?.();}};
}

test("Frame updates avoid layout reads while resize and stale overlays remain correct",async()=>{
  const f=fixture();await f.app.init();f.app.setNetworkFrame(frame());
  const reads=f.layoutReads();
  for(let i=0;i<60;i++)f.app.setNetworkFrame(frame());
  assert.equal(f.layoutReads(),reads);
  f.resize(1280,720);assert.equal(f.layoutReads(),reads+1);
  assert.equal(Number(f.$('fpga-source-markers').children[0].attrs.cx),7);
  f.set({...metadata(),markers:false});await f.app.refresh();
  for(let i=0;i<60;i++)f.app.setNetworkFrame(frame());
  assert.equal(f.layoutReads(),reads+1);
  assert.equal(f.$('fpga-source-markers').children.length,0);
  f.app.destroy();
});

test("FPGA source overlay uses source pixels, returned colors/mask and exact epoch only",()=>{
  const result=sourceMarkers(metadata(),frame());
  assert.deepEqual(result,[{id:1,color:"#ff3864",source:[10,20],point:[4.75,9.75]}]);
  for(const change of [{stream_epoch:"124"},{source_mode:"mock"},{sourceWidth:1280}])assert.deepEqual(sourceMarkers(metadata(),{...frame(),...change}),[]);
  assert.deepEqual(sourceMarkers({...metadata(),markers:false},frame()),[]);
  assert.deepEqual(sourceMarkers(null,frame()),[]);
});

test("Board view is independent, applies one command, keeps source IDs null and clears failures",async()=>{
  const f=fixture();await f.app.init();f.app.setNetworkFrame(frame());
  assert.equal(f.owners.at(-1)[0],true);assert.equal(f.owners.at(-1)[1].source_frame_id,null);
  const circles=f.$("fpga-source-markers").children;assert.equal(circles.length,1);
  assert.equal(circles[0].attrs.fill,"#ff3864");assert.equal(Number(circles[0].attrs.cx),3.5);
  assert.ok(Math.abs(Number(circles[0].attrs.cy)-(60+20.5/3))<1e-10);
  // Repeated readback cannot overwrite an unapplied mode/diameter edit.
  f.$("fpga-view-mode").value="corrected";f.$("fpga-marker-diameter").value="12";
  await f.app.refresh();assert.equal(f.$("fpga-view-mode").value,"corrected");
  await f.$("fpga-view-apply").fire();
  assert.deepEqual(f.calls.filter(c=>c.data),[{path:"/api/board/view",data:{mode:"corrected",markers:true,diameter:12}}]);
  f.fail("revision/generation changed");await f.app.refresh();
  assert.equal(f.$("fpga-source-markers").children.length,0);assert.match(f.$("fpga-control-status").textContent,/revision/);
  assert.equal(f.owners.at(-1)[1],null);f.app.destroy();
});

test("Pending view never retains stale overlays or reports local success; duplicate clicks are blocked",async()=>{
  const f=fixture();await f.app.init();f.app.setNetworkFrame(frame());
  let reject;f.defer(()=>new Promise((_,fail)=>reject=fail));
  const pending=f.$("fpga-view-apply").fire();await Promise.resolve();
  assert.equal(f.$("fpga-source-markers").children.length,0);assert.equal(f.$("fpga-view-apply").disabled,true);
  await f.$("fpga-view-apply").fire();assert.equal(f.calls.filter(c=>c.data).length,1);
  reject(Error("not applied"));await pending;
  assert.equal(f.$("fpga-source-markers").children.length,0);assert.match(f.$("fpga-control-status").textContent,/not applied/);
  assert.equal(f.$("fpga-view-apply").disabled,false);f.app.destroy();
});

test("Software reference switch hides FPGA overlay; stale frames and absent hardware fail gracefully",async()=>{
  const f=fixture();await f.app.init();f.app.setNetworkFrame(frame());
  f.$("geometry-display-owner").value="software";await f.$("geometry-display-owner").fire("change");
  assert.equal(f.$("fpga-source-markers").children.length,0);assert.equal(f.owners.at(-1)[0],false);
  f.$("geometry-display-owner").value="fpga";await f.$("geometry-display-owner").fire("change");
  f.at(1600);await f.tick();assert.equal(f.$("fpga-source-markers").children.length,0);
  f.fail("No UART / old firmware");await f.app.refresh();assert.match(f.$("fpga-control-status").textContent,/No UART/);
  await f.$("fpga-parameters-load").fire();assert.match(f.$("fpga-control-status").textContent,/尚无/);
  assert.ok(f.calls.every(c=>["/api/board/markers","/api/board/view","/api/board/geometry"].includes(c.path)));
  f.app.destroy();
});

test("Explicit parameter JSON goes to checked board uploader, not a software renderer",async()=>{
  const f=fixture();await f.app.init();await f.$("fpga-parameters-apply").fire();
  const request=f.calls.find(c=>c.path==="/api/board/geometry");
  assert.deepEqual(request.data,{preset:{parameters:math.preset()},rotation_deg:0,enhance:true});
  f.$("fpga-parameters").value="broken";await f.$("fpga-parameters-apply").fire();
  assert.equal(f.calls.filter(c=>c.path==="/api/board/geometry").length,1);f.app.destroy();
});

test("Unmarked HDMI mode remains confirmed while failed marker coordinates stay hidden",async()=>{
  // Header-only mode proof never becomes coordinate-table proof or a warp.
  const f=fixture();f.set({...metadata(),markers:false,status:3,metadata_verified:false,
    view_verified:true,marker_error:"标记映射超出支持范围或失败",points:[]});
  await f.app.init();f.app.setNetworkFrame(frame());
  assert.equal(f.$("fpga-source-markers").children.length,0);
  assert.match(f.$("fpga-control-status").textContent,/标记坐标未验证/);
  assert.equal(f.owners.at(-1)[1].view_verified,true);
  assert.ok(f.calls.every(c=>c.path!=="/api/board/markers"));
  f.app.destroy();
});

test("Actual video UI clears both canonical overlays and PC warp when FPGA owns HDMI",()=>{
  // Run the real integration with wireframe media/DOM surfaces; capture entry
  // points throw, making any accidental reopen or stream mutation observable.
  class Node{
    constructor(){this.listeners={};this.dataset={};this.value="";this.hidden=false;this.children=[];}
    addEventListener(k,fn){this.listeners[k]=fn;}removeEventListener(k){delete this.listeners[k];}
    setAttribute(){}replaceChildren(...items){this.children=items;}
  }
  const nodes=new Map(),$=id=>{if(!nodes.has(id))nodes.set(id,new Node());return nodes.get(id);},overlays=[];
  const video=$("capture-video");Object.assign(video,{videoWidth:1280,videoHeight:720,readyState:2,paused:false,
    srcObject:{getVideoTracks:()=>[{readyState:"live",muted:false}]}});
  const controller={getState:()=>({supported:true,devices:[],selected:null,stream_open:true,status:"open",settings:{},capture_mode:"720p30"}),
    refresh(){throw Error("Unexpected hardware refresh");},open(){throw Error("Unexpected capture open");},close(){throw Error("Unexpected capture close");},destroy(){}};
  const environment={document:{getElementById:$,createElement:()=>new Node(),hidden:false},navigator:{mediaDevices:{}},
    localStorage:{getItem:()=>null},performance:{now:()=>0},setInterval:()=>1,clearInterval(){},
    requestAnimationFrame:()=>2,cancelAnimationFrame(){},addEventListener(){},removeEventListener(){},
    PangoFisheyePreview:{...math,createPixelOverlay(){const overlay={view:null,setView(v){this.view=v;},destroy(){}};overlays.push(overlay);return overlay;},
      createMarkerToggle:()=>({updateInfo(){},destroy(){}})},
    PangoVideoInput:{createController:()=>controller},PangoPreviewRate:{videoMeter:()=>({destroy(){}})}};
  environment.window=environment;
  vm.runInNewContext(fs.readFileSync(path.join(__dirname,"../web/video-input-ui.js"),"utf8"),environment);
  const app=environment.PangoVideoInputUI.create();
  app.setNetworkFrame(frame());assert.ok(overlays[0].view);assert.ok(overlays[1].view);
  $("capture-correction-toggle").listeners.click();
  app.setBoardMode(true,metadata());
  assert.equal(overlays[0].view,null);assert.equal(overlays[1].view,null);
  assert.equal($("capture-corrected").hidden,true);assert.equal($("capture-correction-toggle").disabled,true);
  assert.match($("capture-view-label").textContent,/灰度 ISP 原图（非 S0）/);
  assert.match($("capture-correction-info").textContent,/source_frame_id=null/);
  app.setNetworkFrame(frame());assert.equal(overlays[0].view,null);
  app.setBoardMode(false);assert.ok(overlays[0].view);assert.ok(overlays[1].view);
  assert.equal($("capture-correction-toggle").disabled,false);app.destroy();
});

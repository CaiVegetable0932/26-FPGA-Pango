/* Software-only source-pixel geometry, forward mapping and SVG lifecycle.
 * Browser and OpenCV checks provide independent rendering/math validation. */
"use strict";
const assert=require("node:assert/strict"),math=require("../web/fisheye-preview.js");
const results=[];
function close(a,b,tolerance=1e-8){assert.ok(Math.abs(a-b)<tolerance,`${a} != ${b}`);}
function test(name,fn){try{fn();results.push({name,passed:true});}catch(error){results.push({name,passed:false,error:error.stack});}}

test("Twenty unique integer pixels retain the original anchors and add inner cross/diagonal references",()=>{
  for(const [width,height] of [[1920,1080],[1280,720],[321,181],[16,16]]){
    const points=math.markerPixels(width,height);assert.equal(points.length,20);
    assert.deepEqual(points.slice(0,4).map(p=>p.point),[[0,0],[width-1,0],[width-1,height-1],[0,height-1]]);
    assert.equal(new Set(points.map(p=>JSON.stringify(p.point))).size,20);
    for(const p of points){assert.ok(p.point.every(Number.isInteger));assert.match(p.color,/^#[0-9a-f]{6}$/i);
      assert.ok(p.point[0]>=0&&p.point[0]<width&&p.point[1]>=0&&p.point[1]<height);}
    for(const [a,b] of [[9,10],[11,12],[17,18]]){
      assert.equal(points[a].point[0]+points[b].point[0],width-1);assert.equal(points[a].point[1]+points[b].point[1],height-1);
    }
  }
  assert.throws(()=>math.markerPixels(0,1080));
});
test("Forward marker coordinates reverse renderer mapping, including asymmetric and resized outputs",()=>{
  const presets=[math.preset(),math.preset("equidistant200"),math.preset("equisolid200")];
  for(const p of presets)for(const [w,h] of [[1920,1080],[640,360]]){
    for(const [u,v] of [[0,0],[w-1,h-1],[(w-1)/2,(h-1)/2],[w*.3,h*.7]]){
      const source=math.sourcePoint(p,1920,1080,u,v,w,h);
      const mapped=math.destinationPoint(p,1920,1080,...source,w,h);
      assert.equal(mapped.visible,true);close(mapped.point[0],u);close(mapped.point[1],v);
    }
  }
});
test("Zero-distortion equidistant projection agrees with analytic tan-radius mapping",()=>{
  const p=math.normalize(math.preset("equidistant200")),source=[1050,610];
  const x=(source[0]-p.cx)/p.fx,y=(source[1]-p.cy)/p.fy,r=Math.hypot(x,y);
  const f=1920/(2*Math.tan(p.output_fov_deg*Math.PI/360));
  const mapped=math.destinationPoint(p,1920,1080,...source);
  close(mapped.point[0],959.5+f*x*Math.tan(r)/r);close(mapped.point[1],539.5+f*y*Math.tan(r)/r);
});
test("Cropped corners remain outside and reduced outputs preserve half-pixel locations",()=>{
  const p=math.normalize({...math.preset(),output_fov_deg:50});
  const cropped=math.destinationPoint(p,1920,1080,0,0);
  assert.equal(cropped.visible,false);assert.equal(cropped.reason,"outside_view");
  const source=[945,553],full=math.destinationPoint(p,1920,1080,...source),small=math.destinationPoint(p,1920,1080,...source,640,360);
  close(small.point[0],(full.point[0]+.5)/3-.5);close(small.point[1],(full.point[1]+.5)/3-.5);
});

// A tiny SVG/document fixture measures letterboxing independently of image
// rendering and catches cache, clear, resize and visibility preference errors.
function fixture(){
  class Node{
    constructor(){this.hidden=false;this.children=[];this.dataset={};this.attributes={};this.listeners={};this.textContent="";}
    setAttribute(k,v){this.attributes[k]=v;}append(...items){this.children.push(...items);}
    toggleAttribute(k,force){if(force)this.attributes[k]="";else delete this.attributes[k];}
    replaceChildren(...items){this.children=items;this.rebuilds=(this.rebuilds||0)+1;}
    addEventListener(k,fn){this.listeners[k]=fn;}removeEventListener(k){delete this.listeners[k];}
  }
  let resize,disconnected=false;const events={},values=new Map();
  const container={getBoundingClientRect:()=>({width:640,height:480})},element=new Node(),button=new Node(),info=new Node();
  const environment={document:{createElementNS:()=>new Node()},ResizeObserver:class{
    constructor(fn){resize=fn;}observe(){}disconnect(){disconnected=true;}},
    addEventListener(k,fn){events[k]=fn;},removeEventListener(k){delete events[k];}};
  const storage={getItem:key=>values.get(key)||null,setItem:(key,value)=>values.set(key,value)};
  let toggle=null;const overlay=math.createPixelOverlay({element,container,environment,onChange:()=>toggle?.updateInfo()});
  toggle=math.createMarkerToggle({button,info,overlays:[overlay],storage,environment});
  return {element,button,info,overlay,toggle,values,events,
    resize(width,height){resize([{contentRect:{width,height}}]);},get disconnected(){return disconnected;}};
}
test("Overlay letterboxing uses actual display pixels and changing markers leaves image buffers untouched",()=>{
  const f=fixture();f.overlay.setView({width:960,height:540,sourceWidth:1920,sourceHeight:1080});
  assert.equal(f.element.hidden,true);f.button.listeners.click();assert.equal(f.element.children.length,20);
  assert.equal("hidden" in f.element.attributes,false);
  const circle=f.element.children[0].children[0];close(Number(circle.attributes.cx),1/6);close(Number(circle.attributes.cy),60+1/6);
  assert.equal(circle.attributes.r,"5");assert.equal(f.overlay.getState().points[0].point[0],0);
  const rebuilds=f.element.rebuilds;f.overlay.setView({width:960,height:540,sourceWidth:1920,sourceHeight:1080});
  assert.equal(f.element.rebuilds,rebuilds);f.resize(320,240);close(Number(f.element.children[0].children[0].attributes.cy),30+1/12);
  f.overlay.setView(null);assert.equal(f.element.hidden,true);assert.equal(f.element.children.length,0);
  f.toggle.destroy();f.overlay.destroy();assert.equal(f.disconnected,true);
});
test("Mapped overlays retain identities, disclose cropped IDs and share persisted visibility",()=>{
  const f=fixture();f.overlay.setView({width:640,height:360,sourceWidth:1920,sourceHeight:1080,
    parameters:math.normalize({...math.preset(),output_fov_deg:50})});
  f.button.listeners.click();const state=f.overlay.getState();assert.ok(state.outside.includes(1));
  assert.match(f.info.textContent,/视野外/);assert.equal(f.element.children.length,state.visible);
  f.values.set("pango.pixel-markers.visible.v1","0");f.events.storage({key:"pango.pixel-markers.visible.v1"});
  assert.equal(f.element.hidden,true);assert.equal(f.button.attributes["aria-pressed"],"false");
  f.toggle.destroy();f.overlay.destroy();
});

// Export native source samples for an independent OpenCV undistortPoints check.
if(process.argv.includes("--coordinates")){
  assert.ok(results.every(r=>r.passed));
  const presets=[math.preset(),math.preset("equidistant200"),math.preset("equisolid200")];
  console.log(JSON.stringify(presets.flatMap(parameters=>[[1920,1080],[640,360]].map(([width,height])=>({parameters,
    source_width:1920,source_height:1080,width,height,points:math.markerPixels(1920,1080).map(p=>({source:p.point,
      ...math.destinationPoint(parameters,1920,1080,...p.point,width,height)}))})))));
}else{
  for(const r of results)console.log((r.passed?"PASS ":"FAIL ")+r.name+(r.error?"\n"+r.error:""));
  process.exitCode=results.every(r=>r.passed)?0:1;
}

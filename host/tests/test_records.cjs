/* Records UI behavior tests using an isolated DOM fixture, without a browser. */
const assert=require("node:assert/strict"),fs=require("node:fs"),path=require("node:path"),vm=require("node:vm"),crypto=require("node:crypto");
class Element{
  constructor(tag="div"){this.tag=tag;this.children=[];this.listeners={};this.dataset={};this.attributes={};this.textContent="";this.className="";this.disabled=false;this.checked=false;this.indeterminate=false;this.open=false;this.classList={toggle:()=>{}};}
  append(...items){for(const item of items)this.children.push(...(item.tag==="fragment"?item.children:[item]));}
  replaceChildren(...items){this.children=[];this.append(...items);}
  setAttribute(k,v){this.attributes[k]=v;}
  addEventListener(name,fn){(this.listeners[name]??=[]).push(fn);}
  async fire(name){for(const fn of this.listeners[name]||[])await fn({target:this,preventDefault(){}});}
  showModal(){this.open=true;}close(){this.open=false;for(const fn of this.listeners.close||[])fn({});}
}
function fixture(){
  const elements=new Map(),groups=["archive","run","report"].map(group=>{const e=new Element("input");e.dataset.selectGroup=group;return e;});
  const document={getElementById:id=>{if(!elements.has(id))elements.set(id,new Element());return elements.get(id);},
    createElement:tag=>new Element(tag),createDocumentFragment:()=>new Element("fragment"),querySelectorAll:()=>groups};
  const context={document,window:{}};vm.createContext(context);
  vm.runInContext(fs.readFileSync(path.join(__dirname,"../web/records.js"),"utf8"),context);
  let data={archives:[
    {key:"old/f1",run_id:"old",frame_id:"1",complete:false,source_mode:"mock",state:"未完成"},
    {key:"active/f1",run_id:"active",frame_id:"1",complete:false,source_mode:"mock",state:"正在采集",protected:true}],
    runs:[{key:"old/web-session.json",run_id:"old",mode:"mock",state:"已结束"},
          {key:null,run_id:"active",mode:"mock",state:"正在采集",protected:true}],
    reports:[{key:"test.json",name:"test.json",extension:"JSON",bytes:10}]};
  const calls=[],messages=[];let partial=false;
  const request=async(route,payload)=>{
    calls.push({route,payload:payload?JSON.parse(JSON.stringify(payload)):null});
    if(route==="/api/records")return JSON.parse(JSON.stringify({...data,total:data.archives.length+data.runs.length+data.reports.length}));
    const deleted=[],failed=[];
    for(const target of payload.targets){
      if(partial&&target.kind==="report"){failed.push({...target,error:"file locked"});continue;}
      deleted.push(target);
      if(target.kind==="run"){data.runs=data.runs.filter(r=>r.run_id!==target.key);data.archives=data.archives.filter(r=>r.run_id!==target.key);}
      if(target.kind==="archive")data.archives=data.archives.filter(r=>r.key!==target.key);
      if(target.kind==="report")data.reports=data.reports.filter(r=>r.key!==target.key);
    }
    return {deleted,failed};
  };
  const ui=context.window.PangoRecords.create({request,previewArchive:()=>{},toast:(...args)=>messages.push(args),
    getStatus:()=>({running:true,run_id:"active"}),getOnline:()=>true});
  return {ui,$:document.getElementById,calls,messages,setPartial:value=>partial=value};
}
const results=[];
async function test(name,fn){try{await fn();results.push({name,passed:true});}catch(error){results.push({name,passed:false,error:error.stack});}}
(async()=>{
  await test("Selection excludes live records and cancellation never deletes",async()=>{
    const f=fixture();await f.ui.refresh();await f.$("select-all-records").fire("click");
    assert.match(f.$("selection-count").textContent,/3/);
    assert.equal(f.$("archive-table").children[1].children[0].children[0].disabled,true);
    await f.$("delete-selected").fire("click");
    assert.equal(f.$("delete-dialog").open,true);
    assert.equal(f.$("confirm-delete").disabled,false);
    assert.equal(f.calls.filter(c=>c.route.endsWith("/delete")).length,0);
    await f.$("cancel-delete").fire("click");
    assert.equal(f.$("delete-dialog").open,false);
    assert.equal(f.$("confirm-delete").disabled,true);
    await f.$("confirm-delete").fire("click");
    assert.equal(f.calls.filter(c=>c.route.endsWith("/delete")).length,0);
  });
  await test("Confirmed parent deletion de-duplicates selected child images",async()=>{
    const f=fixture();await f.ui.refresh();await f.$("select-all-records").fire("click");
    await f.$("delete-selected").fire("click");await f.$("confirm-delete").fire("click");
    const mutations=f.calls.filter(c=>c.route.endsWith("/delete"));
    assert.equal(mutations.length,1);
    assert.deepEqual(mutations[0].payload.targets,[{kind:"run",key:"old"},{kind:"report",key:"test.json"}]);
    assert.equal(f.$("delete-dialog").open,false);
    assert.match(f.$("records-total").textContent,/全部 2 条/);
    assert.equal(f.$("delete-selected").disabled,true);
  });
  await test("Partial failures keep undeleted selection and disable stale confirmation",async()=>{
    const f=fixture();await f.ui.refresh();f.setPartial(true);
    await f.$("select-all-records").fire("click");await f.$("delete-selected").fire("click");await f.$("confirm-delete").fire("click");
    assert.equal(f.$("delete-dialog").open,true);
    assert.match(f.$("delete-progress").textContent,/file locked/);
    assert.equal(f.$("confirm-delete").disabled,true);
    assert.match(f.$("selection-count").textContent,/1/);
    await f.$("cancel-delete").fire("click");f.setPartial(false);
    await f.$("delete-selected").fire("click");await f.$("confirm-delete").fire("click");
    assert.equal(f.$("delete-dialog").open,false);
    assert.equal(f.$("delete-selected").disabled,true);
  });
  const root=path.resolve(__dirname,"..");
  const report={utc:new Date().toISOString(),node:process.version,tests_run:results.length,passed:results.every(r=>r.passed),
    browser_ui_qa:"not_performed",test_environment:"isolated DOM fixture",results,
    source_sha256:{"web/records.js":crypto.createHash("sha256").update(fs.readFileSync(path.join(root,"web/records.js"))).digest("hex")}};
  fs.writeFileSync(path.join(root,"reports/webui-records-frontend-tests.json"),JSON.stringify(report,null,2)+"\n");
  for(const r of results)console.log((r.passed?"PASS ":"FAIL ")+r.name+(r.error?"\n"+r.error:""));
  process.exitCode=report.passed?0:1;
})();

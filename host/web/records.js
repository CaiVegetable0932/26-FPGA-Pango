/* Complete record inventory and deliberate, selectable deletion. */
(function(){
  "use strict";
  function create({request,previewArchive,toast,getStatus,getOnline}){
    const $=id=>document.getElementById(id), selected=new Set(), rows=new Map();
    let catalog={archives:[],runs:[],reports:[]}, refreshing=false, deleting=false, pending=[];
    const id=target=>JSON.stringify([target.kind,target.key]);
    const target=(kind,item)=>({kind,key:kind==="run"?item.run_id:item.key});
    const locked=item=>Boolean(item.run_id&&getStatus()?.running&&item.run_id===getStatus().run_id);
    function cell(row,value,cls=""){
      const td=document.createElement("td");td.textContent=value??"—";td.className=cls;row.append(td);return td;
    }
    function empty(table,message){const row=document.createElement("tr");cell(row,message,"empty-row").colSpan=6;$(table).replaceChildren(row);}
    function source(value){return value==="mock"?"MOCK · 合成数据":value==="hardware_unverified"?"板端 · 未验收":"来源未记录";}
    function date(value){return value?new Date(value).toLocaleString("zh-CN",{hour12:false}):"—";}
    function duration(value){const s=Math.floor(value||0);return String(Math.floor(s/60)).padStart(2,"0")+":"+String(s%60).padStart(2,"0");}
    function bytes(value){return value>=1048576?(value/1048576).toFixed(2)+" MiB":value>=1024?(value/1024).toFixed(1)+" KiB":value+" B";}
    function link(container,label,url){const a=document.createElement("a");a.textContent=label;a.href=url;a.download="";container.append(a);}
    function rowFor(kind,item,label){
      const row=document.createElement("tr"),choice=target(kind,item),key=id(choice);
      const checkbox=document.createElement("input");checkbox.type="checkbox";checkbox.setAttribute("aria-label","选择 "+label);
      const entry={target:choice,item,label,row,checkbox};rows.set(key,entry);
      checkbox.addEventListener("change",()=>{checkbox.checked?selected.add(key):selected.delete(key);sync();});
      cell(row,"","check-cell").append(checkbox);return row;
    }
    function sync(){
      for(const [key,entry] of rows){
        const disabled=deleting||locked(entry.item);
        if(locked(entry.item))selected.delete(key);
        entry.checkbox.disabled=disabled;entry.checkbox.checked=selected.has(key);entry.row.classList.toggle("selected",selected.has(key));
        entry.checkbox.title=locked(entry.item)?"正在采集，停止后可删除":"";
      }
      for(const checkbox of document.querySelectorAll("[data-select-group]")){
        const group=[...rows].filter(([,r])=>r.target.kind===checkbox.dataset.selectGroup&&!locked(r.item));
        const chosen=group.filter(([key])=>selected.has(key)).length;
        checkbox.checked=group.length>0&&chosen===group.length;
        checkbox.indeterminate=chosen>0&&chosen<group.length;
        checkbox.disabled=deleting||!group.length;
      }
      $("selection-count").textContent=selected.size?"已选择 "+selected.size+" 条记录":"未选择记录";
      $("clear-selection").disabled=deleting||!selected.size;
      $("select-all-records").disabled=deleting||!rows.size;
      $("delete-selected").disabled=deleting||!selected.size||!getOnline();
      $("refresh-records").disabled=refreshing||deleting;
      $("confirm-delete").disabled=deleting||!pending.length;
      $("cancel-delete").disabled=deleting;
    }
    function render(data){
      catalog=data;rows.clear();
      for(const table of ["archive-table","run-table","report-table"])$(table).replaceChildren();
      const imageFragment=document.createDocumentFragment(),runFragment=document.createDocumentFragment(),reportFragment=document.createDocumentFragment();
      for(const item of data.archives){
        const row=rowFor("archive",item,"图像 "+item.key),origin=cell(row,source(item.source_mode)),run=document.createElement("small");
        run.className="run-name";run.textContent=item.run_id;origin.append(run);
        cell(row,item.frame_id);const format=cell(row,item.complete?item.width+" × "+item.height+" "+item.pixel_format:"未完成 / 组合记录");
        const state=document.createElement("small");state.textContent=item.state;format.append(state);
        cell(row,date(item.saved_utc));const actions=cell(row,"","table-actions");
        if(item.complete){
          const button=document.createElement("button");button.textContent="回看";button.addEventListener("click",()=>previewArchive(item));actions.append(button);
          link(actions,item.pixel_format==="RAW8"?"RAW":"RGB","/api/archive/pixels?key="+encodeURIComponent(item.key));
          link(actions,"元数据","/api/archive/metadata?key="+encodeURIComponent(item.key));
        }else actions.textContent="可选中删除；原始数据未完整提交";
        imageFragment.append(row);
      }
      for(const item of data.runs){
        const row=rowFor("run",item,"运行 "+item.run_id),name=cell(row,item.run_id,"run-name"),state=document.createElement("small");
        state.className="record-state"+(item.protected?" active":"");state.textContent=item.state;name.append(state);
        cell(row,source(item.mode));cell(row,(item.frames||0)+" / "+(item.saved||0));cell(row,duration(item.seconds));
        const actions=cell(row,"","table-actions");
        if(item.key)link(actions,"下载 JSON","/api/report?key="+encodeURIComponent(item.key));else actions.textContent="尚无结束报告";
        runFragment.append(row);
      }
      for(const item of data.reports){
        const row=rowFor("report",item,"报告 "+item.name);cell(row,item.name,"run-name");cell(row,item.extension);cell(row,bytes(item.bytes));cell(row,date(item.modified_utc));
        link(cell(row,"","table-actions"),"下载","/api/artifact?key="+encodeURIComponent(item.key));reportFragment.append(row);
      }
      $("archive-table").append(imageFragment);$("run-table").append(runFragment);$("report-table").append(reportFragment);
      if(!data.archives.length)empty("archive-table","暂无原始图像记录");
      if(!data.runs.length)empty("run-table","暂无运行记录");
      if(!data.reports.length)empty("report-table","暂无其他生成报告");
      for(const key of selected)if(!rows.has(key))selected.delete(key);
      $("records-total").textContent="全部 "+data.total+" 条 · "+data.archives.length+" 张图像 / "+data.runs.length+" 次运行 / "+data.reports.length+" 份报告";
      $("archive-count").textContent="全部 "+data.archives.length+" 条";
      $("run-count").textContent="全部 "+data.runs.length+" 次";
      $("report-count").textContent="全部 "+data.reports.length+" 份";
      $("nav-saved").textContent=data.total;sync();
    }
    async function refresh(){
      if(refreshing||deleting)return;
      refreshing=true;sync();
      try{const data=await request("/api/records");render(data);return data;}
      catch(error){toast("记录读取失败："+error.message,true);if(!rows.size)for(const table of ["archive-table","run-table","report-table"])empty(table,"记录读取失败，请刷新重试");throw error;}
      finally{refreshing=false;sync();}
    }
    function openDeletion(){
      pending=[...selected].map(key=>rows.get(key)).filter(entry=>entry&&!locked(entry.item));
      if(!pending.length)return;
      const summary={archive:0,run:0,report:0};pending.forEach(entry=>summary[entry.target.kind]++);
      $("delete-summary").textContent="将删除 "+pending.length+" 条所选记录："+summary.archive+" 张图像、"+summary.run+" 次运行、"+summary.report+" 份报告。";
      $("delete-list").replaceChildren();
      for(const entry of pending){const li=document.createElement("li");li.textContent=entry.label;$("delete-list").append(li);}
      $("delete-progress").textContent="";sync();$("delete-dialog").showModal();
    }
    async function confirmDeletion(){
      if(deleting||!pending.length)return;
      deleting=true;sync();
      const runKeys=new Set(pending.filter(r=>r.target.kind==="run").map(r=>r.target.key));
      const targets=pending.filter(r=>r.target.kind!=="archive"||!runKeys.has(r.item.run_id)).map(r=>r.target);
      let removed=0,failures=[];
      try{
        for(let offset=0;offset<targets.length;offset+=100){
          $("delete-progress").textContent="正在删除 "+(offset+1)+"–"+Math.min(offset+100,targets.length)+" / "+targets.length+" 条记录…";
          const result=await request("/api/records/delete",{targets:targets.slice(offset,offset+100)});
          for(const deleted of result.deleted){
            for(const [key,entry] of rows){
              if(id(deleted)===key||(deleted.kind==="run"&&entry.item.run_id===deleted.key)){
                if(selected.delete(key))removed++;
              }
            }
          }
          failures.push(...result.failed.map(r=>r.key+"："+r.error));
        }
      }catch(error){failures.push(error.message);}
      finally{deleting=false;sync();}
      if(failures.length){
        $("delete-progress").textContent="已删除 "+removed+" 条；部分记录未删除："+failures.join("；");
        $("confirm-delete").disabled=true;toast("部分记录未删除，详情见对话框",true);
      }else{$("delete-dialog").close();toast("已删除 "+removed+" 条所选记录");}
      pending=[];await refresh().catch(()=>{});
      if(failures.length)$("confirm-delete").disabled=true;
    }
    $("select-all-records").addEventListener("click",()=>{for(const [key,r] of rows)if(!locked(r.item))selected.add(key);sync();});
    $("clear-selection").addEventListener("click",()=>{selected.clear();sync();});
    $("delete-selected").addEventListener("click",openDeletion);
    $("confirm-delete").addEventListener("click",confirmDeletion);
    $("cancel-delete").addEventListener("click",()=>$("delete-dialog").close());
    $("delete-dialog").addEventListener("cancel",event=>{if(deleting)event.preventDefault();});
    $("delete-dialog").addEventListener("close",()=>{if(!deleting){pending=[];sync();}});
    $("refresh-records").addEventListener("click",()=>refresh().catch(()=>{}));
    for(const checkbox of document.querySelectorAll("[data-select-group]")){
      checkbox.addEventListener("change",()=>{for(const [key,r] of rows)if(r.target.kind===checkbox.dataset.selectGroup&&!locked(r.item))checkbox.checked?selected.add(key):selected.delete(key);sync();});
    }
    return {refresh,sync,async stageDeletion(targets){
      if(deleting)throw Error("正在执行删除，请等待完成");
      await refresh();
      if(!Array.isArray(targets)||!targets.length)throw Error("请选择记录");
      const ids=targets.map(t=>id(t));
      if(ids.some(key=>!rows.has(key)||locked(rows.get(key).item)))throw Error("记录不存在或仍在采集");
      selected.clear();ids.forEach(key=>selected.add(key));sync();openDeletion();
      return {staged:pending.map(r=>r.target),state:"awaiting_visible_confirmation"};
    }};
  }
  window.PangoRecords={create};
})();

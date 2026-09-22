/* Local workbench. Binary frame conversion runs off the main UI thread. */
(function(){
  "use strict";
  const $=id=>document.getElementById(id), api={token:null};
  // Purpose: default to source samples while the live camera Bayer phase is
  // unverified. Color/averaged previews remain explicit, derived alternatives.
  let status=null, online=false, busy=false, color="raw", lastKey="", workerBusy=false;
  let closed=false, archiveKey="", lastPaint=0, previewErrors=0;
  let rendered=0, renderStart=performance.now(), activeView="live", frameTimer=null, statusTimer=null;
  const recordUI=window.PangoRecords.create({request,previewArchive,toast,getStatus:()=>status,getOnline:()=>online});
  const videoInputUI=window.PangoVideoInputUI.create({toast});
  let recordsLastRefresh=0;
  const archiveWorker=new Worker("/preview-worker.js");
  const worker=new Worker("/preview-worker.js"), title={live:"实时采集",records:"采集记录",settings:"连接设置"};
  function text(id,value){$(id).textContent=value;}
  function toast(message,error=false){$("toast").textContent=message;$("toast").classList.toggle("error",error);$("toast").hidden=false;clearTimeout(toast.timer);toast.timer=setTimeout(()=>$("toast").hidden=true,5000);}
  async function request(path,data,retried=false){
    const opts={cache:"no-store",signal:AbortSignal.timeout(12000)};
    if(data!==undefined){opts.method="POST";opts.headers={"Content-Type":"application/json","X-Pango-Token":api.token};opts.body=JSON.stringify(data);}
    const response=await fetch(path,opts);
    const result=await response.json();
    if(response.status===403&&data!==undefined&&!retried){
      const fresh=await request("/api/session");api.token=fresh.token;update(fresh.status);return request(path,data,true);
    }
    if(!response.ok) throw Error(result.error||"请求失败");
    return result;
  }
  function elapsed(seconds){const s=Math.floor(seconds||0);return (Math.floor(s/60)).toString().padStart(2,"0")+":"+(s%60).toString().padStart(2,"0");}
  function count(value){return Number(value||0).toLocaleString("zh-CN");}
  function showView(view){
    activeView=view;
    for(const name of Object.keys(title)) $("view-"+name).hidden=name!==view;
    document.querySelectorAll(".nav-button").forEach(button=>{const selected=button.dataset.view===view;button.classList.toggle("active",selected);if(selected)button.setAttribute("aria-current","page");else button.removeAttribute("aria-current");});
    text("breadcrumb-view",title[view]);
    if(view==="records") refreshRecords();
    if(view==="settings") videoInputUI.refresh();
  }
  function update(state){
    const sessionChanged=status&&(status.running!==state.running||status.run_id!==state.run_id);
    if(status&&status.run_id!==state.run_id){lastKey="";$("live-canvas").hidden=true;$("video-empty").hidden=false;rendered=0;renderStart=performance.now();}
    status=state;
    const c=state.metrics?.assembly?.counters||{}, rx=state.metrics?.counters||{}, running=state.running;
    const mock=state.config.source_mode==="mock", live=state.signal==="live", hasRun=!!state.run_id;
    const failures=Object.entries(c).reduce((sum,[key,value])=>sum+(key.startsWith("frames_failed_")&&key!=="frames_failed_stopped"?value:0),0)+Number(c.frames_rejected_memory||0);
    const labels={idle:"未开始采集",listening:live?"正在接收完整帧":"等待来源数据",stopping:"正在停止并保存",stopped:"采集已停止",error:"采集发生错误"};
    text("session-state",labels[state.state]||state.state);
    $("session-dot").className="status-dot"+(live?" live":state.error?" error":"");
    $("source-pill").className="pill "+(mock?"mock":"hardware");text("source-pill",mock?"本机模拟":"板端数据 · 未验收");
    text("start-label",mock?"开始模拟":"开始接收");
    $("start").disabled=!online||busy||running;$("stop").disabled=!online||busy||!running;
    $("archive-every").disabled=running||busy;
    $("save-current").disabled=!online||busy||!live;
    text("metric-fps",hasRun?state.complete_fps.toFixed(1):"—");
    text("metric-frames",hasRun?count(c.live_frames_complete):"—");
    text("metric-throughput",hasRun?state.payload_mb_s.toFixed(2):"—");
    text("metric-errors",hasRun?count(c.packets_rejected_crc)+" / "+count(failures):"— / —");
    text("error-hint",state.error||(!hasRun?"等待接收数据":failures?"存在不完整帧，详见运行报告":"按包校验与帧完整性分别统计"));
    text("frame-span",state.metrics?.assembly?.live_first_id==null?"源帧号 —":"源帧 "+state.metrics.assembly.live_first_id+" → "+state.metrics.assembly.live_highwater);
    text("device-id",state.config.device_id);text("bind-address",state.config.bind_ip+":"+state.config.port);text("peer-address",state.config.peer_ip+":"+state.config.peer_port);text("epoch",state.config.stream_epoch);
    text("settings-lock",running?"采集期间连接设置已锁定":"配置仅用于本次服务会话，每次运行均保存配置副本。");
    text("elapsed",elapsed(state.elapsed_seconds));text("transport-pill",running?"UDP 已绑定":"待启动");
    $("transport-pill").className="pill "+(running?"active":"neutral");
    text("video-origin",mock?"MOCK / 模拟来源":"S0 / 板端 RAW8");
    text("source-node",mock?"模拟发送器":"FPGA RAW8");
    text("packet-total",count(rx.datagrams_received)+" 个数据报");
    text("buffer-usage",((state.metrics?.assembly?.buffer_bytes||0)/1048576).toFixed(2)+" MiB 在途");
    text("saved-total",count(state.saved_frames)+" 张已写入");
    text("duplicate-count",count(c.packets_duplicate));text("reorder-count",count(c.packets_out_of_order));
    text("missing-count",count(state.metrics?.assembly?.live_unobserved_ids_in_span));
    text("preview-drops",count(rx.preview_frames_replaced));text("archive-drops",count((rx.archive_frames_rejected||0)+(state.manual_saves_rejected||0)));
    $("stale-label").hidden=(live&&performance.now()-lastPaint<1500)||$("live-canvas").hidden;
    text("stale-label",!running?"采集已停止 · 保留最后画面":live?"浏览器预览等待更新":"超过 1 秒没有完整新帧");
    if(!live)text("preview-rate","预览 0 FPS");
    text("run-footer",state.run_id||"本机服务 · 无云端视频转发");
    const history=state.history||[], points=history.map((p,i)=>((i/(Math.max(1,history.length-1)))*236+2).toFixed(1)+","+(26-Math.min(p.fps,60)/60*24).toFixed(1));
    $("fps-line").setAttribute("d",points.length>1?"M"+points.join(" L"):"");
    const events=$("event-list");events.replaceChildren();
    for(const event of (state.events||[]).slice(-5).reverse()){
      const li=document.createElement("li"),time=document.createElement("time"),body=document.createElement("span");
      li.className=event.kind;time.textContent=new Date(event.time).toLocaleTimeString("zh-CN",{hour12:false});body.textContent=event.message;li.append(time,body);events.append(li);
    }
    if(!events.children.length){const li=document.createElement("li");li.className="empty-row";li.textContent="启动采集后显示运行事件";events.append(li);}
    $("config-fields").disabled=running;$("apply-config").disabled=running||busy;
    recordUI.sync();if(sessionChanged)refreshRecords();
  }
  async function init(){
    try{
      const result=await request("/api/session");api.token=result.token;online=true;$("connection-alert").hidden=true;text("server-health","服务已连接");update(result.status);fillConfig(result.status.config);refreshRecords();
    }catch(error){offline();}
  }
  function offline(){online=false;recordUI.sync();$("connection-alert").hidden=false;text("server-health","服务未连接");$("start").disabled=true;$("stop").disabled=true;$("save-current").disabled=true;if(!$("live-canvas").hidden){$("stale-label").hidden=false;text("stale-label","服务连接已中断");}}
  async function poll(){
    if(!document.hidden){try{const state=await request("/api/status");if(!online){await init();}else update(state);}catch(error){offline();}}
    if(online&&activeView==="records"&&!document.hidden&&performance.now()-recordsLastRefresh>3000)refreshRecords();
    if(!closed)statusTimer=setTimeout(poll,500);
  }
  async function framePoll(){
    try{
      if(online&&status?.signal==="live"&&!document.hidden&&activeView==="live"&&!workerBusy){
        const response=await fetch("/api/frame?after="+encodeURIComponent(lastKey),{cache:"no-store",signal:AbortSignal.timeout(3000)});
        if(response.status===200){
          const meta=JSON.parse(response.headers.get("X-Frame-Info")), buffer=await response.arrayBuffer();
          if(meta.run_id===status.run_id){previewErrors=0;lastKey=meta.key;workerBusy=true;worker.postMessage({buffer,meta,mode:color,target:"live"},[buffer]);}
        }else if(response.status!==204)throw Error("预览读取失败");
      }
    }catch(error){previewErrors++;if(previewErrors===3)toast("预览暂时无法读取；接收状态仍独立更新",true);}
    if(!closed)frameTimer=setTimeout(framePoll,125);
  }
  worker.onmessage=event=>{
    const result=event.data;workerBusy=false;
    if(result.error){toast(result.error,true);return;}
    if(result.target==="live"&&result.meta.run_id!==status?.run_id)return;
    const canvas=result.target==="archive"?$("archive-canvas"):$("live-canvas");
    canvas.width=result.width;canvas.height=result.height;
    canvas.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(result.pixels),result.width,result.height),0,0);
    if(result.target==="live"){
      lastPaint=performance.now();canvas.hidden=false;$("video-empty").hidden=true;
      text("frame-identity","源帧 "+result.meta.frame_id+" · "+result.meta.width+" × "+result.meta.height+" RAW8 · CRC ✓");
      rendered++;const dt=(performance.now()-renderStart)/1000;
      if(dt>=1){text("preview-rate","预览 "+(rendered/dt).toFixed(1)+" FPS");rendered=0;renderStart=performance.now();}
    }
  };
  archiveWorker.onmessage=event=>{const r=event.data;if(r.meta&&r.meta.key!==archiveKey)return;if(r.error){text("archive-detail",r.error);return;}const canvas=$("archive-canvas");canvas.width=r.width;canvas.height=r.height;canvas.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(r.pixels),r.width,r.height),0,0);canvas.hidden=false;};
  archiveWorker.onerror=()=>text("archive-detail","归档预览转换失败");
  worker.onerror=()=>{workerBusy=false;toast("预览转换失败，请刷新页面重试",true);};
  async function action(path,data={}){
    if(busy)throw Error("上一项操作仍在处理");
    busy=true;if(status)update(status);
    try{const result=await request(path,data);if(result.config)update(result);else toast(result.status==="queued"?"源帧 "+result.frame_id+" 已加入归档队列":"源帧 "+result.frame_id+" 已保存或正在保存");if(path==="/api/stop")refreshRecords();return result;}
    catch(error){toast(error.message,true);throw error;}
    finally{busy=false;if(status)update(status);}
  }
  function fillConfig(config){
    const fields={"cfg-mode":"source_mode","cfg-device":"device_id","cfg-epoch":"stream_epoch","cfg-bind":"bind_ip","cfg-port":"port","cfg-peer":"peer_ip","cfg-peer-port":"peer_port","cfg-bayer":"bayer_code","cfg-buffer":"receive_buffer_bytes","cfg-width":"width","cfg-height":"height"};
    for(const [id,key] of Object.entries(fields))$(id).value=config[key]??"";
    settingsHint();
  }

  async function previewArchive(item){
    try{
      archiveKey=item.key;$("archive-canvas").hidden=true;text("archive-title","原始数据回看 · 源帧 "+item.frame_id);
      text("archive-detail","正在读取并检查原始文件…");$("archive-dialog").showModal();
      const response=await fetch("/api/archive/pixels?key="+encodeURIComponent(item.key),{cache:"no-store",signal:AbortSignal.timeout(12000)});
      if(!response.ok){const error=await response.json();throw Error(error.error||"归档读取失败");}
      const meta=JSON.parse(response.headers.get("X-Frame-Info")),buffer=await response.arrayBuffer();
      text("archive-detail",(meta.source_mode==="mock"?"MOCK 合成数据":"来源："+meta.source_mode)+" · "+meta.width+" × "+meta.height+" "+meta.pixel_format+" · SHA-256 "+meta.sha256+" · PC 派生预览，不作硬件精度结论");
      if(meta.key!==archiveKey)return;
      archiveWorker.postMessage({buffer,meta,mode:"color",target:"archive"},[buffer]);
    }catch(error){text("archive-detail",error.message);toast(error.message,true);}
  }
  async function refreshRecords(){recordsLastRefresh=performance.now();return recordUI.refresh().catch(()=>{});}
  function settingsHint(){
    const mock=$("cfg-mode").value==="mock";
    $("settings-mode").className="pill "+(mock?"mock":"hardware");text("settings-mode",mock?"本机模拟":"板端 · 待验证");
    text("settings-note",mock?"本机模拟通过实际 UDP / PRAW 编解码链路，不计作硬件验收。":"请填写实际设备身份、PC 网卡地址、FPGA 地址和回读的源代次。界面设置不会向 FPGA 写入参数。");
  }
  $("cfg-mode").addEventListener("change",()=>{
    const mock=$("cfg-mode").value==="mock";
    $("cfg-device").value=mock?"MOCK-OV5640":"";
    $("cfg-epoch").value=mock?"1":"";
    $("cfg-bind").value=mock?"127.0.0.1":"";
    $("cfg-peer").value=mock?"127.0.0.1":"";
    settingsHint();
  });
  $("config-form").addEventListener("submit",async event=>{
    event.preventDefault();if(busy||status?.running)return;
    const config=Object.fromEntries(new FormData(event.currentTarget));
    for(const key of ["port","peer_port","bayer_code","receive_buffer_bytes","width","height"])config[key]=Number(config[key]);
    busy=true;if(status)update(status);
    try{fillConfig(await request("/api/config",config));update(await request("/api/status"));toast("连接设置已应用，下次采集生效");}
    catch(error){toast(error.message,true);}finally{busy=false;if(status)update(status);}
  });

  document.querySelectorAll("[data-view]").forEach(button=>button.addEventListener("click",()=>showView(button.dataset.view)));
  document.querySelectorAll("[data-color]").forEach(button=>button.addEventListener("click",()=>{
    color=button.dataset.color;lastKey="";document.querySelectorAll("[data-color]").forEach(b=>{b.classList.toggle("selected",b===button);b.setAttribute("aria-pressed",String(b===button));});
  }));
  $("start").addEventListener("click",()=>action("/api/start",{archive_every:Number($("archive-every").value)}).catch(()=>{}));
  $("stop").addEventListener("click",()=>action("/api/stop").catch(()=>{}));
  $("save-current").addEventListener("click",()=>action("/api/save").catch(()=>{}));
  $("reconnect").addEventListener("click",init);
  $("close-dialog").addEventListener("click",()=>$("archive-dialog").close());
  $("archive-dialog").addEventListener("close",()=>{archiveKey="";});
  setInterval(()=>text("clock",new Date().toLocaleTimeString("zh-CN",{hour12:false})),1000);

  // Optional WebMCP surface: the same visible actions and receiver state.
  const toolLifetime=new AbortController();
  function registerWorkbenchTools(){
    if(!document.modelContext?.registerTool)return;
    const schema={type:"object",properties:{},additionalProperties:false};
    const tools=[
      ["pango_receiver_status","Read the current local RAW8 receiver status.",true,async()=>{const value=await request("/api/status");update(value);return value;}],
      ["pango_start_mock","Start the configured local mock UDP capture. Refuses a hardware source.",false,async()=>{
        if(status?.config.source_mode!=="mock")throw Error("请先在连接设置中选择本机模拟");
        showView("live");return action("/api/start",{archive_every:Number($("archive-every").value)});
      }],
      ["pango_stop_capture","Stop the current capture and drain its archive queue.",false,async()=>action("/api/stop")],
      ["pango_save_latest_raw","Archive the latest complete raw frame with its source metadata.",false,async()=>action("/api/save")]
    ];
    for(const [name,description,readOnlyHint,execute] of tools){
      try{void Promise.resolve(document.modelContext.registerTool({name,description,inputSchema:schema,annotations:{readOnlyHint},execute:async args=>{
        if(args==null||typeof args!=="object"||Array.isArray(args)||Object.keys(args).length)throw Error("此操作不接受参数");
        const result=await execute();return {content:[{type:"text",text:JSON.stringify(result)}]};
      }},{signal:toolLifetime.signal})).catch(error=>console.warn("WebMCP registration unavailable",name,error));}catch(error){console.warn("WebMCP registration unavailable",name,error);}
    }
  }
  window.addEventListener("pagehide",()=>{closed=true;videoInputUI.destroy();toolLifetime.abort();clearTimeout(frameTimer);clearTimeout(statusTimer);worker.terminate();archiveWorker.terminate();});

  window.addEventListener("pageshow",event=>{if(event.persisted)location.reload();});
  init().then(()=>{registerWorkbenchTools();poll();framePoll();});
})();

/* Local workbench. Binary frame conversion runs off the main UI thread. */
(function(){
  "use strict";
  const $=id=>document.getElementById(id), api={token:null};
  // Purpose: default to source samples while the live camera Bayer phase is
  // unverified. Color/averaged previews remain explicit, derived alternatives.
  let status=null, online=false, busy=false, color="raw", lastKey="", workerBusy=false;
  // Purpose: label the exact stage identified by each received packet, not a
  // presumed S0 merely because the payload has one RAW8 byte per pixel.
  let latestStage=null;
  let closed=false, archiveKey="", lastPaint=0, previewErrors=0;
  let rendered=0, renderStart=performance.now(), activeView="live", frameTimer=null, statusTimer=null;
  // Measure canvas presentations separately from complete source frames.
  let frameFetching=false, previewRateTimer=null,pendingPreview=null,totalPresented=0,lastPresentedKey="";
  let streamAbort=null;
  let previewGeneration=0,streamConfig=null,drainWait=null;
  // Keep only bounded aggregates. No per-frame disk log or GPU readback runs
  // in the live path; clock estimates always retain their RTT uncertainty.
  const previewDiagnostics=window.PangoPreviewDiagnostics.create();
  let workerQueue={executing:0,pending:0,networkCredit:0,pendingBytes:0},workerQueueAt=performance.now();
  window.pangoPreviewDiagnostics=()=>previewDiagnostics.snapshot(workerPull?
    {...workerQueue,scope:"last_observed_worker_state",sampleAgeMs:performance.now()-workerQueueAt}:
    {executing:Number(workerBusy),pending:Number(!!pendingPreview),scope:"main_thread"});
  let clockTimer=null,longTaskObserver=null,hostMetricsTimer=null;
  async function pollHostMetrics(){
    // Query the service host, not browser CPU. Hidden tabs avoid extra polling,
    // and unavailable readings clear the old percentage rather than displaying 0%.
    if(!document.hidden){
      let value=null;
      try{value=(await request("/api/system")).cpu_percent;}catch{}
      const valid=Number.isFinite(value)&&value>=0&&value<=100;
      text("host-cpu-value",valid?`${value.toFixed(1)}%`:"—");
      $("host-cpu-bar").hidden=!valid;
      if(valid)$("host-cpu-bar").value=value;
    }
    if(!closed)hostMetricsTimer=setTimeout(pollHostMetrics,1000);
  }
  async function syncPreviewClock(){
    try{for(let i=0;i<3;i++){
      const sent=performance.now(),value=await request("/api/clock");
      previewDiagnostics.sync(sent,performance.now(),value);
    }}catch{/* Diagnostic failure must never stop reception or display. */}
    if(!closed)clockTimer=setTimeout(syncPreviewClock,30000);
  }
  if(typeof PerformanceObserver!=="undefined")try{
    longTaskObserver=new PerformanceObserver(list=>{for(const entry of list.getEntries())previewDiagnostics.longTask(entry.duration);});
    longTaskObserver.observe({type:"longtask",buffered:false});
  }catch{/* Browsers without long-task reporting keep other measurements. */}
  // A bitmap presentation transfers ownership instead of expanding/copying a
  // full RGBA frame on the UI thread that also schedules the HDMI video.
  const liveCanvas=$("live-canvas");
  const bitmapContext=typeof OffscreenCanvas!=="undefined"&&
    typeof OffscreenCanvas.prototype.transferToImageBitmap==="function"?liveCanvas.getContext("bitmaprenderer"):null;
  const liveContext=bitmapContext?null:liveCanvas.getContext("2d",{alpha:false});
  const workerPull=!!bitmapContext&&typeof WebSocket!=="undefined";
  // Cache preview geometry on resize instead of forcing a layout read for
  // every frame. A hidden view keeps its last nonzero display width.
  const videoSurface=$("video-surface");
  let displayWidth=videoSurface.getBoundingClientRect().width,lastIdentityUpdate=0,eventsKey=null;
  const surfaceResize=new ResizeObserver(entries=>{
    const width=entries[0]?.contentRect.width;if(width>0){
      const before=previewScale();displayWidth=width;
      // Crossing the native/reduced threshold renegotiates pixels before
      // another fetch; a late bitmap from the old size cannot overwrite it.
      if(before!==previewScale())invalidatePreview();
    }
  });
  surfaceResize.observe(videoSurface);
  const recordUI=window.PangoRecords.create({request,previewArchive,toast,getStatus:()=>status,getOnline:()=>online});
  const videoInputUI=window.PangoVideoInputUI.create({toast});
  // The board panel coordinates physical startup; the generic mock stays explicit.
  const boardUI=window.PangoBoardLink.create({request,video:videoInputUI.controller,toast});
  // Board controls own only UART and the FPGA metadata layer, not video capture.
  const boardGeometry=window.PangoBoardGeometry.create({request,videoUI:videoInputUI});
  // Recovery lives in the server; this widget only configures and observes it.
  const boardAutoload=window.PangoBoardAutoload.create({request});
  let recordsLastRefresh=0;
  const archiveWorker=new Worker("/preview-worker.js");
  // Board setup is a separate view; live keeps its preview lifecycle and MCU state.
  const worker=new Worker("/preview-worker.js"), title={live:"采集与控制",board:"板卡设置",records:"采集记录",settings:"连接设置"};
  worker.postMessage({type:"init-live",bitmap:!!bitmapContext,pull:workerPull});
  // Repeated stage/status labels should not invalidate layout while both
  // video surfaces are being composited. Changed values still update normally.
  function text(id,value){const node=$(id),next=String(value);if(node.textContent!==next)node.textContent=next;}
  function toast(message,error=false){$("toast").textContent=message;$("toast").classList.toggle("error",error);$("toast").hidden=false;clearTimeout(toast.timer);toast.timer=setTimeout(()=>$("toast").hidden=true,5000);}
  // Native fullscreen admits one preview at a time. Only the containing panel
  // changes layout: capture tracks, workers and pixel overlays keep their owners.
  const fullscreenButtons=[...document.querySelectorAll("[data-fullscreen]")];
  let fullscreenBusy=false,fullscreenTrigger=null;
  function syncFullscreen(){
    for(const button of fullscreenButtons){
      const panel=$(button.dataset.fullscreen),active=document.fullscreenElement===panel;
      const label=active?"退出全屏":`全屏查看${button.dataset.previewName}预览`;
      button.disabled=fullscreenBusy||!document.fullscreenEnabled||typeof panel.requestFullscreen!=="function";
      button.setAttribute("aria-pressed",String(active));button.setAttribute("aria-label",label);
      button.title=active?"退出全屏（Esc）":button.disabled&&!fullscreenBusy?"当前浏览器不支持全屏":label;
      button.querySelector("span").textContent=active?"退出全屏":"全屏";
      button.querySelector("use").setAttribute("href",active?"#i-fullscreen-exit":"#i-fullscreen");
    }
    // Browser Esc and the visible exit button share the same state/focus reset.
    if(!fullscreenBusy&&!document.fullscreenElement&&fullscreenTrigger){
      fullscreenTrigger.focus({preventScroll:true});fullscreenTrigger=null;
    }
  }
  for(const button of fullscreenButtons)button.addEventListener("click",async()=>{
    if(fullscreenBusy)return;
    const panel=$(button.dataset.fullscreen);fullscreenBusy=true;syncFullscreen();
    try{
      if(document.fullscreenElement===panel)await document.exitFullscreen();
      else{
        if(document.fullscreenElement)await document.exitFullscreen();
        fullscreenTrigger=button;
        await panel.requestFullscreen({navigationUI:"hide"});
      }
    }catch{
      fullscreenTrigger=null;toast("无法进入全屏，请重新点击全屏按钮。",true);
    }finally{fullscreenBusy=false;syncFullscreen();}
  });
  document.addEventListener("fullscreenchange",syncFullscreen);syncFullscreen();
  async function request(path,data,retried=false){
    // Device enumeration and graceful worker/receiver shutdown can outlast a frame request.
    const opts={cache:"no-store",signal:AbortSignal.timeout(path.startsWith("/api/board/")?25000:12000)};
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
    // A placeholder's settings link can navigate while enlarged; leave the
    // fullscreen panel before its live-view ancestor becomes hidden.
    if(view!=="live"&&document.fullscreenElement?.classList.contains("video-panel")){
      void document.exitFullscreen().catch(()=>{});
    }
    activeView=view;
    // A hidden view must release the HTTP stream and its bounded server slot.
    if(view!=="live")invalidatePreview();
    for(const name of Object.keys(title)) $("view-"+name).hidden=name!==view;
    document.querySelectorAll(".nav-button").forEach(button=>{const selected=button.dataset.view===view;button.classList.toggle("active",selected);if(selected)button.setAttribute("aria-current","page");else button.removeAttribute("aria-current");});
    text("breadcrumb-view",title[view]);
    if(view==="records") refreshRecords();
    if(view==="settings") videoInputUI.refresh();
  }
  function update(state){
    const sessionChanged=status&&(status.running!==state.running||status.run_id!==state.run_id);
    if(status?.running&&!state.running)invalidatePreview();
    if(status&&status.run_id!==state.run_id){invalidatePreview();latestStage=null;$("live-canvas").hidden=true;$("video-empty").hidden=false;videoInputUI.setNetworkFrame(null);rendered=0;renderStart=performance.now();}
    status=state;
    if(state.signal!=="live")boardGeometry.setNetworkFrame(null);
    const c=state.metrics?.assembly?.counters||{}, rx=state.metrics?.counters||{}, running=state.running;
    // A verified fast path and a safe fallback are both valid, but must remain
    // distinguishable when diagnosing receive loss under desktop load.
    const backend=state.metrics?.backend;
    text("receive-backend",!backend?"接收后端待启动":backend.native_batch_parser?
      `原生校验 · 批次 ${backend.receive_batch_size}`:`参考校验 · ${backend.native_parser_status?.reason||"未启用原生模块"}`);
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
    text("video-origin",mock?"MOCK / 模拟来源":latestStage==="fpga_enhanced_raw8"?"FPGA 增强 / Bayer RAW8":"S0 / 板端 RAW8");
    text("raw-stage-note",latestStage==="fpga_enhanced_raw8"?"FPGA 板侧增强 RAW8 · 缩小预览做 Bayer 抗混叠 · RAW 归档不变 · 非原始 S0":"PC 基础可视化 · 不等同于 FPGA S1");
    text("source-node",mock?"模拟发送器":"FPGA RAW8");
    text("packet-total",count(rx.datagrams_received)+" 个数据报");
    text("buffer-usage",((state.metrics?.assembly?.buffer_bytes||0)/1048576).toFixed(2)+" MiB 在途");
    text("saved-total",count(state.saved_frames)+" 张已写入");
    text("duplicate-count",count(c.packets_duplicate));text("reorder-count",count(c.packets_out_of_order));
    text("missing-count",count(state.metrics?.assembly?.live_unobserved_ids_in_span));
    text("preview-drops",count(rx.preview_frames_replaced));text("archive-drops",count((rx.archive_frames_rejected||0)+(state.manual_saves_rejected||0)));
    $("stale-label").hidden=(live&&performance.now()-lastPaint<1500)||$("live-canvas").hidden;
    text("stale-label",!running?"采集已停止 · 保留最后画面":live?"浏览器预览等待更新":"超过 1 秒没有完整新帧");
    text("receive-rate",`完整接收 ${live?state.complete_fps.toFixed(1):"0.0"} FPS`);
    text("run-footer",state.run_id||"本机服务 · 无云端视频转发");
    const history=state.history||[], points=history.map((p,i)=>((i/(Math.max(1,history.length-1)))*236+2).toFixed(1)+","+(26-Math.min(p.fps,60)/60*24).toFixed(1));
    $("fps-line").setAttribute("d",points.length>1?"M"+points.join(" L"):"");
    // Events usually stay unchanged across status polls. Rebuild their DOM
    // only for a new list, keeping the same order and visible event contents.
    const recentEvents=(state.events||[]).slice(-5).reverse(),nextEventsKey=JSON.stringify(recentEvents);
    if(nextEventsKey!==eventsKey){
      eventsKey=nextEventsKey;const events=$("event-list");events.replaceChildren();
      for(const event of recentEvents){
        const li=document.createElement("li"),time=document.createElement("time"),body=document.createElement("span");
        li.className=event.kind;time.textContent=new Date(event.time).toLocaleTimeString("zh-CN",{hour12:false});body.textContent=event.message;li.append(time,body);events.append(li);
      }
      if(!events.children.length){const li=document.createElement("li");li.className="empty-row";li.textContent="启动采集后显示运行事件";events.append(li);}
    }
    $("config-fields").disabled=running;$("apply-config").disabled=running||busy;
    recordUI.sync();if(sessionChanged)refreshRecords();
  }
  async function init(){
    try{
      const result=await request("/api/session");api.token=result.token;online=true;$("connection-alert").hidden=true;text("server-health","服务已连接");update(result.status);fillConfig(result.status.config);refreshRecords();
    }catch(error){offline();}
  }
  function offline(){online=false;invalidatePreview();recordUI.sync();$("connection-alert").hidden=false;text("server-health","服务未连接");$("start").disabled=true;$("stop").disabled=true;$("save-current").disabled=true;if(!$("live-canvas").hidden){$("stale-label").hidden=false;text("stale-label","服务连接已中断");}}
  async function poll(){
    // UI polls need counters, not the full diagnostic loss history.
    if(!document.hidden){try{const state=await request("/api/status?summary=1");if(!online){await init();}else update(state);}catch(error){offline();}}
    if(online&&activeView==="records"&&!document.hidden&&performance.now()-recordsLastRefresh>3000)refreshRecords();
    if(!closed)statusTimer=setTimeout(poll,500);
  }
  async function framePoll(){
    if(closed||frameFetching)return;
    if(workerPull){
      // Fetch/parsing and GPU preparation stay in a Worker. The UI owns the
      // final bitmap handoff and acknowledges it before the next credit.
      if(online&&status?.signal==="live"&&!document.hidden&&activeView==="live"){
        frameFetching=true;
        worker.postMessage({type:"start-live",mode:color,scale:previewScale(),displayWidth,
          run_id:status.run_id,generation:previewGeneration});
      }else frameTimer=setTimeout(framePoll,100);
      return;
    }
    frameFetching=true;
    try{
      if(online&&status?.signal==="live"&&!document.hidden&&activeView==="live"){
        // Keep full-resolution reception/archives while transferring the same
        // Bayer-cell visualization already used by the smaller on-screen view.
        const generation=previewGeneration;
        streamAbort=new AbortController();
        const streamMode=color,streamScale=previewScale();
        streamConfig={mode:streamMode,scale:streamScale,generation};
        // One finite credit uses a persistent HTTP connection. It overlaps
        // conversion while maintaining only one executing and one pending job.
        if(workerBusy&&pendingPreview)await new Promise(resolve=>{drainWait=resolve;});
        if(generation!==previewGeneration||closed||document.hidden||activeView!=="live")return;
        const response=await fetch(`/api/preview?wait=500&after=${encodeURIComponent(lastKey)}&mode=${streamMode}&downscale=${streamScale}`,{cache:"no-store",signal:streamAbort.signal});
        if(response.status===204)return;
        if(!response.ok)throw Error("预览读取失败");
        const readStart=performance.now(),meta=JSON.parse(response.headers.get("X-Frame-Info"));
        const buffer=await response.arrayBuffer();
        if(generation!==previewGeneration||meta.run_id!==status?.run_id||meta.key===lastKey)return;
        previewErrors=0;lastKey=meta.key;
        const job={buffer,meta,mode:streamMode,target:"live",displayWidth,receivedMs:performance.now(),
          fetchMs:performance.now()-readStart,generation};
        if(workerBusy){if(pendingPreview)previewDiagnostics.replace();pendingPreview=job;}else submitPreview(job);
      }
    }catch(error){if(error.name!=="AbortError"){previewErrors++;if(previewErrors===3)toast("预览暂时无法读取；接收状态仍独立更新",true);}}
    finally{frameFetching=false;streamConfig=null;
    // Pipeline one fetch with one conversion. Only the newest pending RAW is
    // kept, so a slow display never builds an unbounded stale-frame queue.
    if(!closed)frameTimer=setTimeout(framePoll,status?.signal==="live"&&!document.hidden&&activeView==="live"?0:100);
    }
  }
  function previewScale(){return color==="raw"&&displayWidth>=(status?.config.width||1920)?1:2;}
  function invalidatePreview(){
    previewGeneration++;lastKey="";pendingPreview=null;streamAbort?.abort();
    workerQueue={executing:0,pending:0,networkCredit:0,pendingBytes:0};workerQueueAt=performance.now();
    drainWait?.();drainWait=null;previewDiagnostics.reset();
    if(workerPull){
      worker.postMessage({type:"stop-live"});frameFetching=false;
      clearTimeout(frameTimer);if(!closed)frameTimer=setTimeout(framePoll,0);
    }
  }
  function submitPreview(job){
    workerBusy=true;job.queueMs=performance.now()-job.receivedMs;
    // timeOrigin translates Window/Worker clocks onto the browser's shared
    // epoch timeline. It is never directly paired with the host clock.
    job.postedEpochMs=performance.timeOrigin+performance.now();
    worker.postMessage(job,[job.buffer]);
  }
  document.addEventListener("visibilitychange",()=>{if(document.hidden)invalidatePreview();});
  worker.onmessage=event=>{
    const arrivedEpochMs=performance.timeOrigin+performance.now();
    const result=event.data;workerBusy=false;
    if(result.type==="preview-queue"){
      if(result.generation===previewGeneration){
        workerQueue={executing:result.executing,pending:result.pending,networkCredit:result.networkCredit,pendingBytes:result.pendingBytes};
        workerQueueAt=performance.now();
      }
      return;
    }
    if(result.type==="stream-end"){
      if(result.generation===previewGeneration){frameFetching=false;clearTimeout(frameTimer);if(!closed)frameTimer=setTimeout(framePoll,100);}
      return;
    }
    if(pendingPreview&&!closed){const job=pendingPreview;pendingPreview=null;
      if(job.meta.run_id===status?.run_id&&job.generation===previewGeneration)submitPreview(job);
    }
    // A consumed pending job frees one credit even while its conversion runs.
    drainWait?.();drainWait=null;
    if(result.error){toast(result.error,true);return;}
    if(result.target==="live"&&(result.meta.run_id!==status?.run_id||result.generation!==previewGeneration||document.hidden||activeView!=="live")){
      result.bitmap?.close();previewDiagnostics.reject();return;
    }
    const canvas=result.target==="archive"?$("archive-canvas"):liveCanvas;
    const paintStart=performance.now();
    // Resizing resets the backing store; do it only when geometry changes.
    if(canvas.width!==result.width)canvas.width=result.width;
    if(canvas.height!==result.height)canvas.height=result.height;
    if(result.bitmap)bitmapContext.transferFromImageBitmap(result.bitmap);
    else (canvas===liveCanvas?liveContext:canvas.getContext("2d")).putImageData(new ImageData(new Uint8ClampedArray(result.pixels),result.width,result.height),0,0);
    if(result.target==="live"){
      lastPaint=performance.now();canvas.hidden=false;$("video-empty").hidden=true;
      // Marker source pixels follow the complete native RAW metadata, not the
      // reduced display raster. The overlay caches unchanged geometry.
      videoInputUI.setNetworkFrame({width:result.width,height:result.height,
        sourceWidth:result.meta.width,sourceHeight:result.meta.height});
      boardGeometry.setNetworkFrame({width:result.width,height:result.height,
        sourceWidth:result.meta.width,sourceHeight:result.meta.height,
        stream_epoch:result.meta.stream_epoch,source_mode:result.meta.source_mode});
      latestStage=result.meta.source_stage;
      // Keep the source identity readable at five updates per second; actual
      // pixel presentation and the FPS counters below still count every frame.
      if(lastPaint-lastIdentityUpdate>=200){
        text("frame-identity","源帧 "+result.meta.frame_id+" · "+result.meta.width+" × "+result.meta.height+" RAW8 · CRC ✓");
        lastIdentityUpdate=lastPaint;
      }
      text("video-origin",latestStage==="fpga_enhanced_raw8"?"FPGA 增强 / Bayer RAW8":"S0 / 板端 RAW8");
      text("raw-stage-note",latestStage==="fpga_enhanced_raw8"?"FPGA 板侧增强 RAW8 · 缩小预览做 Bayer 抗混叠 · RAW 归档不变 · 非原始 S0":"PC 基础可视化 · 不等同于 FPGA S1");
      // Repainting the same frame after a mode change is not a new source frame.
      if(result.meta.key!==lastPresentedKey){rendered++;totalPresented++;lastPresentedKey=result.meta.key;}
      // Diagnostic counters measure each stage without cluttering the UI.
      canvas.dataset.framesPresented=String(totalPresented);
      canvas.dataset.fetchMs=String(result.fetchMs);
      canvas.dataset.convertMs=String(result.convertMs);
      canvas.dataset.paintMs=String(performance.now()-paintStart);
      canvas.dataset.workerPaintMs=String(result.workerPaintMs||0);
      canvas.dataset.renderer=result.renderer||"main-2d";
      previewDiagnostics.record({meta:result.meta,mode:color,width:result.width,height:result.height,
        fetchMs:result.fetchMs,convertMs:result.convertMs,workerPaintMs:result.workerPaintMs||0,
        queueMs:result.queueMs,workerWaitMs:result.workerWaitMs,paintMs:performance.now()-paintStart,renderer:canvas.dataset.renderer,
        bitmapTransferMs:result.bitmapTransferMs,
        previewDroppedBeforeGpu:result.previewDroppedBeforeGpu,
        workerToMainMs:Number.isFinite(result.bitmapPostedEpochMs)?Math.max(0,arrivedEpochMs-result.bitmapPostedEpochMs):null,
        uploadBytes:result.uploadBytes,directTexture:result.directTexture,generation:result.generation});
      // The producer cannot deliver another bitmap until this one was painted.
      if(workerPull)worker.postMessage({type:"preview-painted",generation:result.generation});
    }
  };
  archiveWorker.onmessage=event=>{const r=event.data;if(r.meta&&r.meta.key!==archiveKey)return;if(r.error){text("archive-detail",r.error);return;}const canvas=$("archive-canvas");canvas.width=r.width;canvas.height=r.height;canvas.getContext("2d").putImageData(new ImageData(new Uint8ClampedArray(r.pixels),r.width,r.height),0,0);canvas.hidden=false;};
  archiveWorker.onerror=()=>text("archive-detail","归档预览转换失败");
  worker.onerror=()=>{workerBusy=false;pendingPreview=null;drainWait?.();drainWait=null;toast("预览转换失败，请刷新页面重试",true);};
  // A timer expires the FPS to zero during stalls, even if no new frame arrives.
  previewRateTimer=setInterval(()=>{const now=performance.now(),dt=(now-renderStart)/1000;
    text("preview-rate",`绘制 ${(rendered/dt).toFixed(1)} FPS`);
    $("preview-rate").title="完整帧提交 Canvas 的速率；不证明显示器发光、远程桌面或 FPGA 唯一结果帧率";
    rendered=0;renderStart=now;},1000);
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
    color=button.dataset.color;invalidatePreview();document.querySelectorAll("[data-color]").forEach(b=>{b.classList.toggle("selected",b===button);b.setAttribute("aria-pressed",String(b===button));});
  }));
  $("start").addEventListener("click",()=>action("/api/start",{archive_every:Number($("archive-every").value)}).catch(()=>{}));
  $("stop").addEventListener("click",()=>action("/api/stop").catch(()=>{}));
  $("save-current").addEventListener("click",()=>action("/api/save").catch(()=>{}));
  $("reconnect").addEventListener("click",init);
  $("close-dialog").addEventListener("click",()=>$("archive-dialog").close());
  $("archive-dialog").addEventListener("close",()=>{archiveKey="";});
  setInterval(()=>text("clock",new Date().toLocaleTimeString("zh-CN",{hour12:false})),1000);

  // MCU feedback is cached by the backend; browser refresh never renews the
  // lease itself. Each motion is an explicit operator action, not an input event.
  // Gantry targets are 0..100% of travel; gimbal targets may be any 0.1° value,
  // but one command must change an axis by at least 3° or the servo ignores it
  // while the firmware still reports completion. The backend enforces the same
  // rule against live feedback; this page only saves the operator a round trip.
  const mcuStepMdeg=3000;
  let mcuPending=0,mcuClosed=false,mcuTimer=null,mcuState=null,mcuQueued=null;
  function renderMCU(state){
    mcuState=state;
    const angles=state.angles,xyz=state.state?.xyz_normalized_micro||[];
    const angle=v=>v==null?"无效 / 未就绪":`${v.toFixed(3)}°`;
    const travel=v=>v==null?"无效 / 未就绪":`${(v/1e6).toFixed(2)}%`;
    text("mcu-feedback",state.connected?"MCU 已连接":"MCU 未连接");
    text("mcu-current-x",state.connected?travel(xyz[0]):"—");
    // Firmware logical axis 2 is the dual-motor gantry (site Z) and axis 3 the
    // cantilever extension (site Y); the labels keep the site naming.
    text("mcu-current-y",state.connected?travel(xyz[2]):"—");
    text("mcu-current-z",state.connected?travel(xyz[1]):"—");
    text("mcu-current-pitch",state.connected?angle(angles?.pitch):"—");
    text("mcu-current-yaw",state.connected?angle(angles?.yaw):"—");
    text("mcu-state",state.connected?`反馈年龄 ${state.age_ms} ms · ${["空闲","运动中","回正中","稳定等待","保留","故障"][state.state?.motion_state]||"未知状态"}`:"等待读取真实舵机反馈");
    // Long zero registration runs on the server; only the emergency stop stays
    // reachable while another action or the zero final reply is pending.
    const zeroPending=state.zero_operation?.status==="pending";
    for(const b of document.querySelectorAll("[data-mcu]")){
      const action=b.dataset.mcu;
      const blocked=zeroPending&&["move","gantry","home","zero","confirm"].includes(action);
      b.disabled=!state.connected||blocked||(mcuPending&&action!=="stop");
    }
    $("mcu-connect").disabled=mcuPending||state.connected||!$("mcu-port").value;$("mcu-port").disabled=mcuPending||state.connected;
    if(state.error)text("mcu-message",state.error);
    else if(state.state?.fault_code)text("mcu-message",`MCU 故障 ${state.state.fault_code}，请核对设备状态`);
    else if(state.zero_operation)text("mcu-message",state.zero_operation.message);
    else if(state.last_command)text("mcu-message",state.last_command.message);
    else if(state.last_notice)text("mcu-message",`MCU 通知：${state.last_notice.text}`);
    else if(state.state)text("mcu-message",`反馈年龄 ${state.age_ms} ms · 运动状态 ${state.state.motion_state} · 故障 ${state.state.fault_code} · 指令接受不等于到位`);
  }
  // Compare a target with live feedback in whole millidegrees so the 3° gate
  // stays exact and never depends on float representation.
  function mcuGap(field){
    const axis=field==="mcu-pitch"?"pitch":"yaw";
    const target=Number($(field).value),current=mcuState?.angles?.[axis];
    if(!Number.isFinite(target)||current==null)return null;
    return Math.abs(Math.round(target*1000)-Math.round(current*1000));
  }
  // Only explicit coordinate/angle dispatches wait three seconds. A monotonic
  // deadline prevents an early timer from sending; cancel/stop/pagehide revoke
  // the pending promise before any motion request reaches the service.
  function cancelMCUSend(message="已取消待发指令"){
    const queued=mcuQueued;if(!queued)return;
    mcuQueued=null;clearTimeout(queued.timer);queued.resolve(false);
    $("mcu-cancel-send").hidden=true;text("mcu-dispatch-status",message);
  }
  function waitMCUSend(action){
    return new Promise(resolve=>{
      const queued={resolve,deadline:performance.now()+3000,timer:null};mcuQueued=queued;
      $("mcu-cancel-send").hidden=false;
      const tick=()=>{
        if(mcuQueued!==queued)return;
        const remaining=queued.deadline-performance.now();
        if(remaining<=0){mcuQueued=null;$("mcu-cancel-send").hidden=true;resolve(true);return;}
        text("mcu-dispatch-status",`${action==="gantry"?"龙门架坐标":"云台角度"}将在 ${Math.ceil(remaining/1000)} 秒后下发`);
        queued.timer=setTimeout(tick,Math.min(100,remaining));
      };tick();
    });
  }
  async function mcuAction(action,data={}){
    if(mcuPending&&action!=="stop"&&action!=="disconnect")return;
    if(action==="stop"||action==="disconnect")cancelMCUSend("待发指令已取消");
    const delayed=action==="gantry"||action==="move",payload={...data};
    mcuPending++;if(mcuState)renderMCU(mcuState);
    try{
      if(delayed&&!(await waitMCUSend(action)))return;
      if(mcuClosed)return;
      if(delayed)text("mcu-dispatch-status","3 秒等待结束，正在下发…");
      const state=await request("/api/mcu/"+action,payload);renderMCU(state);
      if(delayed)text("mcu-dispatch-status","指令已下发");
    }catch(error){toast(error.message,true);text("mcu-message",error.message);
      if(delayed)text("mcu-dispatch-status",`下发失败：${error.message}`);
    }finally{mcuPending--;if(!mcuClosed)void pollMCU();}
  }
  $("mcu-cancel-send").addEventListener("click",()=>cancelMCUSend());
  async function pollMCU(){
    clearTimeout(mcuTimer);if(mcuClosed)return;
    try{if(!mcuPending)renderMCU(await request("/api/mcu/status"));}catch{renderMCU({connected:false});text("mcu-message","MCU 通道暂不可用，请确认已加载最新上位机服务。");}
    if(!mcuClosed)mcuTimer=setTimeout(pollMCU,1000);
  }
  $("mcu-refresh").addEventListener("click",async()=>{
    try{const result=await request("/api/mcu/ports");$("mcu-port").replaceChildren(...result.ports.map(p=>{
      const option=document.createElement("option");option.value=p.port;option.textContent=`${p.port} · ${p.description}`;return option;}));
      if(!result.ports.length)text("mcu-message","未发现串口。MCU 通道已预留，接入后刷新并手动连接。");
      void pollMCU();
    }catch(error){toast(error.message,true);}
  });
  $("mcu-port").addEventListener("change",()=>void pollMCU());
  $("mcu-connect").addEventListener("click",()=>mcuAction("connect",{port:$("mcu-port").value}));
  const mcuPayload={
    gantry:()=>({x:Number($("mcu-x").value),y:Number($("mcu-y").value),z:Number($("mcu-z").value),rpm:Number($("mcu-rpm").value)}),
    move:()=>({pitch:Number($("mcu-pitch").value),yaw:Number($("mcu-yaw").value)})
  };
  for(const button of document.querySelectorAll("[data-mcu]"))button.addEventListener("click",()=>{
    const action=button.dataset.mcu;
    // Native range validation rejects out-of-range input without rounding it.
    const fields=action==="gantry"?["mcu-x","mcu-y","mcu-z","mcu-rpm"]:action==="move"?["mcu-pitch","mcu-yaw"]:[];
    for(const field of fields)if(!$(field).reportValidity())return;
    if(action==="move")for(const field of ["mcu-pitch","mcu-yaw"]){
      const axis=field==="mcu-pitch"?"pitch":"yaw",gap=mcuGap(field);
      const message=gap===null?`${axis} 当前角度反馈不可用，请先读取有效反馈`
        :gap<mcuStepMdeg?`${axis} 单次变化 ${(gap/1000).toFixed(3)}° 小于 3°，舵机会吞掉该指令`:null;
      if(message){toast(message,true);text("mcu-message",message);return;}
    }
    void mcuAction(action,(mcuPayload[action]||(()=>({})))());
  });
  window.addEventListener("pagehide",()=>{mcuClosed=true;cancelMCUSend("页面已关闭，待发指令已取消");clearTimeout(mcuTimer);});void pollMCU();

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
  window.addEventListener("pagehide",()=>{closed=true;streamAbort?.abort();surfaceResize.disconnect();boardUI.destroy();boardGeometry.destroy();boardAutoload.destroy();videoInputUI.destroy();toolLifetime.abort();clearTimeout(frameTimer);clearTimeout(statusTimer);clearTimeout(clockTimer);clearTimeout(hostMetricsTimer);longTaskObserver?.disconnect();clearInterval(previewRateTimer);worker.terminate();archiveWorker.terminate();});

  window.addEventListener("pageshow",event=>{if(event.persisted)location.reload();});
  init().then(()=>{registerWorkbenchTools();poll();framePoll();void pollHostMetrics();void syncPreviewClock();void boardUI.init();void boardGeometry.init();void boardAutoload.init();});
})();

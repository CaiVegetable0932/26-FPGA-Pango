/* Device controls and both HDMI display modes share one capture session. */
(function(root){
  "use strict";

  // Purpose: add an optional PC software reference to an already-open HDMI
  // input. This controller never requests media, replaces a stream, or touches
  // FPGA/receiver settings. Only the selected correction mode schedules work.
  function createCorrectionView({video,canvas,storage=null,math=root.PangoFisheyePreview,
    environment=root,onState=()=>{},onRate=()=>{},onFrame=()=>{},onError=()=>{}}){
    const now=()=>environment.performance.now();
    let settings=math.loadSettings(storage),mode="original",available=false,source=null;
    let renderer=null,disposed=false,ticket=null,lastMedia=null,lastDraw=null,hasFrame=false,suspended=false,error="";
    const videoCallbacks=typeof video.requestVideoFrameCallback==="function"&&typeof video.cancelVideoFrameCallback==="function";
    let start=now(),draws=0,total=0,maxGap=0,renderMs=0,maxRenderMs=0;
    function state(){return {mode,available,hasFrame,origin:settings.origin,parameterError:settings.error,
      outputFov:settings.parameters.output_fov_deg,renderer:renderer?.kind||"",maxFps:renderer?.maxFps||0,error};}
    function publish(){canvas.hidden=mode!=="corrected"||!available;onState(state());}
    function resetRate(){start=now();draws=0;maxGap=0;renderMs=0;maxRenderMs=0;lastDraw=null;
      onRate(0,{frames:0,maxGapMs:0,ageMs:0});}
    function clear(){renderer?.clear();hasFrame=false;lastMedia=null;resetRate();}
    // Video callbacks expose decoded media timestamps: currentTime can advance
    // between pictures and must not count repeated textures as new source data.
    function stop(){if(ticket!==null){if(videoCallbacks)video.cancelVideoFrameCallback(ticket);
      else environment.cancelAnimationFrame(ticket);}ticket=null;}
    function visibility(){
      const hidden=!!environment.document.hidden||!!video.closest?.("[hidden]");
      if(hidden!==suspended){suspended=hidden;clear();publish();}
      return hidden;
    }
    function fail(cause){
      // A failed GPU/parameter operation exposes the original with an explicit
      // error, rather than mislabelling an old image as newly corrected.
      mode="original";error=cause.message;stop();hasFrame=false;lastMedia=null;resetRate();
      canvas.hidden=true;publish();onError(cause);
    }
    function schedule(){if(!disposed&&mode==="corrected"&&available&&ticket===null)
      ticket=videoCallbacks?video.requestVideoFrameCallback(tick):environment.requestAnimationFrame(tick);}
    function tick(_time,metadata){
      ticket=null;if(disposed||mode!=="corrected"||!available)return;
      try{
        if(source!==video.srcObject){source=video.srcObject;clear();publish();}
        const hidden=visibility();
        const track=video.srcObject?.getVideoTracks()[0];
        if(hidden||!video.srcObject||video.paused||video.readyState<2||!video.videoWidth||!video.videoHeight||
          track?.muted||track?.readyState!=="live"){
          if(hasFrame){clear();publish();}schedule();return;
        }
        // Draw the newest decoded picture immediately; no intermediate canvas,
        // queued replay or second camera request. Older browsers use RAF and
        // decoder counters when available, falling back to media time otherwise.
        const time=now(),quality=!videoCallbacks?video.getVideoPlaybackQuality?.():null;
        const media=metadata?.mediaTime??(quality?quality.totalVideoFrames-quality.droppedVideoFrames:video.currentTime);
        if(!Number.isFinite(media)){schedule();return;}
        if(media!==lastMedia&&(!renderer||lastDraw===null||time-lastDraw>=1000/renderer.maxFps)){
          renderer ||= math.createRenderer(canvas,{live:true});
          renderer.render(video,settings.parameters);
          const submitted=now()-time;renderMs+=submitted;maxRenderMs=Math.max(maxRenderMs,submitted);
          if(lastDraw!==null)maxGap=Math.max(maxGap,time-lastDraw);
          const first=!hasFrame;
          lastDraw=time;lastMedia=media;hasFrame=true;draws++;total++;
          canvas.dataset.renderCount=String(total);canvas.dataset.renderer=renderer.kind;
          canvas.dataset.backend=renderer.backend||"";
          canvas.dataset.processingLocation="pc_software_reference";
          // Send geometry/settings only: marker overlays never read or paint
          // this video/renderer buffer. Their unchanged geometry is cached.
          onFrame({sourceWidth:video.videoWidth,sourceHeight:video.videoHeight,
            width:canvas.width,height:canvas.height,parameters:settings.parameters});
          if(first)publish();
        }else if(hasFrame&&lastDraw!==null&&time-lastDraw>1500){
          // Keep the media timestamp after a stall, so clearing cannot turn an
          // unchanged decoded image into another counted update.
          renderer.clear();hasFrame=false;publish();
        }
      }catch(cause){fail(cause);return;}
      schedule();
    }
    const timer=environment.setInterval(()=>{
      if(disposed||mode!=="corrected")return;
      // Animation callbacks may cease entirely in a background tab; the rate
      // timer must detect visibility independently and expire old counts.
      visibility();
      const time=now(),seconds=(time-start)/1000,age=lastDraw===null?0:time-lastDraw;
      // New-frame callbacks stop on a stalled source, so stale-image clearing
      // also runs from this timer, independently of callback delivery.
      if(hasFrame&&age>1500){renderer.clear();hasFrame=false;publish();}
      const active=available&&!suspended;
      onRate(active&&seconds>0?draws/seconds:0,{frames:active?draws:0,
        maxGapMs:active?Math.max(maxGap,age):0,ageMs:active?age:0,
        meanSubmitMs:draws?renderMs/draws:0,maxSubmitMs:maxRenderMs,
        scheduler:videoCallbacks?"video-frame":"animation-frame"});
      start=time;draws=0;maxGap=0;renderMs=0;maxRenderMs=0;
    },1000);
    // Same-origin calibration edits notify this tab; re-read on every switch
    // too, including when edits happened while the original was displayed.
    function refreshSettings(){settings=math.loadSettings(storage);lastMedia=null;publish();}
    function storageChanged(event){if(event.key===math.STORAGE_KEY||event.key===null)refreshSettings();}
    function contextLost(event){event.preventDefault();if(mode==="corrected")fail(Error("GPU 矫正上下文已丢失，请刷新页面后重试"));}
    environment.addEventListener?.("storage",storageChanged);canvas.addEventListener("webglcontextlost",contextLost);
    publish();
    return {getState:state,
      toggle(){if(disposed)return;error="";mode=mode==="original"?"corrected":"original";
        stop();clear();if(mode==="corrected")refreshSettings();publish();schedule();},
      setSource(active){
        if(disposed)return;
        const current=active?video.srcObject:null;
        if(available===!!active&&source===current)return;
        available=!!active;source=current;stop();clear();publish();schedule();
      },
      destroy(){disposed=true;stop();environment.clearInterval(timer);
        environment.removeEventListener?.("storage",storageChanged);canvas.removeEventListener("webglcontextlost",contextLost);
        renderer?.dispose();canvas.hidden=true;}
    };
  }

  function create({toast=()=>{}}={}){
    const $=id=>document.getElementById(id),text=(id,value)=>{$(id).textContent=value;};
    let storage=null,disposed=false,inventoryKey="",correction=null,correctionState={mode:"original"};
    let nativeFps=0,nativeInfo={playbackTotalFps:0,skipped:0,playbackDrops:0,qualityConsistent:true,maxGapMs:0,ageMs:0};
    let correctedFps=0,correctedInfo={frames:0,maxGapMs:0,ageMs:0};
    try{storage=window.localStorage;}catch{}
    // Original RAW8 coordinates use metadata, HDMI coordinates use its actual
    // video dimensions. Same IDs describe each link's own pixels, not pairing.
    const math=window.PangoFisheyePreview;
    let markerToggle=null,correctedGeometry=null,boardMode=false,boardMetadata=null,networkGeometry=null;
    const overlayChanged=()=>markerToggle?.updateInfo();
    const rawMarkers=math.createPixelOverlay({element:$("raw-pixel-markers"),container:$("video-surface"),environment:window,onChange:overlayChanged});
    const hdmiMarkers=math.createPixelOverlay({element:$("capture-pixel-markers"),container:$("result-surface"),environment:window,onChange:overlayChanged});
    markerToggle=math.createMarkerToggle({button:$("pixel-markers-toggle"),info:$("pixel-markers-info"),
      overlays:[rawMarkers,hdmiMarkers],storage,environment:window});
    function syncHdmiMarkers(){
      // FPGA HDMI already contains its markers; never paint a second host layer.
      if(boardMode){hdmiMarkers.setView(null);return;}
      const video=$("capture-video"),corrected=correctionState.mode==="corrected";
      hdmiMarkers.setView(video.hidden?null:corrected?
        (correctionState.hasFrame?correctedGeometry:null):video.readyState>=2&&video.videoWidth&&video.videoHeight?
          {width:video.videoWidth,height:video.videoHeight}:null);
    }
    const controller=window.PangoVideoInput.createController({mediaDevices:navigator.mediaDevices,storage,video:$("capture-video"),
      secureContext:window.isSecureContext!==false,onState:render});
    // Display mode and calibration parameters belong only to the browser view.
    // Returning to the original reveals the very same running video element.
    correction=createCorrectionView({video:$("capture-video"),canvas:$("capture-corrected"),storage,
      onState:renderCorrection,onRate:(fps,info)=>{correctedFps=fps;correctedInfo=info;renderRate();},
      onFrame:geometry=>{correctedGeometry=geometry;syncHdmiMarkers();},
      onError:error=>toast("计算机矫正失败，已显示原图："+error.message,true)});
    function renderCorrection(state){
      correctionState=state;const corrected=state.mode==="corrected";
      text("capture-correction-toggle",corrected?"显示原图":"计算机矫正");
      $("capture-correction-toggle").setAttribute("aria-pressed",String(corrected));
      text("capture-view-label",boardMode?`FPGA HDMI / ${boardMetadata?.mode==="original"?"灰度 ISP 原图（非 S0）":boardMetadata?.mode==="corrected"?"灰度 ISP + 矫正":"模式未查询"} / 源帧未验证`:corrected?"计算机矫正 / PC 软件参考":"HDMI 原图 / 信号未验证");
      const origin=state.origin==="calibration"?"标定页已保存参数":"标定页默认参数";
      text("capture-correction-info",boardMode?"板端处理 · HDMI source_frame_id=null / pairing_status=unverified":state.error?`矫正失败：${state.error} · 当前显示原图`:corrected?
        `PC 软件参考 · ${origin} · 输出视场 ${state.outputFov}°`+
        (state.renderer?` · ${state.renderer}（上限 ${state.maxFps} FPS）`:"")+
        (!state.hasFrame?" · 等待 HDMI 图像":"")+
        (state.parameterError?" · 保存参数无法读取，使用默认参数":""):
        "当前：HDMI 原图 · 可切换为标定页面的计算机矫正");
      renderRate();
      syncHdmiMarkers();
    }
    // The badge follows the visible view. Correction FPS counts successful
    // canvas updates, while decoder health continues to describe the input.
    function renderRate(){
      const corrected=correctionState.mode==="corrected",fps=corrected?correctedFps:nativeFps;
      text("capture-preview-rate",fps===null?"预览帧率不可测":`${corrected?"矫正显示":"原图预览"} ${fps.toFixed(1)} FPS`);
      const info=corrected?correctedInfo:nativeInfo;
      $("capture-preview-rate").title=corrected?"每秒实际完成的 PC 矫正绘制次数；不代表采集、FPGA 或远程桌面帧率":"每秒实际观察到的新帧回调；跳过的回调不补计，不能证明显示器或远程桌面的最终帧率";
      $("capture-preview-rate").dataset.fps=fps===null?"":String(fps);
      $("capture-preview-rate").dataset.measurement=JSON.stringify({...info,mode:correctionState.mode});
      // Quality totals are browser bookkeeping, not decoded or FPGA unique frames.
      text("capture-preview-health",`浏览器累计 ${nativeInfo.playbackTotalFps.toFixed(1)} FPS · 跳过更新 ${nativeInfo.skipped} · 质量统计丢弃 ${nativeInfo.playbackDrops} · ${corrected?"矫正":"原图"}最长间隔 ${Math.round(info.maxGapMs)} ms`+
        (!nativeInfo.qualityConsistent?" · 质量统计与显示回调不一致":"")+
        (info.ageMs>200?` · 已停顿 ${Math.round(info.ageMs)} ms`:""));
    }
    // Count observed new-frame callbacks, not negotiated FPS or backfilled
    // compositor totals. Show stalls separately: a one-second average hides them.
    const rateMeter=window.PangoPreviewRate.videoMeter($("capture-video"),(fps,info)=>{
      nativeFps=fps;nativeInfo=info;renderRate();
      // Read-only diagnostics allow browser checks without adding another
      // competing frame callback or forcing costly video pixel transfers.
      $("capture-preview-health").dataset.inputMeasurement=JSON.stringify(info);
    });
    const labels={idle:"未配置",configured:"已配置 · 未打开",authorizing:"等待授权",opening:"正在打开",open:"接口已打开",waiting:"等待设备数据",disconnected:"设备已断开",error:"设备操作失败",unsupported:"当前窗口不支持"};
    function render(state){
      if(disposed)return;
      const selected=state.selected?.deviceId||"",key=JSON.stringify([state.devices,selected,state.selected?.label]);
      if(key!==inventoryKey){
        const previous=$("capture-device").value;inventoryKey=key;
        const options=[];
        function option(value,label){const item=document.createElement("option");item.value=value;item.textContent=label;options.push(item);}
        option("",state.devices.length?"请选择采集卡 / 视频设备":"尚无可选设备，请刷新或授权");
        for(const device of state.devices)option(device.deviceId,device.label);
        if(selected&&!state.devices.some(device=>device.deviceId===selected))option(selected,(state.selected.label||"已保存的设备")+"（当前列表未找到）");
        $("capture-device").replaceChildren(...options);
        $("capture-device").value=state.devices.some(device=>device.deviceId===previous)?previous:selected;
      }
      const locked=state.pending||state.stream_open,valid=state.devices.some(device=>device.deviceId===$("capture-device").value),unsaved=$("capture-device").value!==selected;
      $("capture-device").disabled=!state.supported||locked;
      $("capture-mode").disabled=!state.supported||locked;$("capture-mode").value=state.capture_mode;
      $("capture-save").disabled=!state.supported||locked||!valid;
      $("capture-refresh").disabled=!state.supported||state.refreshing||state.pending;
      $("capture-authorize").disabled=!state.supported||state.pending||state.stream_open;
      for(const id of ["capture-open","capture-preview-open"])$(id).disabled=!state.supported||state.pending||state.stream_open||!selected||unsaved;
      for(const id of ["capture-close","capture-preview-close"])$(id).disabled=!state.stream_open&&!state.pending;
      for(const id of ["capture-settings-status","capture-preview-status"]){text(id,labels[state.status]||state.status);$(id).className="pill "+(state.stream_open?"active":"neutral");}
      text("capture-message",unsaved&&!locked?"设备选择尚未保存，请先保存再打开预览。":state.message);
      text("capture-selected",state.selected?.label||"尚未选择");
      text("capture-preview-device",state.selected?.label||"尚未选择设备");
      const f=state.settings,format=f.width&&f.height?`${f.width} × ${f.height}`:"设备默认格式";
      text("capture-format",state.stream_open?format+(f.frameRate?` · 协商 ${Number(f.frameRate.toFixed(2))} FPS`:""):"采集格式 —");
      $("capture-video").hidden=!state.stream_open||state.status==="waiting";
      correction?.setSource(!$("capture-video").hidden);
      syncHdmiMarkers();
      $("capture-empty").hidden=state.stream_open&&state.status!=="waiting";
      text("capture-empty-title",state.status==="opening"?"正在打开采集卡":state.status==="waiting"?"等待设备数据":state.status==="error"?"暂时无法打开设备":selected?"采集设备已配置":"选择视频输入设备");
      text("capture-empty-detail",state.status==="error"||state.status==="unsupported"?state.message:selected?"点击打开预览；HDMI 输入信号尚未验证":"在连接设置中选择采集卡，无信号时也可保存配置");
      text("capture-device-note",state.listError||(!state.supported?state.message:state.permissionRequired?"浏览器尚未公开完整设备名称。点击授权显示设备，并允许摄像头访问。":state.listed&&!state.devices.length?"当前未列出视频设备。请检查 USB 连接，或点击授权显示设备。":"选择实际采集卡，例如 Hagibis。授权时会短暂打开视频设备，读取名称后立即释放；不申请麦克风。"));
    }
    function action(fn){return async()=>{try{await fn();}catch(error){toast(error.message,true);}};}
    const listeners=[];
    function on(id,event,fn){$(id).addEventListener(event,fn);listeners.push([id,event,fn]);}
    on("capture-device","change",()=>render(controller.getState()));
    on("capture-mode","change",action(()=>controller.configureMode($("capture-mode").value)));
    on("capture-refresh","click",action(()=>controller.refresh()));
    on("capture-authorize","click",action(()=>controller.authorize()));
    on("capture-save","click",action(()=>{const state=controller.configure($("capture-device").value);toast(state.message);}));
    on("capture-correction-toggle","click",()=>correction.toggle());
    for(const event of ["loadedmetadata","loadeddata","resize"])on("capture-video",event,syncHdmiMarkers);
    for(const id of ["capture-open","capture-preview-open"])on(id,"click",action(()=>controller.open()));
    for(const id of ["capture-close","capture-preview-close"])on(id,"click",()=>controller.close());
    render(controller.getState());
    return {controller,refresh:()=>{if(controller.getState().supported&&!controller.getState().refreshing)return controller.refresh().catch(()=>{});},
      setNetworkFrame(meta){networkGeometry=meta;rawMarkers.setView(boardMode?null:meta);},
      // Switching display ownership changes only browser presentation. Actual
      // FPGA view commands are issued by the separate board control panel.
      setBoardMode(enabled,metadata=null){boardMode=!!enabled;boardMetadata=metadata;
        if(boardMode&&correction.getState().mode==="corrected")correction.toggle();
        $("capture-correction-toggle").disabled=boardMode;$("pixel-markers-toggle").disabled=boardMode;
        rawMarkers.setView(boardMode?null:networkGeometry);renderCorrection(correction.getState());
        if(boardMode)text("pixel-markers-info","板端标记由上方 FPGA 显示控制操作；HDMI 不重复叠加");
        else markerToggle.updateInfo();},
      destroy(){disposed=true;markerToggle.destroy();rawMarkers.destroy();hdmiMarkers.destroy();correction.destroy();rateMeter.destroy();for(const [id,event,fn] of listeners)$(id).removeEventListener(event,fn);controller.destroy();}};
  }
  const api={create,createCorrectionView};root.PangoVideoInputUI=api;
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof globalThis!=="undefined"?globalThis:this);

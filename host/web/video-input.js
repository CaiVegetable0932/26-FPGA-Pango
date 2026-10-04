/* Local camera/capture-card adapter. No microphone, network relay or source-frame inference. */
(function(root){
  "use strict";
  const STORAGE_KEY="pango.video-input.v1";
  function explain(error){
    const messages={NotAllowedError:"摄像头访问未获允许，请在浏览器站点权限中允许后重试。",SecurityError:"当前浏览器窗口不允许访问视频设备，请用系统浏览器打开本机页面。",
      NotFoundError:"找不到所选视频设备，请检查连接并刷新列表。",OverconstrainedError:"所选设备已不可用，请刷新后重新选择；不会自动切换到其他摄像头。",
      NotReadableError:"设备暂时无法打开，可能被其他程序占用或驱动尚未就绪。已保存的选择仍保留。",AbortError:"设备打开被中断，可以稍后重试。",TimeoutError:"采集卡 12 秒内未完成打开；请完成权限提示或释放外部预览后重试。"};
    return messages[error?.name]||error?.message||"视频设备操作失败，请稍后重试。";
  }
  function stopTracks(stream){for(const track of stream?.getTracks()||[])track.stop();}
  function createController({mediaDevices,storage=null,video=null,onState=()=>{},secureContext=true}={}){
    let saved=null;
    try{const data=JSON.parse(storage?.getItem(STORAGE_KEY)||"null");if(data?.version===1&&typeof data.deviceId==="string"&&data.deviceId.length>0&&data.deviceId.length<4096)saved={deviceId:data.deviceId,label:typeof data.label==="string"?data.label.slice(0,256):"视频输入设备"};}catch{}
    const supported=secureContext&&typeof mediaDevices?.getUserMedia==="function"&&typeof mediaDevices?.enumerateDevices==="function";
    const state={supported,devices:[],selected:saved,status:supported?(saved?"configured":"idle"):"unsupported",pending:false,refreshing:false,
      permissionRequired:false,listed:false,persistent:!!storage,settings:{},message:saved?"已恢复设备选择；尚未打开采集卡。":"刷新设备后选择采集卡，保存配置无需输入信号。",listError:""};
    const unsupported="当前窗口无法访问视频设备，请使用系统浏览器打开 http://127.0.0.1:8765/（或实际启动端口）。";
    if(!supported)state.message=unsupported;
    let stream=null,disposed=false,generation=0,inventoryGeneration=0;
    // Coordinate this origin's preview/calibration tabs. Explicitly opening a
    // card transfers ownership and releases the old tab's tracks first.
    const channel=typeof window!=="undefined"&&typeof BroadcastChannel!=="undefined"?new BroadcastChannel("pango.capture-owner.v1"):null;
    if(channel)channel.onmessage=event=>{const value=event.data;if(value?.claim&&(stream||state.pending)&&
      (value.deviceId===state.selected?.deviceId||value.label===state.selected?.label))close();};
    let trackListeners=[];
    function getState(){return {...state,selected:state.selected?{...state.selected}:null,devices:state.devices.map(d=>({...d})),settings:{...state.settings},
      stream_open:!!stream,source_frame_id:null,pairing_status:"unverified",signal_validation:"not_performed",capture_owner:"browser"};}
    function emit(values={}){Object.assign(state,values);if(!disposed)onState(getState());}
    function ensure(){if(disposed)throw Error("视频输入接口已关闭");if(!supported)throw Error(unsupported);}
    function release(){
      for(const [track,event,listener] of trackListeners)track.removeEventListener(event,listener);
      trackListeners=[];
      const previous=stream;stream=null;
      stopTracks(previous);
      if(video){video.pause();video.srcObject=null;}
      state.settings={};
    }
    function close(){
      generation++;release();
      // Explicit close disables navigation resume; destroy only releases tracks.
      try{storage?.setItem("pango.capture.resume","0");}catch{}
      emit({status:state.selected?"configured":"idle",message:state.pending?"已取消设备打开；等待浏览器结束当前权限或设备请求。":"设备已关闭，配置仍保留。"});
    }
    function disconnect(){
      generation++;release();
      emit({status:"disconnected",message:"采集设备已断开或访问已结束。请检查连接后重新打开，不会切换到其他设备。"});
    }
    async function refresh(){
      ensure();const ticket=++inventoryGeneration;emit({refreshing:true,listError:""});
      try{
        const items=await mediaDevices.enumerateDevices();
        if(disposed||ticket!==inventoryGeneration)return getState();
        const inputs=items.filter(item=>item.kind==="videoinput"),seen=new Set();
        state.permissionRequired=inputs.some(item=>!item.label||!item.deviceId);
        state.devices=inputs.filter(item=>item.deviceId&&!seen.has(item.deviceId)&&seen.add(item.deviceId)).map((item,index)=>({deviceId:item.deviceId,label:item.label||`视频输入 ${index+1}（名称未授权）`}));
        state.listed=true;
        if(stream&&!state.devices.some(item=>item.deviceId===state.selected?.deviceId))disconnect();
        emit();
      }catch(error){if(!disposed&&ticket===inventoryGeneration)emit({listError:explain(error)});throw error;}
      finally{if(!disposed&&ticket===inventoryGeneration)emit({refreshing:false});}
      return getState();
    }
    function configure(deviceId){
      ensure();if(state.pending||stream)throw Error("请先关闭设备，再修改输入选择。");
      const device=state.devices.find(item=>item.deviceId===deviceId);
      if(!device)throw Error("请从设备列表中选择一个视频输入；名称不可见时先授权。");
      state.selected={...device};
      try{if(!storage)throw Error("storage unavailable");storage.setItem(STORAGE_KEY,JSON.stringify({version:1,...state.selected}));state.persistent=true;}catch{state.persistent=false;}
      emit({status:"configured",message:state.persistent?"设备选择已保存；尚未打开设备，输入信号未验证。":"设备选择已应用到当前页面；浏览器未允许持久保存，刷新页面后需重新选择。"});
      return getState();
    }
    function begin(status,message){ensure();if(state.pending)throw Error("请先处理浏览器中的权限请求，或等待上一次设备请求结束。");const ticket=++generation;emit({pending:true,status,message});return ticket;}
    function current(ticket){return !disposed&&ticket===generation;}
    async function acquireVideo(constraints){
      // Bound an unresponsive driver request. A late permission/driver success
      // releases its tracks immediately instead of taking ownership after timeout.
      let expired=false,timer;
      const request=mediaDevices.getUserMedia(constraints).then(value=>{
        if(expired){stopTracks(value);throw Object.assign(Error(),{name:"TimeoutError"});}
        return value;
      });
      const timeout=new Promise((_,reject)=>{timer=setTimeout(()=>{expired=true;reject(Object.assign(Error(),{name:"TimeoutError"}));},12000);});
      try{return await Promise.race([request,timeout]);}finally{clearTimeout(timer);}
    }
    async function authorize(){
      ensure();if(stream)return refresh();
      const ticket=begin("authorizing","请处理浏览器摄像头权限提示；仅为读取设备名称，完成后会立即释放设备。");
      let temporary=null;
      try{
        temporary=await mediaDevices.getUserMedia({audio:false,video:state.devices.some(item=>item.deviceId===state.selected?.deviceId)?{deviceId:{exact:state.selected.deviceId}}:true});
        if(!current(ticket))throw Error("设备授权已取消");
        await refresh();
        if(current(ticket))emit({status:state.selected?"configured":"idle",message:"设备名称已读取，授权用的临时采集已释放。请选择设备并保存。"});
      }catch(error){
        if(current(ticket)){
          // Some drivers grant permission but cannot produce a stream without HDMI input.
          try{await refresh();}catch{}
          if(current(ticket))emit({status:"error",message:explain(error)});
        }
      }finally{stopTracks(temporary);emit({pending:false});}
      return getState();
    }
    async function open(){
      ensure();if(stream)return getState();
      if(!state.selected)throw Error("请先选择并保存输入设备。");
      // Acquire the request generation before any await so close cancels open.
      const chosen={...state.selected},ticket=begin("opening","正在打开所选采集设备；输入信号未验证。");
      let incoming=null;
      try{
        // Inventory refreshes on entry/hotplug. Re-resolve a USB ID only by an
        // unambiguous saved label; never fall back to another camera.
        if(!state.devices.some(d=>d.deviceId===chosen.deviceId)){
          const same=state.devices.filter(d=>d.label===chosen.label&&!/名称未授权/.test(d.label));
          if(same.length===1){
            Object.assign(chosen,same[0]);state.selected={...chosen};
            try{storage?.setItem(STORAGE_KEY,JSON.stringify({version:1,...chosen}));}catch{}
          }
        }
        // Purpose: prefer the CAM1 HDMI capture mode while binding the selected
        // device exactly; report negotiated settings if the driver chooses otherwise.
        if(channel){channel.postMessage({claim:true,...chosen});await new Promise(r=>setTimeout(r,250));}
        // UVC can remain briefly busy after another page releases it. Retry
        // transient driver errors on the same exact device, never permissions.
        for(let attempt=0;attempt<3;attempt++){
          if(!current(ticket))throw Error("设备打开已取消");
          try{
            incoming=await acquireVideo({audio:false,video:{deviceId:{exact:chosen.deviceId},
              width:{ideal:1280},height:{ideal:720},frameRate:{ideal:30}}});
            break;
          }catch(error){
            if(!["NotReadableError","AbortError"].includes(error?.name)||attempt===2)throw error;
            if(current(ticket))emit({message:`采集卡暂忙，正在重试 ${attempt+1}/2；请关闭 PotPlayer 等外部预览。`});
            await new Promise(r=>setTimeout(r,500*(attempt+1)));
          }
        }
        if(!current(ticket))throw Error("设备打开已取消");
        const track=incoming.getVideoTracks()[0];
        if(!track||track.readyState==="ended")throw Error("设备没有提供可用的视频轨道；配置仍保留。");
        const settings=track.getSettings();
        if(settings.deviceId&&settings.deviceId!==chosen.deviceId)throw Error("浏览器返回的设备与所选设备不一致，已停止打开。");
        stream=incoming;
        try{storage?.setItem("pango.capture.resume","1");}catch{}
        state.settings=Object.fromEntries(["width","height","frameRate"].filter(key=>Number.isFinite(settings[key])&&settings[key]>0).map(key=>[key,settings[key]]));
        const watch=(event,listener)=>{track.addEventListener(event,listener);trackListeners.push([track,event,listener]);};
        watch("ended",()=>{if(current(ticket))disconnect();});
        watch("mute",()=>{if(current(ticket))emit({status:"waiting",message:"接口已打开，视频轨道暂时没有数据；输入信号未验证。"});});
        watch("unmute",()=>{if(current(ticket))emit({status:"open",message:"接口已打开；当前只显示采集卡输出，不代表 FPGA 信号或源帧身份通过验证。"});});
        emit({status:track.muted?"waiting":"open",message:"采集接口已打开；设备输出、HDMI 输入信号及源帧配对均未验证。"});
        if(video){
          video.muted=true;video.srcObject=stream;
          Promise.resolve(video.play()).catch(error=>{if(current(ticket)&&stream===incoming){release();emit({status:"error",message:"预览播放失败，请点击打开预览重试。"+explain(error)});}});
        }
      }catch(error){
        stopTracks(incoming);
        if(current(ticket)){release();emit({status:"error",message:explain(error)});}
      }finally{emit({pending:false});}
      return getState();
    }
    const deviceChange=()=>{refresh().catch(()=>{});};
    if(supported)mediaDevices.addEventListener?.("devicechange",deviceChange);
    function destroy(){disposed=true;generation++;inventoryGeneration++;channel?.close();mediaDevices?.removeEventListener?.("devicechange",deviceChange);release();}
    return {getState,refresh,configure,authorize,open,close,destroy,getStream:()=>stream};
  }
  const api={createController,STORAGE_KEY};
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
  else root.PangoVideoInput=api;
})(globalThis);

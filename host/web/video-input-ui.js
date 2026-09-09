/* Device controls and result preview share one browser-owned capture session. */
(function(){
  "use strict";
  function create({toast=()=>{}}={}){
    const $=id=>document.getElementById(id),text=(id,value)=>{$(id).textContent=value;};
    let storage=null,disposed=false,inventoryKey="";
    try{storage=window.localStorage;}catch{}
    const controller=window.PangoVideoInput.createController({mediaDevices:navigator.mediaDevices,storage,video:$("capture-video"),
      secureContext:window.isSecureContext!==false,onState:render});
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
      $("capture-empty").hidden=state.stream_open&&state.status!=="waiting";
      text("capture-empty-title",state.status==="opening"?"正在打开采集卡":state.status==="waiting"?"等待设备数据":state.status==="error"?"暂时无法打开设备":selected?"采集设备已配置":"选择视频输入设备");
      text("capture-empty-detail",state.status==="error"||state.status==="unsupported"?state.message:selected?"点击打开预览；HDMI 输入信号尚未验证":"在连接设置中选择采集卡，无信号时也可保存配置");
      text("capture-device-note",state.listError||(!state.supported?state.message:state.permissionRequired?"浏览器尚未公开完整设备名称。点击授权显示设备，并允许摄像头访问。":state.listed&&!state.devices.length?"当前未列出视频设备。请检查 USB 连接，或点击授权显示设备。":"选择实际采集卡，例如 Hagibis。授权时会短暂打开视频设备，读取名称后立即释放；不申请麦克风。"));
    }
    function action(fn){return async()=>{try{await fn();}catch(error){toast(error.message,true);}};}
    const listeners=[];
    function on(id,event,fn){$(id).addEventListener(event,fn);listeners.push([id,event,fn]);}
    on("capture-device","change",()=>render(controller.getState()));
    on("capture-refresh","click",action(()=>controller.refresh()));
    on("capture-authorize","click",action(()=>controller.authorize()));
    on("capture-save","click",action(()=>{const state=controller.configure($("capture-device").value);toast(state.message);}));
    for(const id of ["capture-open","capture-preview-open"])on(id,"click",action(()=>controller.open()));
    for(const id of ["capture-close","capture-preview-close"])on(id,"click",()=>controller.close());
    render(controller.getState());
    return {controller,refresh:()=>{if(controller.getState().supported&&!controller.getState().refreshing)return controller.refresh().catch(()=>{});},
      destroy(){disposed=true;for(const [id,event,fn] of listeners)$(id).removeEventListener(event,fn);controller.destroy();}};
  }
  window.PangoVideoInputUI={create};
})();

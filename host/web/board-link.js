/* Physical startup controls: remember the setup, expose progress, keep HDMI independent. */
(function(root){
  "use strict";
  function create({request,video,toast}){
    const $=id=>document.getElementById(id);
    let ended=false,timer=null,first=true,opening=false,resetPending=false,resetRequestInFlight=false,lastState=null;
    const fields={port:"board-port",interface:"board-interface",source_ip:"board-source-ip",source_mac:"board-source-mac",peer_port:"board-peer-port",source_port:"board-source-port"};
    function render(state){
      lastState=state;
      $("board-message").textContent=state.message;
      const b=state.board;
      $("board-diagnostics").textContent=b?`网线 ${b.link_ready?"已连接":"未建立链路"} · 摄像头 ${b.sensor_ready?"就绪":"未就绪"} · 有效帧 ${b.frame_published?"已发布":"未发布"} · HDMI 欠载 ${b.hdmi_underflow?"有":"无"} · FPGA 故障 ${b.core_fault?"有":"无"}`:"";
      // Lock immediately on click as well as during the asynchronous UART job.
      const busy=!!state.busy||resetPending;
      for(const id of ["board-start","board-refresh","board-reset-ethernet",...Object.values(fields),"board-auto"])$(id).disabled=busy;
    }
    async function refresh(forceProfile=false){
      const result=await request("/api/board/devices"),state=await request("/api/board/status");
      for(const [field,rows,label] of [["port",result.ports,p=>`${p.port} · ${p.label}`],["interface",result.interfaces,n=>`${n.name} · ${n.ip}/${n.prefix} · ${n.mac}`]]){
        const node=$(fields[field]),selected=(forceProfile?state.profile[field]:node.value||state.profile[field])||"";
        node.replaceChildren(new Option("请选择", ""));
        const seen=new Set();
        for(const row of rows){const value=field==="port"?row.port:row.name;if(!seen.has(value)){node.add(new Option(label(row),value));seen.add(value);}}
        if(selected&&!seen.has(selected))node.add(new Option(selected+"（未连接）",selected));
        node.value=selected||(seen.size===1?[...seen][0]:"");
      }
      if(first||forceProfile){
        for(const [key,id] of Object.entries(fields))if(state.profile[key]!==undefined)$(id).value=state.profile[key];
        if(state.profile.auto_start!==undefined)$("board-auto").checked=state.profile.auto_start;
        first=false;
      }
      render(state);
      if(result.errors.length)$("board-message").textContent=result.errors.join("；");
      return state;
    }
    async function hdmi(){
      if(opening||video.getState().stream_open)return;
      opening=true;
      try{
        await video.refresh();
        if(!video.getState().selected){
          // Only the unique named capture card is auto-selected; never a laptop webcam.
          const candidates=video.getState().devices.filter(d=>/Hagibis/i.test(d.label));
          if(candidates.length===1)video.configure(candidates[0].deviceId);
          else {toast("HDMI：请在连接设置授权并选择采集卡，再打开预览。",true);return;}
        }
        const state=await video.open();
        if(!state.stream_open)toast("HDMI："+state.message,true);
      }catch(error){toast("HDMI："+error.message,true);}finally{opening=false;}
    }
    async function poll(){
      try{const state=await request("/api/board/status");if(!ended){
        if(resetPending&&!resetRequestInFlight&&!state.busy)await finishReset(state);
        else render(state);
      }}catch{}
      if(!ended)timer=setTimeout(poll,1000);
    }
    async function finishReset(state){
      // Only persisted defaults from the completed worker replace form edits.
      // An error keeps the actual saved profile visible and explains recovery.
      resetPending=false;await refresh(true);
      if(state.phase==="error")toast(state.message,true);
      else if(state.phase==="ready")toast("以太网默认配置已恢复，已收到完整视频帧。HDMI 预览保持打开。");
    }
    $("board-refresh").addEventListener("click",()=>refresh().catch(e=>toast(e.message,true)));
    $("board-start").addEventListener("click",async()=>{
      const profile=Object.fromEntries(Object.entries(fields).map(([key,id])=>[key,$(id).value.trim()]));
      profile.peer_port=Number(profile.peer_port);profile.source_port=Number(profile.source_port);profile.auto_start=$("board-auto").checked;
      try{render(await request("/api/board/start",profile));}catch(e){toast(e.message,true);}
      // HDMI recovery is independent of successful network commissioning.
      await hdmi();
    });
    $("board-reset-ethernet").addEventListener("click",async()=>{
      if(resetPending||lastState?.busy)return;
      resetPending=resetRequestInFlight=true;render(lastState||{message:"正在恢复默认以太网链路…"});
      try{
        const state=await request("/api/board/reset-ethernet",{});
        resetRequestInFlight=false;
        if(state.busy)render(state);else await finishReset(state);
      }catch(e){resetPending=resetRequestInFlight=false;if(lastState)render(lastState);toast(e.message,true);}
      // Intentionally no hdmi(), close(), getUserMedia() or page reload here.
    });
    $("board-stop").addEventListener("click",async()=>{try{render(await request("/api/board/stop",{}));video.close();}catch(e){toast(e.message,true);}});
    // Link statistics stay in the workspace; commissioning now has its own tab.
    const note=document.querySelector(".control-note");if(note)note.textContent="UART 启动与状态见“板卡设置”";
    return {async init(){try{const state=await refresh();let resume=false;try{resume=localStorage.getItem("pango.capture.resume")==="1";}catch{}if(state.profile.auto_start||resume)void hdmi();}catch(e){toast(e.message,true);}void poll();},destroy(){ended=true;clearTimeout(timer);}};
  }
  root.PangoBoardLink={create};
})(globalThis);

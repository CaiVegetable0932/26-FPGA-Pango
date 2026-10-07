/* Real-board controls and SOURCE-coordinate overlay. No destination math or video I/O. */
(function(root){
  "use strict";
  // Keep board metadata separate from canonical software-reference markers.
  // A metadata revision does not establish an HDMI/source frame association.
  function sourceMarkers(metadata,frame){
    if(!metadata?.metadata_verified||metadata.processing_location!=="fpga"||!metadata.markers||
      !frame||frame.source_mode!=="hardware_unverified"||String(frame.stream_epoch)!==metadata.epoch)return [];
    if(frame.sourceWidth!==metadata.source_width||frame.sourceHeight!==metadata.source_height)return [];
    return metadata.points.filter(p=>p.visible).map(p=>({id:p.id,color:p.color,source:p.source,
      point:[(p.source[0]+.5)*frame.width/frame.sourceWidth-.5,
        (p.source[1]+.5)*frame.height/frame.sourceHeight-.5]}));
  }
  function create({request,videoUI,environment=root}){
    const doc=environment.document,$=id=>doc.getElementById(id),svg=$("fpga-source-markers"),surface=$("video-surface");
    let ended=false,busy=false,metadata=null,frame=null,boardMode=true,timer=null;
    let frameAt=0,metadataAt=0,key="";
    const now=()=>environment.performance.now();
    const controls=["fpga-refresh","fpga-view-apply","fpga-parameters-apply"];
    function message(value){$("fpga-control-status").textContent=value;}
    function draw(){
      const fresh=now()-frameAt<1500&&now()-metadataAt<6000;
      const points=boardMode&&fresh?sourceMarkers(metadata,frame):[];
      const bounds=surface.getBoundingClientRect(),next=JSON.stringify([points,bounds.width,bounds.height,metadata?.diameter,frame?.width,frame?.height]);
      if(next===key)return;key=next;
      svg.toggleAttribute("hidden",!points.length);svg.replaceChildren();
      if(!points.length)return;
      const scale=Math.min(bounds.width/frame.width,bounds.height/frame.height);
      const ox=(bounds.width-frame.width*scale)/2,oy=(bounds.height-frame.height*scale)/2;
      svg.setAttribute("viewBox",`0 0 ${bounds.width} ${bounds.height}`);
      for(const p of points){
        const node=doc.createElementNS("http://www.w3.org/2000/svg","circle");
        // Source coordinates and RGB originate solely in FPGA bank 2. Scale
        // marker diameter from source pixels together with the RAW preview.
        for(const [name,value] of Object.entries({cx:ox+(p.point[0]+.5)*scale,cy:oy+(p.point[1]+.5)*scale,
          r:metadata.diameter*frame.width/frame.sourceWidth*scale/2,fill:p.color}))node.setAttribute(name,String(value));
        node.dataset.pixelId=String(p.id);node.dataset.source=JSON.stringify(p.source);svg.append(node);
      }
      svg.dataset.processingLocation="fpga_metadata_source_overlay";
      svg.dataset.revision=String(metadata.revision);svg.dataset.generation=String(metadata.generation);
    }
    function accept(value){
      const changed=!metadata||value.revision!==metadata.revision||value.epoch!==metadata.epoch;
      metadata=value;metadataAt=now();draw();
      // Repeated polling must not replace an operator's unapplied form edits.
      if(changed){$("fpga-view-mode").value=value.mode;$("fpga-markers").checked=value.markers;$("fpga-marker-diameter").value=String(value.diameter);}
      message(`板端显示版本 ${value.revision} · 参数版本 ${value.displayed_param_version} · 标记代次 ${value.generation} · HDMI 源帧未验证`);
      videoUI.setBoardMode(boardMode,value);
    }
    async function action(fn){
      if(busy||ended)return;busy=true;for(const id of controls)$(id).disabled=true;
      try{await fn();}catch(error){invalidate();message(error.message);}
      finally{busy=false;for(const id of controls)$(id).disabled=false;}
    }
    const listeners=[];
    // A write or failed read invalidates both labels and overlays immediately;
    // there is no local fallback to old metadata or software-computed points.
    function invalidate(){metadata=null;draw();videoUI.setBoardMode(boardMode,null);}
    function on(id,event,fn){$(id).addEventListener(event,fn);listeners.push([id,event,fn]);}
    const refresh=()=>action(async()=>accept(await request("/api/board/markers")));
    on("fpga-refresh","click",refresh);
    on("fpga-view-apply","click",()=>action(async()=>{
      invalidate();
      message("等待 FPGA 应用显示设置…");
      const result=await request("/api/board/view",{mode:$("fpga-view-mode").value,markers:$("fpga-markers").checked,
        diameter:Number($("fpga-marker-diameter").value)});
      accept(result);
    }));
    on("fpga-parameters-apply","click",()=>action(async()=>{
      // JSON is explicit and reviewable. Invalid saved software parameters do
      // not silently substitute defaults before a physical board mutation.
      const preset=JSON.parse($("fpga-parameters").value);
      invalidate();
      message("正在上传并回读 FPGA 参数，等待按帧激活…");
      const result=await request("/api/board/geometry",{preset,rotation_deg:Number($("fpga-rotation").value),
        enhance:$("fpga-enhance").checked});
      metadata=null;draw();
      message(`FPGA 参数版本 ${result.version} 已回读 · 图像精度尚未验收`);
      accept(await request("/api/board/markers"));
    }));
    on("fpga-parameters-load","click",()=>{
      try{
        const saved=environment.localStorage?.getItem(environment.PangoFisheyePreview.STORAGE_KEY);
        if(!saved)throw Error("尚无已保存的软件参考参数，请先在标定页保存或直接编辑 JSON");
        const value=JSON.parse(saved),parameters=environment.PangoFisheyePreview.normalize(value.parameters);
        $("fpga-parameters").value=JSON.stringify({parameters},null,2);
        message("参数已填入；点击上传后才会写入 FPGA");
      }catch(error){message(error.message);}
    });
    on("geometry-display-owner","change",()=>{
      boardMode=$("geometry-display-owner").value==="fpga";
      videoUI.setBoardMode(boardMode,metadata);draw();
    });
    const observer=typeof environment.ResizeObserver==="function"?new environment.ResizeObserver(draw):null;
    observer?.observe(surface);
    // Periodic readback also detects changes made by a different browser tab.
    // No hardware present is an explicit unavailable state, never a mock success.
    async function poll(){if(ended)return;if(boardMode&&!doc.hidden&&!busy)await refresh();draw();
      if(!ended)timer=environment.setTimeout(poll,3000);}
    $("fpga-parameters").value=JSON.stringify({parameters:environment.PangoFisheyePreview.preset()},null,2);
    videoUI.setBoardMode(true,null);
    return {init:poll,refresh,setNetworkFrame(value){frame=value;frameAt=now();draw();},
      destroy(){ended=true;environment.clearTimeout(timer);observer?.disconnect();svg.replaceChildren();svg.toggleAttribute("hidden",true);
        for(const [id,event,fn] of listeners)$(id).removeEventListener(event,fn);}};
  }
  const api={create,sourceMarkers};root.PangoBoardGeometry=api;
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof globalThis!=="undefined"?globalThis:this);

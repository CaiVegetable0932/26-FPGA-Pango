/* Calibration images use native video pixels and the existing device adapter.
 * All mutations share the local server token; labels/filenames render as text.
 */
(function(){
  "use strict";
  const $=id=>document.getElementById(id);
  let token="",sets=[],current="",busy=false,storage=null;
  try{storage=localStorage;}catch{}
  function message(text,error=false){$("message").textContent=text;$("message").className=error?"error":"";}
  async function api(path,data){
    const options=data===undefined?{}:{method:"POST",headers:{"Content-Type":"application/json","X-Pango-Token":token},body:JSON.stringify(data)};
    const response=await fetch(path,options),body=await response.json();
    if(!response.ok)throw Error(body.error||"请求失败");return body;
  }
  // Hold form state while uploads/detection run, preventing cross-dataset races.
  async function action(fn){
    if(busy)return;busy=true;document.querySelectorAll("button,select,input,textarea").forEach(n=>n.disabled=true);
    try{await fn();}catch(error){message(error.message,true);}
    finally{busy=false;document.querySelectorAll("button,select,input,textarea").forEach(n=>n.disabled=false);}
  }
  function on(id,fn){$(id).addEventListener("click",()=>action(fn));}
  function option(value,label){const n=document.createElement("option");n.value=value;n.textContent=label;return n;}
  function link(label,url){const n=document.createElement("a");n.textContent=label;n.href=url;n.download="";return n;}
  function artifact(sample,file,version){return "/api/calibration/artifact?"+new URLSearchParams({dataset:current,sample:sample||"",file,...(version?{version}: {})});}
  function group(){const g=sets.find(g=>g.id===current);if(!g)throw Error("请先创建或选择标定组");return g;}
  // Archive selection passes a server-owned key and does not load display previews.
  async function refreshRecords(){
    const result=await api("/api/calibration/sources"),select=$("host-records"),previous=select.value;
    select.replaceChildren(option("",result.items.length?"请选择已保存原图":"暂无完整原图，可重新拍照"));
    for(const item of result.items){
      const n=option(item.key,`${item.width}×${item.height} ${item.pixel_format} · ${item.key}${item.calibration_reason?" · "+item.calibration_reason:""}`);
      n.disabled=!item.calibration_allowed;select.append(n);
    }
    select.value=previous;
  }
  function showSample(sample){
    $("preview").src=artifact(sample.id,"corners.png");$("preview").hidden=false;
    message(sample.eligible?"原始图与角点已保存，请继续变换位置、距离和倾角。":"图像已保留："+sample.reason,!sample.eligible);
  }
  // Optical model controls coefficient names: fisheye k3/k4 are never labelled p1/p2.
  function showResult(result){
    const K=result.K,f=n=>Number(n).toPrecision(9),fish=result.model==="fisheye_equidistant";
    const names=fish?["k1","k2","k3","k4"]:["k1","k2","p1","p2"];
    $("parameters").hidden=false;
    $("parameters").textContent=`模型：${fish?"鱼眼等距（不兼容当前 FPGA 针孔寄存器）":"针孔 k1/k2/p1/p2，k3=0"}\n分辨率：${result.image_size.join(" × ")}\nfx=${f(K[0][0])}  fy=${f(K[1][1])}  cx=${f(K[0][2])}  cy=${f(K[1][2])}\n${result.D.map((d,i)=>names[i]+"="+f(d)).join("  ")}\n拟合 RMS：${f(result.rms_px)} px\n独立验证 RMS（逐图）：${result.validation_errors_px.map(f).join(", ")} px\n状态：候选参数 / 板端尚未应用`;
    const summary={...result};delete summary.samples;$("result").textContent=JSON.stringify(summary,null,2);
  }
  // Purpose: capture an explicit per-image operator measurement rather than
  // reusing a nominal setup distance after the chart/camera moves.
  function manual(){
    const values={};
    for(const input of $("sample-context").querySelectorAll("[name]")){
      const raw=input.value.trim();
      values[input.name]=["light_preset","notes"].includes(input.name)?raw:raw===""?null:Number(raw);
    }
    if(!Number.isFinite(values.distance_mm)||values.distance_mm<=0)throw Error("请填写本张图的镜头—图卡实测距离(mm)");
    for(const [name,value] of Object.entries(values))if(typeof value==="number"&&!Number.isFinite(value))throw Error(name+"不是有效数值");
    return values;
  }
  const controller=window.PangoVideoInput.createController({mediaDevices:navigator.mediaDevices,storage,video:$("video"),secureContext:window.isSecureContext,onState:state=>{
    $("device-status").textContent=state.message+" · 来源 unverified";
    const previous=$("device").value||state.selected?.deviceId;
    $("device").replaceChildren(option("","请选择采集卡 / 摄像头"),...state.devices.map(d=>option(d.deviceId,d.label)));
    $("device").value=previous||"";
  }});
  // Purpose: reuse the selected video track for a labelled manual PC reference;
  // sampling this preview never changes saved calibration images or FPGA state.
  const tuning=window.PangoFisheyeTuning.create({video:$("video"),storage});
  async function refresh(){
    const result=await api("/api/calibration");sets=result.items;
    $("environment").textContent=result.environment.available?`OpenCV ${result.environment.opencv} · NumPy ${result.environment.numpy}`:result.environment.error;
    $("datasets").replaceChildren(option("","选择或创建标定组"),...sets.map(g=>option(g.id,`${g.config.board_id} / ${g.config.lens_id||g.config.camera_id} / ${g.created.slice(0,19)}`)));
    if(!current&&sets.length)current=sets[sets.length-1].id;
    $("datasets").value=current;render();
  }
  function render(){
    $("samples").replaceChildren();$("downloads").replaceChildren();$("result").textContent="";
    $("parameters").hidden=true;
    const g=sets.find(g=>g.id===current);
    // Purpose: expose saved exact RGB samples, including detection failures,
    // to manual review without promoting them into the fitted data set.
    tuning.setSamples(g?.samples||[],artifact,current);
    if(!g)return;
    $("group-info").textContent=JSON.stringify(g.config,null,2);
    const train=g.samples.filter(s=>s.enabled&&s.role==="train").length,valid=g.samples.filter(s=>s.enabled&&s.role==="validation").length;
    $("counts").textContent=`已保存 ${g.samples.length} 张 · 有效拟合 ${train}/25 · 独立验证 ${valid}/3 · 所有图像来源均需核验`;
    for(const s of g.samples){
      const row=document.createElement("tr");
      function cell(text){const td=document.createElement("td");if(text!==undefined)td.textContent=text;row.append(td);return td;}
      const view=document.createElement("button");view.textContent=s.name;
      view.onclick=()=>{ $("preview").src=artifact(s.id,"corners.png");$("preview").hidden=false; };
      cell().append(view);cell(`${s.role==="train"?"拟合":"验证"} · ${s.width}×${s.height} · ${s.manual?.distance_mm??"未测"} mm`);
      cell(`${s.corners.length} 点 · ${s.enabled?"已选入":"未选入"}${s.reason?" · "+s.reason:""}`);
      const actions=cell();actions.append(link("RGB",artifact(s.id,"image.rgb")),link("元数据",artifact(s.id,"metadata.json")));
      if(s.kind==="raw8")actions.append(link("RAW8 原始字节",artifact(s.id,"image.raw")));
      if(s.eligible){const b=document.createElement("button");b.textContent=s.enabled?"剔除":"选入";b.onclick=()=>action(async()=>{
        const reason=prompt("填写选入或剔除原因（原始证据继续保留）");if(!reason?.trim())return;
        await api("/api/calibration/select",{dataset:current,sample:s.id,enabled:!s.enabled,reason});await refresh();
      });actions.append(b);}
      $("samples").append(row);
    }
    for(const r of g.results){
      const view=document.createElement("button");view.textContent="查看参数 "+r.version.slice(0,8);
      view.onclick=()=>action(async()=>showResult(await api(artifact(null,"json",r.version))));
      $("downloads").append(view,link("下载 JSON",artifact(null,"json",r.version)),link("SHA-256",artifact(null,"sha256",r.version)));
    }
  }
  function base64(bytes){let text="";for(let i=0;i<bytes.length;i+=32768)text+=String.fromCharCode(...bytes.subarray(i,i+32768));return btoa(text);}
  async function saveImage(data){
    const sample=await api("/api/calibration/image",{dataset:current,role:$("role").value,manual:manual(),...data});
    await refresh();showSample(sample);
  }
  $("config").addEventListener("submit",event=>{event.preventDefault();action(async()=>{
    const config=Object.fromEntries(new FormData($("config")));
    // Disabled controls are absent from FormData while busy; read named fields explicitly.
    for(const n of $("config").elements)if(n.name)config[n.name]=n.value;
    for(const key of ["cols","rows","square_mm"])config[key]=Number(config[key]);
    const result=await api("/api/calibration/create",{config});current=result.id;await refresh();message("标定组已创建，图卡和模式参数已冻结。");
  });});
  $("datasets").addEventListener("change",()=>{current=$("datasets").value;$("preview").hidden=true;render();});
  on("refresh",async()=>{await refresh();await controller.refresh();});
  on("refresh-records",refreshRecords);
  on("import-record",async()=>{
    group();const key=$("host-records").value;if(!key)throw Error("请选择完整原图");
    const context=manual();message("读取完整原图并检测角点…");
    const sample=await api("/api/calibration/record",{dataset:current,key,role:$("role").value,manual:context});await refresh();showSample(sample);
  });
  on("authorize",async()=>{await controller.authorize();});
  on("open",async()=>{controller.configure($("device").value);await controller.open();});
  on("close",async()=>controller.close());
  on("capture",async()=>{
    group();const video=$("video"),track=controller.getStream()?.getVideoTracks()[0];
    if(!track||track.readyState!=="live"||track.muted||video.readyState<2||!video.videoWidth)throw Error("没有可用视频帧，请打开设备并等待输入。");
    // Require a fresh frame when supported; reject frozen/ended streams.
    if(video.requestVideoFrameCallback)await new Promise((resolve,reject)=>{
      const timer=setTimeout(()=>{video.cancelVideoFrameCallback(ticket);reject(Error("等待新视频帧超时"));},2500);
      const ticket=video.requestVideoFrameCallback(()=>{clearTimeout(timer);resolve();});
    });
    if(track.readyState!=="live"||track.muted)throw Error("设备已停止输出");
    const width=video.videoWidth,height=video.videoHeight;
    if(width>4096||height>4096||width*height>9000000)throw Error("图像超过尺寸限制");
    const canvas=document.createElement("canvas");canvas.width=width;canvas.height=height;
    const context=canvas.getContext("2d",{willReadFrequently:true});context.drawImage(video,0,0);
    const rgba=context.getImageData(0,0,width,height).data,rgb=new Uint8Array(width*height*3);
    for(let i=0,j=0;i<rgba.length;i+=4){rgb[j++]=rgba[i];rgb[j++]=rgba[i+1];rgb[j++]=rgba[i+2];}
    message("保存 RGB 并检测角点…");await saveImage({kind:"browser_rgb",width,height,payload:base64(rgb),name:"采集 "+new Date().toISOString(),metadata:{device:controller.getState().selected,settings:track.getSettings(),source_frame_id:null,pairing_status:"unverified",conversion:"browser video decoded to RGB via canvas"}});
  });
  on("import",async()=>{
    group();const files=Array.from($("files").files),meta=$("metadata").files[0];if(files.length!==1)throw Error("请每次只导入一张图，分别记录对应实测距离");
    if(meta&&!files[0].name.toLowerCase().endsWith(".rgb"))throw Error("配套元数据只可用于单张 RGB 导入");
    if(meta&&meta.size>16384)throw Error("元数据超过 16 KB");
    const metadata=meta?JSON.parse(await meta.text()):{};let imported=0,failed=0,lastError="";
    for(const file of files){
      message(`导入 ${file.name}…`);
      try{
        if(file.size>32*1024*1024)throw Error("单图上限 32 MB");
        await saveImage({kind:file.name.toLowerCase().endsWith(".rgb")?"rgb":"image",payload:base64(new Uint8Array(await file.arrayBuffer())),name:file.name,width:Number($("width").value),height:Number($("height").value),metadata});imported++;
      }catch(error){failed++;lastError=file.name+"："+error.message;break;}
    }
    message(`已归档 ${imported} 张；导入错误 ${failed}。${lastError||"角点未检出图也会保留，请在列表中检查。"}`,failed>0);
  });
  // Purpose: import only a current, complete local receiver frame and retain
  // exact RAW8 bytes; derived RGB never becomes a claimed FPGA S1 snapshot.
  on("capture-network",async()=>{
    group();const context=manual();message("读取网口最新完整原图…");
    const sample=await api("/api/calibration/live",{dataset:current,role:$("role").value,manual:context});await refresh();showSample(sample);
  });
  on("solve",async()=>{
    group();message("正在求解和验证，请稍候…");const result=await api("/api/calibration/solve",{dataset:current});await refresh();
    showResult(result);
    const coverage=document.createElement("div");coverage.className="coverage";coverage.setAttribute("aria-label","4×3 视场覆盖角点数");
    for(const count of result.coverage_4x3.flat()){const item=document.createElement("span");item.textContent=count+" 点";if(!count)item.className="empty";coverage.append(item);}
    $("downloads").append(coverage);message("候选参数已导出；来源、独立网格与板端应用仍需验证。");
  });
  // Purpose: release both the video track and the GPU/reference loop on navigation.
  window.addEventListener("pagehide",()=>{tuning.destroy();controller.destroy();});
  // Resume the previously opened card on navigation; the shared controller
  // releases this origin's other preview first and retains unverified identity.
  action(async()=>{
    token=(await api("/api/session")).token;await refresh();await refreshRecords();
    if(controller.getState().supported){
      await controller.refresh();
      if(storage?.getItem("pango.capture.resume")==="1"&&controller.getState().selected)await controller.open();
    }
    message("选择或创建标定组后开始采集。");
  });
})();


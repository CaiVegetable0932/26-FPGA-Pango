/* Editable reference workbench. Both views share a captured RGB canvas;
 * live input is explicitly selected and never substitutes for FPGA HDMI. */
(function(){
  "use strict";
  const STORAGE="pango.fisheye-preview.v1",math=window.PangoFisheyePreview,$=id=>document.getElementById(id);

  function create({video,storage=null}){
    const form=$("tuning-parameters"),original=$("tuning-original"),context=original.getContext("2d",{willReadFrequently:true});
    let params=math.preset(),renderer=null,valid=true,ready=false,disposed=false,frozen=false,revision=0;
    let frameTicket=0,lastDraw=0,lastVideoTime=-1,lastAdvance=0,lastStatus="",sampleTicket=0,samples=[],urlFor=null;
    let sampleCanvas=null,sampleId="",sampleGroup="",drawCount=0,fpsCount=0,fpsTime=performance.now(),fps=0;
    try{const saved=JSON.parse(storage?.getItem(STORAGE)||"null");if(saved?.schema===STORAGE)params=math.normalize(saved.parameters);}catch{}
    const keys=Object.keys(params).filter(key=>key!=="model");
    // Purpose: pressing Enter edits parameters without navigating/reloading
    // the page; use an external handler compatible with the site's CSP.
    form.addEventListener("submit",event=>event.preventDefault());
    function status(text,error=false){
      if(lastStatus===text)return;lastStatus=text;$("tuning-status").textContent=text;$("tuning-status").classList.toggle("error",error);
    }
    function fill(){
      for(const key of keys){form.elements.namedItem(key).value=String(params[key]);const range=form.querySelector(`[data-parameter="${key}"]`);if(range)range.value=String(params[key]);}
      identifyPreset();
    }
    // Purpose: identify exact presets after restore/import/edit, so a modified
    // or previously saved setting is not mislabelled as the reviewed defaults.
    function identifyPreset(){
      const name=["user-reviewed200","equidistant200","equidistant180","equisolid200"].find(name=>{
        const candidate=math.preset(name);return keys.every(key=>Math.abs(params[key]-candidate[key])<1e-9);
      });
      $("tuning-preset").value=name||"custom";
    }
    function draw(){
      if(!ready||!valid||!renderer)return;
      try{
        renderer.render(original,params);drawCount++;fpsCount++;
        $("tuning-corrected").dataset.parameterRevision=String(revision);$("tuning-corrected").dataset.renderCount=String(drawCount);
        const mode=$("tuning-source").value==="sample"?"已保存样本":frozen?"冻结帧":"实时采集卡";
        const shownFps=$("tuning-source").value==="sample"||frozen?0:fps;
        status(`${mode} · ${original.width}×${original.height} · 参数参考 ${params.reference_width}×${params.reference_height} · ${renderer.kind} · ${shownFps.toFixed(1)} FPS · 参数版本 ${revision}`);
      }catch(error){valid=false;renderer.clear();status(error.message,true);}
    }
    // Purpose: keep incomplete edits visible and pause only the correction view;
    // the last valid settings are persisted only after complete validation.
    function edit(){
      try{
        const value={model:"fisheye_equidistant"};
        for(const key of keys){const raw=form.elements.namedItem(key).value;value[key]=raw.trim()===""?NaN:Number(raw);}
        params=math.normalize(value);valid=true;revision++;identifyPreset();
        try{storage?.setItem(STORAGE,JSON.stringify(math.exportSettings(params)));}catch{}
        draw();if(!ready)status("参数已更新；打开采集卡或选择已保存样本即可预览。");
      }catch(error){valid=false;renderer?.clear();status(error.message,true);}
    }
    form.addEventListener("input",event=>{
      if(event.target.dataset.parameter)form.elements.namedItem(event.target.dataset.parameter).value=event.target.value;
      else{const range=form.querySelector(`[data-parameter="${event.target.name}"]`);if(range)range.value=event.target.value;}
      edit();
    });
    // Purpose: apply a selected named preset explicitly while retaining the
    // operator's last manual settings across ordinary refreshes.
    $("tuning-reset").addEventListener("click",()=>{
      try{params=math.preset($("tuning-preset").value);fill();edit();}
      catch(error){status(error.message,true);}
    });
    $("tuning-export").addEventListener("click",()=>{
      if(!valid){status("请先修正参数后再导出。",true);return;}
      const url=URL.createObjectURL(new Blob([JSON.stringify(math.exportSettings(params),null,2)],{type:"application/json"}));
      const link=document.createElement("a");link.href=url;link.download="fisheye-manual-preview.json";link.click();setTimeout(()=>URL.revokeObjectURL(url),1000);
    });
    $("tuning-import").addEventListener("change",async event=>{
      try{
        const file=event.target.files[0];if(!file)return;if(file.size>16384)throw Error("参数文件上限 16 KB");
        const imported=JSON.parse(await file.text());if(imported.schema!==STORAGE)throw Error("请导入本页导出的调参 JSON");
        params=math.normalize(imported.parameters);fill();edit();
      }catch(error){status(error.message,true);}finally{event.target.value="";}
    });

    // Purpose: archive review reads exact saved RGB bytes, including rejected
    // calibration images, without overwriting their original measurements.
    async function loadSample(id){
      const sample=samples.find(s=>s.id===id),ticket=++sampleTicket;ready=false;sampleCanvas=null;clear();
      if(!sample){status("本组暂无保存的样本；可在下方打开采集卡预览。");return;}
      status("正在读取已保存样本…");
      try{
        const response=await fetch(urlFor(sample.id,"image.rgb"),{cache:"no-store"});if(!response.ok)throw Error("读取样本失败");
        const rgb=new Uint8Array(await response.arrayBuffer());if(disposed||ticket!==sampleTicket)return;
        if(rgb.length!==sample.width*sample.height*3)throw Error("样本 RGB 字节数与尺寸不符");
        sampleCanvas=document.createElement("canvas");sampleCanvas.width=sample.width;sampleCanvas.height=sample.height;
        const ctx=sampleCanvas.getContext("2d"),rgba=ctx.createImageData(sample.width,sample.height);
        for(let i=0,j=0;i<rgb.length;i+=3,j+=4){rgba.data[j]=rgb[i];rgba.data[j+1]=rgb[i+1];rgba.data[j+2]=rgb[i+2];rgba.data[j+3]=255;}
        ctx.putImageData(rgba,0,0);sampleId=id;
        if($("tuning-source").value==="sample"){copy(sampleCanvas);draw();}
      }catch(error){if(ticket===sampleTicket)status(error.message,true);}
    }
    function clear(){ready=false;context.clearRect(0,0,original.width,original.height);renderer?.clear();}
    function copy(source){
      const width=source.videoWidth||source.width,height=source.videoHeight||source.height;
      if(original.width!==width||original.height!==height){original.width=width;original.height=height;}
      context.drawImage(source,0,0,width,height);ready=true;
    }
    $("tuning-source").addEventListener("change",()=>{
      frozen=false;$("tuning-freeze").textContent="冻结当前画面";lastVideoTime=-1;clear();
      if($("tuning-source").value==="sample")loadSample($("tuning-sample").value);
      else status("等待采集卡新帧；请在下方打开预览。");
    });
    $("tuning-sample").addEventListener("change",()=>{
      $("tuning-source").value="sample";frozen=false;$("tuning-freeze").textContent="冻结当前画面";loadSample($("tuning-sample").value);
    });
    $("tuning-freeze").addEventListener("click",()=>{
      if($("tuning-source").value!=="live"||!ready){status("冻结需要正在显示的实时采集卡画面。",true);return;}
      frozen=!frozen;$("tuning-freeze").textContent=frozen?"继续实时画面":"冻结当前画面";lastVideoTime=-1;draw();
    });
    // A deliberate device-open action switches to live input; moving between
    // saved samples never opens a video device or restarts the board.
    video.addEventListener("playing",()=>{$("tuning-source").value="live";frozen=false;$("tuning-freeze").textContent="冻结当前画面";lastVideoTime=-1;});
    video.addEventListener("emptied",()=>{if($("tuning-source").value==="live"&&!frozen){clear();status("采集卡已关闭；请选择保存的样本或重新打开预览。");}});
    $("tuning-corrected").addEventListener("webglcontextlost",event=>{event.preventDefault();valid=false;status("GPU 预览已中断，请刷新页面。",true);});

    // Purpose: capture each live frame once so both panes show the same software
    // input; limit UI throughput and report it independently of camera/FPGA FPS.
    function tick(now){
      if(disposed)return;frameTicket=requestAnimationFrame(tick);
      if(document.hidden||$("tuning-source").value!=="live"||frozen||!renderer)return;
      const track=video.srcObject?.getVideoTracks()[0];
      if(video.readyState<2||!video.videoWidth||track?.muted||track?.readyState!=="live"){
        if(ready)clear();status("等待实时采集卡画面；请在下方打开预览。");return;
      }
      if(video.currentTime!==lastVideoTime&&now-lastDraw>=1000/renderer.maxFps){
        lastVideoTime=video.currentTime;lastDraw=now;lastAdvance=now;copy(video);draw();
      }else if(lastAdvance&&now-lastAdvance>1500){if(ready)clear();status("采集卡画面停止更新，请检查设备输出。",true);}
      if(now-fpsTime>=1000){fps=fpsCount*1000/(now-fpsTime);fpsCount=0;fpsTime=now;}
    }
    fill();
    try{renderer=math.createRenderer($("tuning-corrected"));status("已预置近似鱼眼参数；打开采集卡或选择保存样本。");frameTicket=requestAnimationFrame(tick);}
    catch(error){status(error.message,true);}
    return {
      setSamples(items,artifact,groupId){
        const changed=sampleGroup!==groupId;sampleGroup=groupId;samples=items;urlFor=artifact;
        const selected=changed?"":$("tuning-sample").value;
        $("tuning-sample").replaceChildren(...items.map(s=>{const o=document.createElement("option");o.value=s.id;o.textContent=`${s.name} · ${s.width}×${s.height}`;return o;}));
        $("tuning-sample").value=items.some(s=>s.id===selected)?selected:items[items.length-1]?.id||"";
        if(!video.srcObject&&!frozen&&items.length){$("tuning-source").value="sample";if(changed||sampleId!==$("tuning-sample").value)loadSample($("tuning-sample").value);}
        else if(changed&&$("tuning-source").value==="sample")loadSample($("tuning-sample").value);
      },
      destroy(){disposed=true;sampleTicket++;cancelAnimationFrame(frameTicket);renderer?.dispose();}
    };
  }
  window.PangoFisheyeTuning={create};
})();

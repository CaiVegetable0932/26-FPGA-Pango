/* Explicit persistent controls for the server-owned FPGA recovery daemon.
   Polls show status only: they never upload, change video owners or replace edits. */
(function(root){
  "use strict";
  function create({request,environment=root}){
    const $=id=>environment.document.getElementById(id);
    const fields={enabled:"autoload-enabled",preset_path:"autoload-preset",rotation_deg:"autoload-rotation",
      enhance:"autoload-enhance",mode:"autoload-mode",markers:"autoload-markers",diameter:"autoload-diameter"};
    let ended=false,loaded=false,pending=false,timer=null;
    function render(state,fill=false){
      $("autoload-status").textContent=state.message+
        (state.active_version!==null&&state.active_version!==undefined?` · 活动参数 ${state.active_version}`:"")+
        (state.displayed_version!==null&&state.displayed_version!==undefined?` · HDMI 参数 ${state.displayed_version}`:"")+
        (state.retry_in_seconds?` · ${state.retry_in_seconds}s 后重试`:"")+
        (state.log_error?` · 日志保存失败：${state.log_error}`:"");
      if(fill||!loaded){
        for(const [key,id] of Object.entries(fields)){
          if(["enabled","enhance","markers"].includes(key))$(id).checked=state.settings[key];
          else $(id).value=String(state.settings[key]);
        }
        loaded=true;
      }
    }
    async function refresh(){
      try{const state=await request("/api/board/autoload");if(!ended)render(state);}
      catch(error){if(!ended)$("autoload-status").textContent=error.message;}
    }
    async function save(){
      if(pending||ended)return;
      pending=true;$("autoload-save").disabled=true;
      try{
        // Consent is a saved checkbox, not an implicit effect of page opening.
        const data=Object.fromEntries(Object.entries(fields).map(([key,id])=>[key,
          ["enabled","enhance","markers"].includes(key)?$(id).checked:$(id).value]));
        data.preset_path=data.preset_path.trim();data.rotation_deg=Number(data.rotation_deg);data.diameter=Number(data.diameter);
        render(await request("/api/board/autoload",data),true);
      }catch(error){$("autoload-status").textContent=error.message;}
      finally{pending=false;$("autoload-save").disabled=false;}
    }
    async function load(){
      // The file is an explicit review input; this GET neither writes FPGA
      // parameters nor claims the displayed words were read from the board.
      try{
        const value=await request("/api/board/autoload/preset");
        $("fpga-parameters").value=JSON.stringify(value.preset,null,2);
        $("fpga-rotation").value=String(value.settings.rotation_deg);$("fpga-enhance").checked=value.settings.enhance;
        $("autoload-status").textContent="已填入已保存的自动恢复文件，仅供审校；不代表板上活动参数。SHA-256 "+value.preset_sha256;
      }catch(error){$("autoload-status").textContent=error.message;}
    }
    async function poll(){await refresh();if(!ended)timer=environment.setTimeout(poll,2000);}
    $("autoload-save").addEventListener("click",save);$("autoload-load").addEventListener("click",load);
    return {init:poll,refresh,destroy(){ended=true;environment.clearTimeout(timer);
      $("autoload-save").removeEventListener("click",save);$("autoload-load").removeEventListener("click",load);}};
  }
  const api={create};root.PangoBoardAutoload=api;
  if(typeof module!=="undefined"&&module.exports)module.exports=api;
})(typeof globalThis!=="undefined"?globalThis:this);

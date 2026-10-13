/* Bounded preview telemetry. CPU submission is distinct from screen presentation. */
(function(root){
  "use strict";
  function distribution(values){
    const sorted=values.filter(Number.isFinite).sort((a,b)=>a-b);
    const at=q=>sorted.length?sorted[Math.max(0,Math.ceil(sorted.length*q)-1)]:null;
    return {count:sorted.length,p50:at(.5),p95:at(.95),p99:at(.99),max:at(1)};
  }
  function create(now=()=>performance.now()){
    let samples=[],clock=null,last=null,longTasks=[],replaced=0,rejected=0;
    // The best RTT exchange bounds network asymmetry; estimates are never
    // subtracted across unrelated clocks without this explicit uncertainty.
    function sync(sent,received,server){
      const rtt=received-sent-(server.sent_ms-server.received_ms);
      if(server.clock!=="host_monotonic_ms"||!Number.isFinite(rtt)||rtt<0)return;
      const value={offset_ms:(sent+received-server.received_ms-server.sent_ms)/2,
        uncertainty_ms:rtt/2,synced_at:received};
      if(!clock||received-clock.synced_at>30000||value.uncertainty_ms<clock.uncertainty_ms)clock=value;
    }
    function record(value){
      const t=now(),complete=value.meta?.host_timing?.complete_ms;
      const age=clock&&t-clock.synced_at<60000&&Number.isFinite(complete)?t-complete-clock.offset_ms:null;
      samples.push({...value,submitted_ms:t,interval_ms:last===null?null:t-last,
        frame_age_estimate_ms:age===null?null:Math.max(0,age)});
      if(samples.length>512)samples.shift();last=t;
    }
    return {sync,record,replace(){replaced++;},reject(){rejected++;},
      longTask(duration){longTasks.push(duration);if(longTasks.length>256)longTasks.shift();},
      reset(){samples=[];last=null;},
      snapshot(queue={}){
        const stages={};
        for(const name of ["interval_ms","fetchMs","convertMs","workerPaintMs","bitmapTransferMs","workerToMainMs","queueMs","workerWaitMs","paintMs","frame_age_estimate_ms"])
          stages[name]=distribution(samples.map(s=>s[name]));
        return {scope:"host_receive_to_canvas_submission_not_optical_latency",window_limit:512,
          stages,latest:samples.at(-1)||null,latest_submission_age_ms:last===null?null:now()-last,
          // During a source stall, picture age must continue rising even when
          // the last measured submission itself was fast.
          latest_frame_age_estimate_ms:last===null||!Number.isFinite(samples.at(-1)?.frame_age_estimate_ms)?null:
            samples.at(-1).frame_age_estimate_ms+now()-last,
          clock:clock&&now()-clock.synced_at<60000?clock:null,
          preview_replaced:replaced,stale_results_rejected:rejected,queue,
          long_tasks_ms:distribution(longTasks)};
      }};
  }
  const api={create,distribution};root.PangoPreviewDiagnostics=api;
  if(typeof module!=="undefined")module.exports=api;
})(typeof self!=="undefined"?self:globalThis);

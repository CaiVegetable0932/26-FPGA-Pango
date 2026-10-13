/* Verify clock bounds and bounded samples without claiming optical latency. */
"use strict";
const {test}=require("node:test"),assert=require("node:assert/strict");
const {create}=require("../web/preview-diagnostics.js");
test("Unrelated clocks remain unpaired until an RTT exchange exists",()=>{
  let now=110;const d=create(()=>now);
  d.record({meta:{host_timing:{complete_ms:1000}}});
  assert.equal(d.snapshot().latest.frame_age_estimate_ms,null);
  d.sync(100,120,{clock:"host_monotonic_ms",received_ms:1005,sent_ms:1015});
  now=150;d.record({meta:{host_timing:{complete_ms:1040}}});
  assert.equal(d.snapshot().latest.frame_age_estimate_ms,10);
  assert.equal(d.snapshot().clock.uncertainty_ms,5);
  now=60121;d.record({meta:{host_timing:{complete_ms:1040}}});
  assert.equal(d.snapshot().latest.frame_age_estimate_ms,null);
});
test("Tail durations, idle age and queues remain independently bounded",()=>{
  let now=0;const d=create(()=>now);
  for(let i=0;i<1000;i++){now+=i===999?1000:33;d.record({fetchMs:i});d.longTask(i);}
  d.replace();d.reject();now+=2000;
  const s=d.snapshot({executing:1,pending:1});
  assert.equal(s.stages.fetchMs.count,512);assert.equal(s.long_tasks_ms.count,256);
  assert.equal(s.stages.interval_ms.max,1000);assert.equal(s.latest_submission_age_ms,2000);
  assert.equal(s.preview_replaced,1);assert.equal(s.stale_results_rejected,1);
  assert.deepEqual(s.queue,{executing:1,pending:1});
});

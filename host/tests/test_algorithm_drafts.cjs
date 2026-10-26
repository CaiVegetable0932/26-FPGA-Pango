/* Independent boundary vectors for the decimal editor -> wire draft bridge. */
'use strict';
const assert = require('node:assert/strict');
const {color, quantize, importEntity} = require('../web/algorithm_drafts.js');
const base = {awb_min:2048, awb_max:8192, awb_step:16, awb_hold_frames:30};
const input = {ccm:[1, -0.25, 0, 0, 1.5, 0, 0, 0, 1], gain:[1, 1.25, 1, 2], black:[0, 16, 32, 255], enabled:true, wbMode:0, calibration:7};
const actual = color(base, input);
assert.deepEqual(actual.ccm, [16384, -4096, 0, 0, 24576, 0, 0, 0, 16384]);
assert.deepEqual(actual.channel_gain, [4096, 5120, 4096, 8192]);
assert.equal(actual.awb_hold_frames, 30);
assert.equal(quantize(-0.5 / 16384, 14, -131072, 131071, 'CCM'), -1);
assert.throws(() => color(base, {...input, ccm:[7, 2, 0, 0, 1, 0, 0, 0, 1]}), /每行/);
assert.throws(() => color(base, {...input, black:[0, 1.5, 0, 0]}), /整数/);
assert.throws(() => color(base, {...input, gain:['', 1, 1, 1]}), /不能为空/);
assert.throws(() => color(base, {...input, gain:[NaN, 1, 1, 1]}), /范围/);
assert.deepEqual(importEntity(JSON.stringify({schema:1, kind:3, draft:actual}), 3), actual);
assert.throws(() => importEntity(JSON.stringify({schema:1, kind:7, draft:actual}), 3), /不一致/);
console.log('ALGORITHM_DRAFTS_PASS: decimal rounding, signed CCM, row bound, black/gain domain, AWB retention, typed import');

// Saved legacy drafts cannot restore withdrawn motion functionality.
for (const [kind, draft] of [[4,{enabled:0}], [5,{mode:2}], [6,{enabled:1}]])
  assert.throws(() => importEntity(JSON.stringify({schema:1,kind,draft}),kind), /C4/);
assert.deepEqual(importEntity(JSON.stringify({schema:1,kind:6,draft:{enabled:0}}),6), {enabled:0});

/* Board control UI: keep draft, queued, source-applied and scanout states
   separate. No PC image transform is invoked by the hardware switch. */
(() => {
  'use strict';
  const $ = id => document.getElementById(id);
  const controls = ['affine-enable', 'geometry-submit', 'geometry-load', 'reference-submit', 'reference-load', 'reference-cancel', 'entity-read', 'entity-submit', 'entity-example', 'entity-load', 'draft-build', 'motion-reset', 'history-clear'];
  let token = null, current = null, busy = false;
  async function execute(action, extra = {}) {
    if (busy) return;
    busy = true;
    for (const id of ['algorithm-read', ...controls]) $(id).disabled = true;
    $('algorithm-message').textContent = action === 'read' ? '正在读取…' : '正在发送，等待板端校验…';
    try {
      const response = await fetch('/api/algorithms', {method: 'POST', headers: {
        'Content-Type': 'application/json', 'X-Pango-Token': token},
        body: JSON.stringify({action, port: $('algorithm-port').value, ...extra})});
      const result = await response.json();
      if (!response.ok) throw new Error(result.error || '操作失败');
      current = result;
      if (result.entity) { const {body_hex, ...visible} = result.entity; $('entity-state').textContent = JSON.stringify(visible, null, 2); }
      const s = result.state;
      $('affine-enable').checked = s.requested_enable;
      $('source-state').textContent = `${s.applied_enable ? 'ON' : 'OFF'} · 版本 ${s.control_version} · 源帧 ${s.source_frame_id}${s.pending ? ' · 新请求等待生效' : ''}`;
      $('display-state').textContent = s.display_known ? `${s.display_enable ? 'ON' : 'OFF'} · 版本 ${s.display_control_version} · 源帧 ${s.display_frame_id}` : '未取得板端显示描述符确认';
      // PC-only firmware applies the frozen PC matrix directly.
      const matrixLabel = result.features?.mcu_auto_pose ? '源帧选择的基准六系数（最终矩阵见运动帧）' : '源帧采用的 PC 六系数';
      $('affine-details').textContent = `${matrixLabel}：${s.coefficients.join(', ')}\n几何版本 ${s.geometry_version} · 参考版本 ${s.reference_version} · epoch ${s.source_epoch}`;
      $('algorithm-message').textContent = `${result.message}。${result.features?.entity_body_readback === false ? '图像配置仅回读状态摘要；修改时请提交完整草稿。' : ''}C4 已撤销；动态裁边与历史配准补全不可用。`;
      $('reference-state').textContent = result.reference ? `参考版本 ${result.reference.version} · ${result.reference.pending ? '等待源帧生效' : '已应用'} · 源帧 ${result.reference.source_frame_id}` : '该位流未提供参考实体上传';
    } catch (error) {
      current = null;
      $('algorithm-message').textContent = `失败：${error.message}。请重新读取实际状态。`;
      $('source-state').textContent = '未知；操作失败后需重新查询';
      $('display-state').textContent = '未知';
    } finally {
      busy = false;
      $('algorithm-read').disabled = false;
      for (const id of controls) $(id).disabled = !current || current.state.pending;
      for (const id of ['reference-submit', 'reference-load', 'reference-cancel']) $(id).disabled = !current?.reference || current.state.pending;
      updateEntityButtons();
    }
  }
  $('algorithm-read').onclick = () => execute('read');
  $('affine-enable').onchange = () => execute('affine', {enabled: $('affine-enable').checked});
  $('geometry-load').onclick = () => {
    if (!current) return;
    $('geometry-draft').value = JSON.stringify(current.geometry.coefficients, null, 2);
    $('geometry-id').value = current.geometry.entity_id;
  };
  // Preview operates on a draft only. It does not acquire a serial port or
  // mutate the FPGA state; acceptance still occurs in the complete submission.
  $('draft-build').onclick = async () => {
    if (!current?.reference) return;
    try {
      const response = await fetch('/api/algorithms', {method:'POST', headers:{'Content-Type':'application/json', 'X-Pango-Token':token}, body:JSON.stringify({action:'preview', reference:current.reference, geometry:current.geometry.coefficients, transform:{angle_deg:Number($('draft-angle').value), translate_x:Number($('draft-x').value), translate_y:Number($('draft-y').value), scale:Number($('draft-scale').value)}})});
      const draft = await response.json();
      if (!response.ok) throw new Error(draft.error);
      $('geometry-draft').value = JSON.stringify(draft.coefficients, null, 2);
      const ctx = $('draft-mask').getContext('2d');
      draft.preview_mask.forEach((v,i) => {ctx.fillStyle=v?'#38886a':'#222'; ctx.fillRect((i%64)*10,Math.floor(i/64)*10,10,10);});
      $('draft-coverage').textContent = `采样有效比例 ${(draft.estimated_valid_fraction*100).toFixed(1)}%；浮点预览，不代替 RTL 逐像素有效域验收。尚未提交。`;
    } catch(error) { $('draft-coverage').textContent=error.message; }
  };
  $('geometry-submit').onclick = () => {
    try { execute('geometry', {model: 'affine_lens', entity_id: Number($('geometry-id').value),
      coefficients: JSON.parse($('geometry-draft').value)}); }
    catch (error) { $('algorithm-message').textContent = `草稿无效：${error.message}`; }
  };
  $('reference-load').onclick = () => {
    if (!current?.reference) return;
    const r = current.reference, [fx, fy, cx, cy] = r.intrinsics;
    $('reference-draft').value = JSON.stringify({fx, fy, cx, cy, width: r.width,
      height: r.height, calibration_id: r.calibration_id}, null, 2);
    $('reference-id').value = r.entity_id;
  };
  $('reference-submit').onclick = () => {
    try { execute('reference', {entity_id: Number($('reference-id').value),
      reference: JSON.parse($('reference-draft').value)}); }
    catch (error) { $('algorithm-message').textContent = `参考草稿无效：${error.message}`; }
  };
  $('reference-cancel').onclick = () => execute('cancel_upload');
  // Safe examples never enable motion, exposure feedback or an uncalibrated
  // model. Firmware validates all fields again before accepting a transaction.
  const examples = {
    1: {mode:0, curve:1, allowed_mask:7, hysteresis:4, low:96, high:144, hold_frames:16, lut_version:0},
    2: {gamma:1.0},
    3: {black_level:[0,0,0,0], channel_gain:[4096,4096,4096,4096], ccm:[16384,0,0,0,16384,0,0,0,16384], ccm_enabled:false, wb_mode:0, calibration_id:0, awb_min:2048, awb_max:8192, awb_step:16, awb_hold_frames:16},
    5: {mode:0, fixed_zoom_q16:65536, max_zoom_q16:78643, step_q16:256, hysteresis_q16:512, min_area_q16:32768, calibration_id:0},
    6: {enabled:0, max_age:1, min_confidence:32, max_luma_delta:16, registration_version:0},
    7: {mode:0, flicker:0, low:96, high:144, exposure:8000, gain:16, gain_min:16, gain_max:128, gain_step:1, exposure_min:16, exposure_max:17856, exposure_step:16, hold_frames:30, settle_frames:3, line_time_ns:0, period150_code:0, timing_calibration_id:0},
    8: {enabled:0, calibration_id:0, reference_pitch_mdeg:0, reference_yaw_mdeg:0, pitch_min_mdeg:-1000, pitch_max_mdeg:1000, yaw_min_mdeg:-1000, yaw_max_mdeg:1000, max_model_error_q16:65536, max_time_error_us:1000, model_source_id:0, expected_mcu_config:0, reference_q26:[67108864,0,0,0,67108864,0], j_pitch_q26:[0,0,0,0,0,0], j_yaw_q26:[0,0,0,0,0,0]}
  };
  function updateEntityButtons() {
    // C4 withdrawal overrides even a legacy capability reply.
    $('motion-reset').disabled = true;
    $('history-clear').disabled = busy || !current || !(current.kind_mask & (1 << 6));
    const kind = Number($('entity-kind').value);
    $('color-editor').hidden = kind !== 3;
    const supported = kind !== 4 && !!current && !!(current.kind_mask & (1 << kind));
    $('entity-read').disabled = busy || !supported;
    $('entity-submit').disabled = busy || !supported || kind === 11;
    $('entity-example').disabled = busy || !supported || kind === 11;
    $('entity-load').disabled = busy || !supported || kind === 11 || current?.entity?.kind !== kind || !current.entity.values;
  }
  $('motion-reset').onclick = () => execute('reset_motion');
  $('history-clear').onclick = () => execute('clear_history');
  $('entity-kind').onchange = updateEntityButtons;
  $('entity-read').onclick = () => execute('entity_read', {kind:Number($('entity-kind').value)});
  $('entity-load').onclick = () => { $('entity-draft').value = JSON.stringify(current.entity.values, null, 2); $('entity-id').value = current.entity.entity_id; if (current.entity.kind === 3) loadColorDraft(); };
  $('entity-example').onclick = () => {
    $('entity-draft').value = JSON.stringify(examples[Number($('entity-kind').value)], null, 2);
    if (Number($('entity-kind').value) === 3) loadColorDraft();
  };
  // All editor and file operations remain local drafts. Quantization uses
  // symmetric rounding and preserves the existing bounded-AWB policy fields.
  for (let i = 0; i < 9; i++) {
    const input = document.createElement('input');
    input.type = 'number'; input.step = '0.00006103515625'; input.id = `color-m${i}`;
    input.setAttribute('aria-label', `CCM 第 ${Math.floor(i / 3) + 1} 行第 ${i % 3 + 1} 列`);
    input.value = i % 4 === 0 ? '1' : '0'; $('color-matrix').append(input);
  }
  ['R', 'Gr', 'Gb', 'B'].forEach((channel, i) => {
    for (const [field, text, initial, step] of [['black', '黑电平', 0, 1], ['gain', '增益', 1, 1 / 4096]]) {
      const label = document.createElement('label'), input = document.createElement('input');
      label.textContent = `${channel} ${text} `; input.id = `color-${field}${i}`;
      input.type = 'number'; input.step = step; input.value = initial;
      label.append(input); $('color-channels').append(label);
    }
  });
  function loadColorDraft() {
    try {
      const value = JSON.parse($('entity-draft').value);
      if (value.ccm?.length !== 9 || value.channel_gain?.length !== 4 || value.black_level?.length !== 4)
        throw new Error('请先载入完整颜色草稿');
      value.ccm.forEach((v, i) => { $(`color-m${i}`).value = v / 16384; });
      value.channel_gain.forEach((v, i) => { $(`color-gain${i}`).value = v / 4096; });
      value.black_level.forEach((v, i) => { $(`color-black${i}`).value = v; });
      $('color-enabled').checked = !!value.ccm_enabled; $('color-wb').value = value.wb_mode;
      $('color-calibration').value = value.calibration_id;
      $('draft-message').textContent = '颜色草稿已载入编辑框；尚未提交。';
    } catch (error) { $('draft-message').textContent = error.message; }
  }
  $('color-load').onclick = loadColorDraft;
  $('color-identity').onclick = () => {
    for (let i = 0; i < 9; i++) $(`color-m${i}`).value = i % 4 === 0 ? 1 : 0;
    $('draft-message').textContent = '编辑框已恢复单位矩阵；请量化到草稿后再提交。';
  };
  $('color-stage').onclick = () => {
    try {
      const base = $('entity-draft').value.trim() ? JSON.parse($('entity-draft').value) : examples[3];
      const values = (prefix, count) => Array.from({length: count}, (_, i) => $(`color-${prefix}${i}`).value);
      const draft = AlgorithmDrafts.color(base, {ccm: values('m', 9), gain: values('gain', 4), black: values('black', 4),
        enabled: $('color-enabled').checked, wbMode: $('color-wb').value, calibration: $('color-calibration').value});
      $('entity-draft').value = JSON.stringify(draft, null, 2);
      $('draft-message').textContent = '完整颜色草稿已量化；下方提交按钮才会发送。';
    } catch (error) { $('draft-message').textContent = error.message; }
  };
  $('entity-import').onchange = async event => {
    try {
      const file = event.target.files[0]; if (!file) return;
      if (file.size > 65536) throw new Error('实体文件超过 64 KiB');
      const kind = Number($('entity-kind').value);
      const draft = AlgorithmDrafts.importEntity(await file.text(), kind);
      $('entity-draft').value = JSON.stringify(draft, null, 2);
      if (kind === 3) loadColorDraft();
      $('draft-message').textContent = '文件已导入草稿；未发送到 FPGA。';
    } catch (error) { $('draft-message').textContent = error.message; }
    event.target.value = '';
  };
  $('entity-export').onclick = () => {
    try {
      const kind = Number($('entity-kind').value), draft = JSON.parse($('entity-draft').value);
      const url = URL.createObjectURL(new Blob([JSON.stringify({schema: 1, kind, draft}, null, 2)], {type: 'application/json'}));
      const link = document.createElement('a'); link.href = url; link.download = `fpga-entity-${kind}-draft.json`;
      link.click(); setTimeout(() => URL.revokeObjectURL(url), 1000);
      $('draft-message').textContent = '导出的是草稿，不是板端生效证明。';
    } catch (error) { $('draft-message').textContent = error.message; }
  };
  $('entity-submit').onclick = () => {
    try { execute('entity_write', {kind:Number($('entity-kind').value), entity_id:Number($('entity-id').value), draft:JSON.parse($('entity-draft').value)}); }
    catch (error) { $('algorithm-message').textContent = `实体草稿无效：${error.message}`; }
  };
  // Changing ports invalidates all cached board values; reconnect never sends
  // an old checkbox value or a previous tab's geometry draft automatically.
  $('algorithm-port').onchange = () => {
    current = null;
    for (const id of controls) $(id).disabled = true;
    $('source-state').textContent = $('display-state').textContent = '未知';
  };
  (async () => {
    try {
      const session = await (await fetch('/api/session')).json(); token = session.token;
      const devices = await (await fetch('/api/board/devices')).json();
      for (const port of devices.ports) $('algorithm-port').add(new Option(`${port.port} · ${port.label}`, port.port));
      if (devices.ports.length === 1) $('algorithm-port').value = devices.ports[0].port;
    } catch (error) { $('algorithm-message').textContent = error.message; }
  })();
})();

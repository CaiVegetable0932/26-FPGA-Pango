/* Pure draft conversion. Fixed-point output is explicit and independently
   validated by Python and RTL before an entire entity can be committed. */
(function (root, factory) {
  const api = factory();
  if (typeof module === 'object' && module.exports) module.exports = api;
  else root.AlgorithmDrafts = api;
})(typeof globalThis !== 'undefined' ? globalThis : this, function () {
  'use strict';
  function quantize(value, bits, low, high, label) {
    if (typeof value === 'string' && !value.trim()) throw new Error(`${label} 不能为空`);
    const n = Number(value), scaled = Math.abs(n) * 2 ** bits;
    const q = Math.sign(n) * Math.floor(scaled + 0.5);
    if (!Number.isFinite(n) || q < low || q > high) throw new Error(`${label} 超出范围`);
    return q;
  }
  function color(base, controls) {
    if (controls.ccm.length !== 9 || controls.gain.length !== 4 || controls.black.length !== 4)
      throw new Error('颜色草稿需要 9 个矩阵系数和 4 个通道');
    const ccm = controls.ccm.map(v => quantize(v, 14, -131072, 131071, 'CCM'));
    for (let i = 0; i < 9; i += 3)
      if (ccm.slice(i, i + 3).reduce((s, v) => s + Math.abs(v), 0) > 131072)
        throw new Error('CCM 每行绝对值之和必须不大于 8');
    const black = controls.black.map(v => {
      const n = Number(v);
      if (!String(v).trim() || !Number.isInteger(n) || n < 0 || n > 255) throw new Error('黑电平必须为 0～255 整数');
      return n;
    });
    const calibration = Number(controls.calibration);
    if (!String(controls.calibration).trim() || !Number.isInteger(calibration) || calibration < 0 || calibration > 0xffffffff)
      throw new Error('标定 ID 必须为 u32 整数');
    return {...base, ccm, black_level: black,
      channel_gain: controls.gain.map(v => quantize(v, 12, 1, 65535, '通道增益')),
      ccm_enabled: !!controls.enabled, wb_mode: Number(controls.wbMode),
      calibration_id: calibration};
  }
  function importEntity(text, expectedKind) {
    const value = JSON.parse(text);
    if (value.schema !== 1 || value.kind !== expectedKind || !value.draft || Array.isArray(value.draft))
      throw new Error('文件的实体类型或 schema 与当前选择不一致');
    // Reject saved drafts that require the withdrawn visual registration.
    if (expectedKind === 4 || (expectedKind === 5 && value.draft.mode === 2) ||
        (expectedKind === 6 && value.draft.enabled))
      throw new Error('C4 已撤销；动态裁边和历史配准补全不可用');
    return value.draft;
  }
  return {quantize, color, importEntity};
});

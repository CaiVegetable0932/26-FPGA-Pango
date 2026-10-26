# Capture admission/control independent review — 2026-10-21

Scope: source-slot configuration, A5 actions, A6/reference selection, ISP colour, tone page ownership and camera statistics version gating. Read-only review; no owner implementation changed by this reviewer.

## P2: live colour version reaches delayed estimator start

Reviewed core connected `motion_control.colour_version` to `capture_meta.isp_version`, a live `colour_capture_version` bus. If an accepted ISP_COLOR submission coincides with capture admission, the source descriptor and admitted ISP coefficients correctly sample old active values; the colour controller sets its new pending value on that edge. At `cap_start` on the following edge, the estimator samples the new pending version instead of the current source version. The following source really uses the new ISP but has the same estimator tag, bypassing the intended colour-change invalidation of the prior thumbnail. This can affect motion and historical-pixel registration.

Requested fix: freeze an admitted colour version on `capture_valid && capture_ready` and pass that to the estimator; add the same-edge submission regression. Parent and motion owner were notified. Resolution and validation belong to their follow-up evidence.

## Other paths checked

Geometry/reference/A6 coefficients and identity, tone page/generation and camera version are frozen at admission and copied at source start. Tone pending/copy/page ownership blocks unsafe rewrite; history contains S1 before tone, so applying the current frame tone to accepted S1 history does not require identical prior tone generation. A5 pending actions and retries preserve next-boundary application when submission coincides with an empty boundary. No additional concrete defect was identified in those paths. This is bounded source inspection, not exhaustive formal verification or board validation.

## Reviewed input hashes

```json
{
  "fpga/rtl/board/video_memory_core.sv": "3ca27aec419d1739be07963fcd3958668f79699d61fd1834aa053cc40ac735a0",
  "fpga/rtl/isp/isp_colour_control.sv": "08fc0208170f10c79a2744c1201be90f83ce30b5fed5778a330d7012064b4df2",
  "fpga/rtl/geometry/tone_entity_control.sv": "5d4ee3377cb481acd90ec0508bdc9fc13008748fc6edc2e7ef6fa63b10599347",
  "fpga/rtl/control/frame_runtime_actions.sv": "d6d199b96ca56a2c4367c00d25d59b4478d590dd3ece2d146a18a6a7c0e35b94",
  "fpga/rtl/control/affine_frame_control.sv": "15107d299326b99e6df2f815eb63386394d9d1b4ca8b3e74ca382277eb0f8b9d",
  "fpga/rtl/control/frame_parameter_bank.sv": "c590ea1b639f8370dc670d14fe578b5a28849c19ceee127289ef577a9c4e0a6b",
  "fpga/rtl/stabilization/source_motion_controller.sv": "a722d06f7d25f60c652b602bbd8f74cb3fc54f5e63af04f53f7700564acd4f46"
}
```

## Resolution evidence

Motion owner added `admitted_colour_version`, frozen on the same admission edge as ISP coefficients, and used it for the delayed estimator start. Actual core regression `build/full_integration_20261013/verilator_20261021_192709_314095/result.json` PASS. The identical new fixture against prior RTL in `verilator_20261021_192720_785142` FAILS on frame 7 (colour version got 3, expected 2), establishing that the regression detects the reviewed defect rather than merely exercising the new code. This remains simulation evidence, not physical calibration or board acceptance.

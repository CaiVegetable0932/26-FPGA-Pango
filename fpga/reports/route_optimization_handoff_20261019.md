# FPGA 布线专项优化交接

状态：实施中，非最终验收。最后更新时间：2026-10-19 21:24（北京时间）。

## 项目与入口

- 本地：`D:\XDU\concept\26-FPGA-Pango`
- 远端：<https://github.com/CaiVegetable0932/26-FPGA-Pango>
- 分支：`codex/fpga-pds-project`
- 方案：`output/FPGA布线效率与拥塞专项优化方案.md`
- 会话账本：`fpga/build/route_optimization/session_20261019/session.json`
- 进度：`fpga/reports/route_optimization_progress_20261019.md`
- 新构建命令留档：`session_20261019/launch_command.json`；通过既有 `run_video_route_attempt.py` 调用，不恢复旧暂停任务。
- 状态与额度检查：`python fpga/scripts/optimization_status.py --session fpga/build/route_optimization/session_20261019`

## 当前进展与证据

已将完整 writer BRAM 候选的 11 项未推广 RTL 变更审查后同步至主源码，修改前文件与补丁归档在 `fpga/build/route_optimization/session_20261019/promotion/`。主源码 12 项集成回归通过；既有全帧模型及差分通过现有入口重新校验，不能把局部回归当作硬件验收。

活动完整工程：`fpga/build/full_integration_20261013/phys_20261019_205545_289460`。seed=11，decongestion=1，macro=Global，planning=true。每阶段默认 60 分钟外部时限，当前处于布局。尚无合格 routed、STA 或位流发布结论。

暂停当前会话：在 `fpga/build/route_optimization/session_20261019/stop_requested.json` 写入原因；监督器下一次检查会停止其拥有的 native 进程树并保留证据。不要按进程名杀所有 PDS。`fpga/build/route_optimization/native_phase.lock` 是本轮重型阶段互斥锁；如异常遗留，核对 PID/创建时间后再处理，不自动删除。

## 额度与汇报约定

用户指定 Codex **账户**剩余额度 10% 为停止线。本地本次会话 `rate_limits` 事件可提供实际百分比，状态脚本只导出额度字段与时间，不导出会话内容或认证文件。20:58 最近观察剩余 52%；该数字随执行变化，以最新带时间戳观察为准。缺失或过期事件必须标明不可确认。

用户要求每小时汇报；本轮开始约 20:48，下一小时汇报约 21:48。常规检查和阶段进展可以更频繁更新。

## Git 与未完成工作

初始 HEAD：`6fc951b3cb7a9d367b6d3c293a3e9efbb1f2c483`。工作区历史未提交内容很多，原始清单保存在会话目录。只能暂存本轮改动及必要运行依赖，不应将整个工作区全部提交。不得新增忽略项。

首批提交 `3540e9e8b7afc0c8e9fc5ba2fd6a1c0a3bdf6477` 已推送并核对。GitHub 的 Schannel 连接被重置，使用单次 `git -c http.sslBackend=openssl -c http.version=HTTP/1.1 ...` 成功；不需要关闭证书验证或修改全局设置。后续证据与候选准备仍需追加提交。

中间证据文件清单：`session_20261019/evidence_scope.txt`；哈希清单：`session_20261019/evidence_manifest.json`，为冻结的中间快照，不包含活动布线的最终结果。1,442 个输入的 Git 暂存字节 SHA-256 已全部核对。完整本机历史产物仍保留，没有将约九万项无关工作区内容混入本轮提交。

两个待综合的独立候选位于 `fpga/build/route_optimization/dma_grouped_20261019_210245_219923` 和 `boot_local_capture_20261019_211117_597873`。前者通过 10 项周期级差分及 12 组参数回归；后者通过 332,580 周期的串口与完整快照差分。队列账本为 `session_20261019/unit_queue.json`；等待当前完整工程终态后才运行两个 20 分钟限时单位综合。没有自动推广权限扩大：单位综合结果仍须审查后再选择完整工程候选。

注意本轮保持现有整机 125 MHz 真实约束；方案提出的初始 150 MHz 处理目标尚未验收，不能把本轮同约束比较当作 150 MHz 签核。

剩余验收：当前完整布线终态、setup/hold STA、外部/CDC 约束核对、有效候选的有限三 seed 稳定性、真实性能与效率比较。原基线从未合格完成时不计算加速比。没有实板测试、没有下载授权，不声称 1080p30 硬件已通过。


## 2026-10-19 21:48 ? user scope update (authoritative)

Project: `D:\XDU\concept\26-FPGA-Pango`; branch: `codex/fpga-pds-project`.
Remote: https://github.com/CaiVegetable0932/26-FPGA-Pango.git

The user now requests design-file edits and functional simulation first. Whole-design placement/routing, bitstream generation and the queued native unit screens have been stopped. Do not restart them automatically. `stop_requested.json` is intentional; the next agent must obtain the user's routing assignment before starting a separate supervised campaign. The existing campaign ended PAUSED at 21:46; it is not a successful routed result and did not generate a qualified bitstream. The unit queue is STOPPED with zero jobs launched.

Canonical RTL now includes the grouped binary DMA selection and the boot status snapshot local capture enables, in addition to the previous 11-file writer-BRAM baseline. Both new candidates passed independent cycle-level proofs before integration. Their combined canonical RTL passed all 20 default integration tests at `fpga/build/full_integration_20261013/sim_20261019_214617_365522`. Full-frame snapshot and runtime-control supplementary simulations are pending at this timestamp. Physical resource, congestion and timing benefits of these two changes remain UNVERIFIED; simulation equivalence does not establish those benefits.

Promotion backup and SHA-256 manifest: `fpga/build/route_optimization/session_20261019/simulation_only_promotion/`. Candidate-specific proofs and combined evidence are listed in `composed_evidence_manifest.json`. Earlier checkpoint `7ffb6639dd6b47bf309c40336676e9b2d807da9c` was pushed successfully. Account quota observed at 21:47: approximately 50% remaining (weekly primary window). Preserve the 10% reserve policy if optimization resumes.

The real existing board processing constraint remains 125 MHz. The plan's 150 MHz target, routed setup/hold, three-seed stability and physical 1080p30 acceptance are still outstanding. No hardware programming was performed.

Git transport uses per-command `-c http.proxy=http://127.0.0.1:7897 -c http.sslBackend=openssl -c http.version=HTTP/1.1`; no global Git settings or certificate validation were changed. Historical unrelated workspace changes must not be included in a broad add/commit.


## 2026-10-19 21:48 ? regional verification authorized

This later instruction supersedes the simulation-only restriction above: regional synthesis and isolated regional placement/routing A/B tests are authorized. Whole-design routing and bitstream generation remain forbidden until the entire design plan is complete. Keep the whole-design stop file intact. Regional jobs use `regional_stop_requested.json`; at the account reserve threshold both kinds of jobs must stop. Do not restart the old automatic queue. Run regional screens sequentially under the native-slot supervisor, compare identical boundaries/constraints, and report results as isolated evidence rather than board signoff.

Combined canonical 20-case regression passed; additional runtime-control scenario passed at `fpga/build/full_integration_20261013/sim_20261019_214713_180909`. The 1920x1080 snapshot simulation remains running. DMA baseline/candidate regional synthesis started in `fpga/build/route_optimization/dma_grouped_20261019_210245_219923/owner_unit_probe_20261019_214842_425939`.


## 2026-10-19 22:03 regional checkpoint

Whole-design entry points now enforce `fpga/config/implementation_readiness.json` before starting or resuming physical work. Its completion/review/permission flags remain false. A real invocation of the resume entry point was rejected before any build mutation or native launch. Regional physical probes only allow `ddr_native_dma` and `pc_video_boot`; they cannot generate bitstreams.

Regional verification matrix: `fpga/reports/regional_verification_plan_20261019.md`. DMA A/B synthesis completed with inputs intact: baseline LUT 3950 / FF 1508 / DRM 28 / controlsets 51; grouped candidate LUT 4047 / FF 1512 / DRM 28 / controlsets 51. Synthesis clock slack estimate changed 0.216 to 0.211 ns (slow row), with 0.552 ns unchanged in the second row. This is not routed timing and does not yet establish a locality benefit. Do not add isolated resources to board totals.

DMA isolated physical A/B is running under `owner_unit_probe_20261019_214842_425939/regional_route_20261019_215701_945412`, bounded to 20 minutes per side including fresh compile/synthesis/map/PnR/STA. Its dynamic boundary has no diagnostic IO insertion; raw internal reports must be reviewed. No whole-design PnR is running. Combined-source Verilator model at `verilator_20261019_215712_138161` is checking full-frame control, snapshot and actual display RTL with one C++ build job. Both this model and the separate full-frame Icarus snapshot simulation remain pending.

Quota monitor tests: 6 passed, including the shared 10% stop for regional and whole-design jobs. Its active watcher was restarted after the regional reserve change. Supplemental evidence in commit `0e9e4755751abfd25f70389c7ef991749a8ca469` was pushed and all 344 frozen supplementary file hashes match Git objects.

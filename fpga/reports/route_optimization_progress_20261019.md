# FPGA 布线专项优化进度

项目：`D:\XDU\concept\26-FPGA-Pango`  
远端：<https://github.com/CaiVegetable0932/26-FPGA-Pango>  
分支：`codex/fpga-pds-project`  
执行依据：`output/FPGA布线效率与拥塞专项优化方案.md`。本轮用户已授权实施、提交和推送；不涉及硬件下载。

## 2026-10-19 21:00（北京时间）

- 本轮起始 HEAD：`6fc951b3cb7a9d367b6d3c293a3e9efbb1f2c483`。
- 完整工作区初始状态已保存至 `fpga/build/route_optimization/session_20261019/initial_git_status.txt`：212 项已跟踪改动，展开未跟踪项后共 91,825 条。不能直接 `git add .`。
- 已读取安装版 PDS User Guide 中 Action Timeout 定义：单位为分钟，0 表示不限制。完整工程入口原先明确传入两个 0；本轮改为默认 60 分钟外部监督。
- 新监督器每 30 秒保留状态、原生日志和完成的布线轮次；完成前 5 轮后，最近 5 轮改进不足 1% 且最优未布通数仍超过 1000 时停止。超时、暂停、停滞均不计作布线成功，仅终止本轮拥有的进程树。
- 监督器 6 项独立测试通过：解析、收敛策略、成功/失败、超时回收、暂停、停滞停止。
- 核对既有 writer BRAM 快照：290 个输入文件哈希完整；完整工程 MAP、模型、回归及差分证据通过现有入口复核后，20:55 启动 seed 11 / decongestion 1 / Global / planning 的单个限时完整工程尝试。
- 构建：`fpga/build/full_integration_20261013/phys_20261019_205545_289460`。源 MAP：`delay_20261019_163458_368603`。当前为布局阶段，尚无 routed 或 STA 签核。
- MAP 资源：41,341 LUT、40,430 FF、117 APM、98 DRM；参考原 P12 为 41,616 / 40,440 / 117 / 86。资源变化不是已证实的布线效率改善。
- 已审查并推广快照相对主源码的 11 个 RTL 差异，包括 writer BRAM 与地址递推、DMA 预取、packer 固定字节通道、板级 token 容量、回填存储及控制修复。修改前字节、哈希和补丁归档于 `session_20261019/promotion/`。
- 主源码重新运行 12 项集成回归全部通过，结果：`fpga/build/full_integration_20261013/sim_20261019_205651_502065/result.json`。
- 已找到本会话账户额度事件，20:58 最新观察剩余 52%。后续以账户实际事件监控，剩余不高于 10% 时停止新增优化并交接；未用上下文 token 余额代替账户额度。
- 首次 GitHub fetch 连接被重置，推送尚未完成。

## 下一步

1. 完成当前限时尝试并保留布局、布线及 STA 真实结果；超时/停滞后按证据决定下一处结构修改。
2. 在单一重型 PDS 队列之外准备轻量差分与局部候选；不自动扫描大量 seed。
3. 分批提交本轮改动及运行所需依赖，保留无关历史改动；重试远端同步。
4. 后续每满一小时更新进度并汇报；停止时更新交接文档及所有活动构建状态。

## 2026-10-19 21:24（北京时间）

- 首批实现提交 `3540e9e8b7afc0c8e9fc5ba2fd6a1c0a3bdf6477` 已推送，已通过 `ls-remote` 核对。Git 的 Schannel 连接多次重置；单次命令使用 OpenSSL + HTTP/1.1 后恢复，不修改全局配置、不关闭证书验证。
- 原 10 月 10 日遗留空 `index.lock` 经核对没有提交进程持有后清理。无关的既有工作区改动仍未暂存。
- 当前完整工程布局完成，原生日志记录 placement 474.14 秒、预估 slack +64 ps。全局布线完成不代表详细布线完成；截至第 12 轮详细布线仍有 45,220/99,932 子网未布通，继续观察，不声称效率目标已实现。
- 新增两个独立局部候选，均从本轮 writer BRAM 的 290 文件基线生成，均未改主 RTL：

| 候选 | 功能证据 | 物理证据 |
| --- | --- | --- |
| `dma_grouped_20261019_210245_219923`：二客户端一组的二进制选择，保留局部低位选择寄存器；区别于已拒绝的 one-hot OR 树 | 10 项原有周期级差分通过；新增 12 组客户端数/校验开关参数检查通过，独立字节内存校验掩码和数据 | 待单位综合，预期增加约 6 FF，尚未实测 |
| `boot_local_capture_20261019_211117_597873`：在最后字节响应边沿提前产生 8 个分页写使能，数据仍在原 CHECK 边沿采样，保留全部复位 | 332,580 周期，903 位公开输出及 1536 位内部快照逐周期一致；53 回复、6 capture、3 次 reset | 待单位综合，预期增加约 8 FF，尚未实测 |

- 单位综合队列在 `session_20261019/unit_queue_plan.json`；仅在当前完整工程形成权威终态、机器无其他 PDS 且额度新鲜有效后顺序运行。每个单位上限 20 分钟；完成后必须审查，不自动推广或启动新完整布线。
- 监督器补充原生父进程退出而子进程遗留的检测/回收；测试增至 7 项。额度读取覆盖工具产生的多个会话分片和大日志，4 项测试通过。额度观察约剩余 51%。
- 复核用于云端交接的 1,442 个证据输入的 Git 暂存字节，SHA-256 全部匹配。为本轮两个 host 验证快照路径添加局部 `-text` 属性，避免 Git 换行转换破坏既有哈希；未新增忽略规则。
- 时钟口径：本轮现有整机 DDR/处理模型按 125 MHz 的真实约束比较，未放宽原约束。方案提出的初始 150 MHz 处理目标不能写成已达成；独立处理域提频仍需另行结构、CDC 和性能验证。


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


## 2026-10-19 22:22 functional and fixture checkpoint

Combined canonical RTL (writer baseline plus grouped DMA and boot local capture) passed the complete 20-case integration suite and the runtime-control scenario. Its full-frame Verilator control/snapshot/display model PASSED at `fpga/build/full_integration_20261013/verilator_20261019_215712_138161`: geometry jobs used 4,073,517 / 3,796,435 / 4,114,261 cycles; actual display fixture checked 22,809,600 pixels with zero failures and zero underflows. This is synthetic model evidence; no hardware was programmed. Account reserve policy is unchanged.

The host's frozen real decoder passed 8,888 snapshot packets (12,441,600 image bytes), report `host/reports/fpga_rgb_vectors_20261019_221953_362056.json`. Snapshot packet and descriptor SHA-256 both exactly match the previous writer-BRAM baseline. The Icarus full-frame supplement reached its 1,200-second cap and remains TIMEOUT; it has not been relabelled PASS. Future Icarus runs stream logs to disk even on timeout; the updated runner passed boot and DMA cases at `sim_20261019_220955_128002`.

Boot synthesis completed: baseline LUT 3726 / FF 3771 / DRM 3 / controlsets 39; candidate LUT 3709 / FF 3776 / DRM 3 / controlsets 47. In this isolated netlist, the old capture CE drives 1,545 registers; the new eight local capture CEs each drive 192. This proves preserved synthesis locality, not a physical win. Unit consumers differ from the whole-design load count recorded earlier.

The first DMA physical fixture failed mapping DRC because raw top ports lacked IO buffers. It never started DUT routing. The replacement uses identical scan-input/capture-output register boundaries and real IOs; its baseline passed DRC and is routing. Fixture controllability, capture ordering, every output word and out-of-range reads passed an actual simulator test. Both A/B sides use the same wrapper hash and 8ns clock. Wrapper resource/timing costs must not be counted as production module changes. `probe_regional_route.py` now restricts its tops to DMA, boot and the reviewed unpack module and never generates a bitstream.

Review round 2: `fpga/build/route_optimization/unpack_local_capture_20261019_221324_680300` changes only the aligned unpack capture control, retaining all payload resets and original edge timing. Its strict differential proof `differential_20261019_221418_033659` passed 300,000 comparisons over both parameter branches and three seeds, including long stalls, simultaneous consume/refill, partial tails and mid-stream resets. It is NOT PROMOTED; synthesis and physical screening remain pending. The main integrated source still contains the preceding 13-file set.

Common whole-design routes and direct timed-database bitgen now enforce the readiness gate. No whole-design PnR or bitstream generation is allowed while design completion is false. The plan remains incomplete; regional validation continues.

## 2026-10-19 23:48 hourly checkpoint

Canonical design is restored to the 11-file writer baseline. Both first-round additions were withheld and rolled back. Fresh 20-case regression `sim_20261019_224436_927540` passed; all 72 inputs of the previously passing baseline full-frame model match current source bytes. Whole-design routing remains stopped; no bitstream generation or programming has occurred. Account quota observation at 23:48: 42% remaining; shared 10% stop remains active.

Earlier auto-pin boot/DMA physical comparisons had different actual package pins and are preliminary. Subsequent experiments freeze identical diagnostic pins, wrapper, 8 ns clock and native settings and verify the final pin mapping. This is isolated internal timing evidence, not board signoff.

Round-2 unpack candidate passed strict differential simulation but is not promoted. Standalone PnR 35→34 seconds is too small to establish a useful improvement. Real RGB reader context `unit_screen_20261019_233122_395009/regional_route_20261019_234111_668461` completed both sides with internal constraints met and fixed pins verified; placement wirelength increased 10,613→11,032. Keep the canonical unpack design.

Round-2 local wait-statistics candidate reduced synthesis LUTs by 166 relative to grouped DMA, but fixed-pin detailed routing stalled after 1,050.547 seconds. Best unrouted count was 1,430, followed by five rounds without improvement. Reference completed routing but failed setup/hold. Neither is a qualifying successful implementation; do not claim acceleration or promote it. Evidence: `dma_local_wait_stats_20261019_222919_171043/owner_unit_probe_20261019_224815_958515/regional_route_20261019_230100_405717`.

Round 3 targets the measured shared beat-index hotspot, using two candidates based on canonical DMA rather than the withheld grouped structure: `dma_local_cursor_20261019_234450_385383` and `dma_cursor_stats_20261019_234450_843063`. A mirrors the exact post-edge cursor into client-local scalar registers; RAM type, latency and reset semantics remain unchanged. B adds local wait-statistics comparisons relative to A. Both passed 10 transport/readback differential scenarios and 12 parameter tests. A synthesis is in progress; neither is promoted. No unattended seed sweep is authorized.

Latest checkpoint commit `0b45b46ae6c3f5d5cb3e3d3ac7f83e8137e049a1` was verified on the remote branch. Progress/handoff and later regional evidence will be committed in the next checkpoint. Clock scope remains pending user clarification: actual 125 MHz equal-constraint optimization versus adding the planned 150 MHz domain/CDC architecture. No clock or PHY change is assumed.

23:59 timing review: the real reader-context native log gives PnR 44→36 seconds (about 18% reduction), with clean internal STA on both sides. The increased placement wirelength alone does not override this primary metric. This is below the 30% goal and one sample cannot establish a stable gain; the candidate remains unpromoted pending the plan's finite seed 7 and 13 checks with identical constraints/pins. No seed sweep is permitted. Checkpoint `cd78b6a2` containing 833 byte-verified evidence files and updated reports was pushed successfully.

## 2026-10-20 00:15 finite-seed and integration checkpoint

Unpack real-reader seed 11/7/13 results all completed and met internal timing on both sides. Baseline PnR seconds: 44/45/44; candidate: 36/38/39. Median 44→38 (13.64% reduction), maximum 45→39. The suggested 30% target is NOT met; this is a modest isolated improvement, not whole-design acceleration. Source/resource increments are LUT +10, FF +12 and controlsets +4 in the real-reader context. Decision is a clean integration finalist, pending complete functional verification rather than immediate promotion. Evidence: `unpack_local_capture_20261019_221324_680300/unit_screen_20261019_233122_395009/three_seed_summary.json`.

Clean finalist snapshot `session_20261019/unpack_finalist/source` contains 290 canonical files and changes exactly one file, `rtl/memory/dma_byte_unpack.v`. It excludes the rolled-back DMA/boot candidates. Its 20-case integration regression passed at `sim_20261020_001153_047628`. Full-frame control/snapshot/actual-display model is running at `verilator_20261020_001232_095496`, one C++ build job. Main RTL remains the 11-file baseline until final proof and source binding are reviewed.

Round-3 DMA cursor A synthesis passed: LUT 3950→4004, FF 1508→1535, DRM 28 and controlsets 51 unchanged. Netlist confirms all 35 local cursor FFs survive; central cursor low-four-bit primitive input loads decrease 56–59→4–7, and local loads are at most 21. This establishes synthesis locality only. Both A and B passed supplementary same-cycle cursor invariants in ten transport/readback scenarios each. A physical and B synthesis remain pending.

Existing writer BRAM isolated synthesis at `writer_bram_screen_20261020_001142_389407/unit_screen` passed: LUT 1466→1323, FF 599→595, DRM 0→4, controlsets 13 unchanged. Generic raster writer physical comparison is running with identical 70-pin boundaries and 8 ns constraints. Dynamic generic parameters exceed some fixed production contexts; no board timing claim is made. One native PDS only; a separate single-job functional model is active, recorded in `host_context.json`.

Supervisor now prevents process creation when a stop marker already exists; it also stops owned jobs if a marker appears during execution. Ten supervisor tests passed, including both cases. Checkpoint `482ac2f71ab01b708a3e52680b5c31fa8e6f72f3` was pushed. Whole-design completion/route gates remain false; no bitstream or hardware programming.

00:26 writer review: the generic dynamic-input pair routed but failed STA (slow setup −6.948/−7.796 ns). Worst path traverses dynamic `span_end` arithmetic. A second pair specializes only the existing production ISP input constants (1920×1080, stride 6144, RGB888); it does not certify dynamic geometry. Both fixed-context sides routed and passed STA: PnR 49→48 seconds, placement wirelength 16,853→18,376, slow setup 2.964→3.090 ns, hold 0.138→0.153 ns. This confirms the mapped BRAM change remains valid in the ISP context but shows no significant isolated runtime benefit. Do not claim a whole-design improvement from it. The first fixed-context generated fixture had invalid literal bit-selection syntax; it failed before synthesis, was retained, and was corrected to named localparams. Both corrected inputs passed independent Icarus compilation before native retry. Production RTL was unchanged.

DMA round-3 B synthesis is now running at `dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874`; A physical comparison remains pending. Full-frame unpack finalist model is still running and has started producing snapshot bytes; no final PASS claim yet. A further 660 terminal evidence files (about 30 MB) are frozen with archive member verification at `session_20261019/regional_checkpoint_20261020_0026_manifest.json`; the active model and active DMA synthesis are excluded.

## 2026-10-20 00:35 single-file unpack promotion

Clean finalist full-frame model PASSED: all three geometry cycle counts exactly match baseline (4,073,517 / 3,796,435 / 4,114,261). Actual display checked 22,809,600 pixels, 3 new frames and 8 repeats, zero failures and underflows. Host frozen decoder PASS at `host/reports/fpga_rgb_vectors_20261020_003432_815058.json`: 8,888 packets and 12,441,600 image bytes. Snapshot datagrams (13,028,208 bytes) and descriptors (288 bytes) match baseline SHA-256 exactly.

Only `rtl/memory/dma_byte_unpack.v` was promoted. All 290 main source hashes match the verified finalist; every model and regression source was checked before promotion. Original bytes are backed up at `session_20261019/unpack_promotion_20261020/before_dma_byte_unpack.v`; promotion record binds the source, functional proofs and three-seed decision. Main design now has 12 selected changes. Earlier pending selection metadata remains immutable in its historical checkpoint; accepted status is a separate `selection_promoted_20261020.json`.

The user was notified that this main version's complete functional verification passed. Overall design optimization is still incomplete: DMA round-3 B synthesis is active and regional DMA physical validation remains pending. All whole-design readiness gates remain closed; no full routing, bitstream or hardware programming. Latest preceding checkpoint `29265c6f963bc035333bbb77835e43af419f1ac9` was verified on the remote.

## 2026-10-20 00:48 hourly report

User notified: current 12-change main design passed the 20-case regression, complete 1080p control/snapshot/actual-display model and host/raw-byte checks. Single-file unpack promotion and full proof were pushed as `20f5269f66d33b647cdd64dd10a720bb19e76cfe`; current handoff, DMA B synthesis and static control review were pushed as `045c28040dc7254a52b572e204b9e9480ae81f3a`. Current handoff is `fpga/reports/route_optimization_handoff_20261020.md`.

DMA B synthesis passed: versus A, LUT 4004→3599, FF 1535 and DRM 28 unchanged, controlsets 51→57, slow estimated slack 0.203→0.427 ns. This is not routed timing and B is not promoted. A fixed-pin physical comparison is active at `dma_local_cursor_20261019_234450_385383/owner_unit_probe_20261019_235108_893996/regional_route_20261020_003911_499310`. Baseline observation 00:47:41: route round 12, best remaining 7,791, 510.297 seconds total, still RUNNING/converging. Candidate side has not run yet.

Account reserve was 40% remaining at the latest observation. Whole-design stop/readiness gates remain closed and no bitstream/hardware action occurred. Next hourly report approximately 01:48. Static pool/snapshot-control proposals are documented but no fourth-round candidate was launched. All 186 frozen DDR controller inputs and the six selected production constraints match the original validated baseline.

00:56 entry-point audit: canonical `portable_video_build.py` now applies the same completion gate to full/route-map/route-placement before package verification, directory creation or native launch. All three real CLI rejection checks passed with no output directory created, recorded in `portable_gate_check_20261020.json`. Future package generation includes the gate record and helper dependencies. Historical portable packages were not modified or executed; they are not current implementation entry points. This does not claim a portable full-flow budget migration; any eventual full implementation must use the current supervised/readiness-gated flow.

## 2026-10-20 01:14 DMA timeout and phase-budget diagnosis

Round-3 raw reference hit the frozen 1,200-second full-flow cap: TIMEOUT, last completed route round 402 remaining 105, best 94, no complete routed DB/STA, actual final pins unverified. No acceleration claim is allowed. Its native processes exited and the slot was verified clean. A candidate-only trial then began at `regional_route_20261020_005929_844858`; this is not a completed A/B pair and retains its own frozen 20-minute total cap.

Native action logs show reference compile took 5m35s; SYN/MAP cumulative 6m22s. The timed-out trial therefore provided only about 13m38s for PnR, not the original plan's full 20-minute PnR allowance. This is a concrete front-end cost diagnosis, not grounds to relabel or silently extend an active experiment.

Added explicit optional phase budgeting for future trials: prepare <=20 minutes, PnR <=20 minutes (or the original successful-baseline formula), STA <=120 seconds, <=42-minute total per side. Same exact RTL, pins, clocks, seed and effort; explicit mapped/routed DB dependencies are hash-checked. Three helper tests and ten supervision tests passed. A real small-module check is still required after the current native slot becomes free. Existing combined-flow mode remains unchanged by default, and old results remain immutable.

01:26 update: A candidate-only trial also TIMEOUT under its frozen full-flow budget, last round 53 remaining 3600, best 3563. It is not promoted. Verified source/checkpoints preserved; no exact in-memory route continuation is claimed. Front-end costs were the same 6m22s in the two initial trials. Two failed/timeout records and native MAP/PLC/congestion evidence are frozen separately from active work.

New separate-phase driver passed real validation on a previously proven raw-reader baseline (`regional_route_20261020_012009_332864`): prepare/PnR/STA all completed, internal STA and actual fixed pins passed, mapped/PCF/routed checkpoint hashes intact. It is explicitly a driver smoke, excluded from three-seed optimization statistics. B candidate-only physical test then started at `regional_route_20261020_012352_959075`, with the published 20/20/2-minute phase budget, unchanged RTL/clock/seed/effort and no acceleration claim against old-budget failures. The phase plan binds source and pin hashes at `regional_phase_budget_plan_20261020.json`.

Added 17 tiny PCF dependencies as a supplemental native-checkpoint closure without rewriting historical ZIPs. Older auto-pin cases had no PCF output; fixed-pin cases retain their exact generated PCFs and mapped-DB hashes. Frozen terminal proof scope `regional_checkpoint_20261020_0123_manifest.json` contains 98 files, about 29 MB, including timeout evidence and validated driver. Main 12-source selection and its complete functional proof remain unchanged.

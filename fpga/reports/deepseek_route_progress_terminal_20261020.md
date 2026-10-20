# DeepSeek + Claude Code 布线轮次终结报告（seed 11，首轮 60 分钟预算）

更新：2026-10-20 14:20（亚洲/上海）。任务来源 `fpga/reports/deepseek_claude_code_routing_handoff_20261020.md`，执行者为本会话。

## 结论

**本轮未布通、未到达 STA、未生成位流，结果按原状态保留为 TIMEOUT，不改为通过。** 60 分钟硬上限（13:55:18 本地）触发时，详细布线完成 13 个迭代（iter 0–12），仍有 **45,542** 条网线未布通（总布线网线 88,195）。监督器终止自有 PID 树，driver 退出，无孤儿进程，`native_phase.lock` 已释放。

## 启动与参数（已核验）

| 项 | 值 |
| --- | --- |
| 会话目录 | `fpga/build/route_optimization/deepseek_route_20261020_125517_1325705` |
| 复用工程 | `fpga/build/full_integration_20261013/handoff_20261020_053147_229875` |
| driver | python PID 21800，启动 12:55:17（UTC 04:55:17） |
| PDS 监督/工作进程 | 47048（12:55:18）→ 26832（12:55:26），全程唯一 |
| 参数 | `--stop-after-timing --placement-seed 11 --placement-decongestion 1 --phase-timeout-minutes 60 --pnr-timeout-minutes 60 --dump-congestion` |
| 就绪门槛 | 启动时仅翻转 `whole_design_route_allowed=true`；前三项 design/simulation/resource 保持 true 未动 |
| 停止文件 | 会话内 `stop_requested.json` 全程未创建（TIMEOUT 而非 PAUSED） |

预检（交接第 5 节）全部通过：308 项选定源码与工作区逐项 SHA 一致；handoff 工程 308 项源一致；MAP `pango_video_system_map.adf` SHA256 `6f71a296eced5942389318ef043689795626f16854cf868983e6c0e31da88474`、PCF SHA256 `6076ff6f14da06bcd4b01755dad9e909e7355e183d2ca5e4f583019965bc1428`；`handoff_preparation.json` `prepared=true`、`native_inputs_identical=true`。启动时无其他 PDS/Python 进程、无遗留 `native_phase.lock`。

## 运行时间线与关键指标

- 12:55:18 PnR 启动；~13:08 布局完成（`pango_video_system_plc.adf` 10,693,467 字节，设计利用率 62%）。
- ~13:10 进入布线：构建布线图 11.00s，总网线 88,195。
- 13:43 起超过 48 分钟预警线（warning=true）。
- 13:55:18 elapsed 3600.0s 触发 TIMEOUT，监督器按身份核验终止自有进程树。

| 迭代 | 未布通 | CPU 秒 | 迭代 | 未布通 | CPU 秒 |
| --- | --- | --- | --- | --- | --- |
| 0 | 78,408 | 29.8 | 7 | 55,385 | 224.2 |
| 1 | 74,100 | 29.3 | 8 | 52,419 | 265.7 |
| 2 | 69,754 | 31.6 | 9 | 50,403 | 291.6 |
| 3 | 66,193 | 39.5 | 10 | 48,623 | 321.1 |
| 4 | 62,958 | 74.8 | 11 | 46,756 | 351.6 |
| 5 | 60,404 | 149.1 | 12 | 45,542 | 387.1 |
| 6 | 58,148 | 172.2 | | | |

趋势：单迭代 CPU 时间近似线性增长（29.8s → 387.1s，约 +30s/迭代），每轮减少的未布通数从 4,308 衰减到 1,214（5.5% → 2.6%）。按该趋势收敛需要数百个迭代，远超 60 分钟预算（本轮只完成 13 个）。停滞规则未触发（最终 5 轮窗口最优改善 17.8%，高于 1% 阈值且剩余 >1000）。旧整板基线约 50 分 31 秒剩 37,200 未布通，与本轮同数量级；两轮设计版本不同（本轮含 150MHz tile 边界域），不能直接比较。

## 拥塞证据（`CongestionNetInfo_0..12`，下一轮分析入口）

iter 12 拥塞值最高的网线集中在：几何 `geometry/u_result`（64）、`tone_cursor`（64/61/55）、`geo_src_slot` 总线（62/59/46）、帧池 `frames/banks[*].pool` 宽总线（62/58/52/49）、DDR PHY `ddrphy_rst_n`（74）、DMA `N1370_2`（52）、快照复制（49）、writer pack（47）、`processing_reset_n_2`（47）。热点 tile 如 CLMA_285_318、CLMS_309_355、CLMA_165_331。特征与 150MHz tile 边界域的宽总线分布一致。13 份逐迭代导出与 CongestionPlot 已归档（见下）。

## 终结证据与产物 SHA

- 证据目录 `resume_20261020_125518_926278`：`place_route.log`（116,765B）、`place_route_monitor.jsonl`（186,341B，全程 30 秒一行）、`place_route_monitor.policy.json`（冻结预算：timeout 3600s / warning 2880s）、`place_route.tcl`、`result.json`、脚本副本。
- 原生产物归档 `native_place_route_timeout.zip`（17,893,762 字节，31 成员，ZIP_DEFLATED），逐成员 SHA manifest `native_place_route_timeout_manifest.json`；**archive_sha256 `d234237da49418a6b77a1473a46b8545fc2e686c93191c2fad97f6f1dc5652a5`**。成员含 placement DB、13×CongestionNetInfo、13×CongestionPlot、`clock_utilization.txt`、`run.log`、空 `layers.txt`/`prr`。已回读校验通过。
- `result.json`（handoff 根与证据目录各一份）：`stage=place_route`、`optimization_status=TIMEOUT`、`native_exit=1`、`internal_timing_met=false`、`snapshot_intact=true`、`stop_after_timing=true`、`full_function_release=false`、`hardware_tested=false`、`programmed=false`。driver stderr 保留 RuntimeError 回溯，未改标任何状态。
- 输入未变：driver 终结前再次核验 308 项源 SHA（`snapshot_intact=true`）；冻结 MAP/PCF 未改动。
- 观察记录：会话内 `observations.jsonl` 共 13 行（每轮检查含阶段/状态/elapsed/轮次/最少未布通/CPU/内存/预算/下一步）。

## 未签核项（如实列出）

routed setup/hold 与 min/max STA、CDC 物理延迟、外部 DDR/HDMI/RGMII/相机时序、HDMI 硬件帧源身份（保持 unverified）、硬件测试、位流与下载——全部未完成。无任何内部时序通过结论；设计/仿真通过结论不升级为板卡运行结论。

## 授权与 Git

- 就绪记录已按交接第 9.2 节复位：`whole_design_route_allowed=false`，reason 记录本轮 TIMEOUT 与后续需重新分派；其他状态与字段保留。会话内留 `readiness_before.json`（启动前）与 `readiness_during_run.json`（运行期）两份副本。
- 本轮新增/修改文件精确暂存后提交：两个脚本、终结/下一轮报告、会话目录、证据目录、归档 ZIP+manifest、handoff 工程内 PDS 生成的小型文件（flow.log/impl.tcl/place_route.pds/logbackup/run.log/result.json）。raw placement DB 与 CongestionNetInfo 不直接入库（按设计阶段约定走 ZIP 归档）；handoff 内 `device_map/*` 大型 DB 仍保持设计阶段的未跟踪状态，云端恢复沿用 `restore_native_artifacts.json`。
- 提交与推送核验见下一轮交接文件。

## 下一轮候选（有限、单变量；需用户分派，本会话不自动执行）

1. **只读拥塞分析**（不启动 PDS）：结合 13 份 CongestionNetInfo/Plot 定位热点网线与 tile，形成候选结构改动清单。
2. **固定 seed 小样本复现**：seed 7 或 13，同样约束与 60 分钟预算，独立证据目录，单变量。
3. **结构候选**（每轮至多两个）：如几何 u_result/tone_cursor 区域分散、帧池 bank 扇出、geo_src_slot 总线布局；必须先过仿真与重新 MAP（设计阶段流程），不得直接复用旧 DB。
4. 不允许：同 seed 自动重启、无限续时、扫 seed、未说明理由地叠加 effort/planning 旋钮。

# 无时限布线续跑交接（seed 13，2026-10-20 19:32）

接续者先读：根目录 `AGENTS.md` → 原始任务 `fpga/reports/deepseek_claude_code_routing_handoff_20261020.md` → 本轮状况报告 `fpga/reports/deepseek_route_status_report_seed13_20261020.md` → 本文件。

## 1. 当前状态（按启动时间与日志互相确认）

- 项目 `D:\XDU\concept\26-FPGA-Pango`，分支 `codex/fpga-pds-project`。
- 设计冻结提交 `a4bc5aae`；冻结工程 `fpga/build/full_integration_20261013/handoff_20261020_053147_229875`（308 项源 + MAP/PCF，预检 SHA 一致）。
- **seed 13 限时轮已终结**：90 分钟 `TIMEOUT`，未布通 34,802（iter 20）。会话 `deepseek_route_20261020_175732_8933723`，证据 `resume_20261020_175734_931652`，原生产物 ZIP（47 成员，SHA `9fb0c0ed…`）已回读校验。
- **seed 13 优于 seed 11（41,449）16%**，用户指示取消时间限制继续推进，目标完整可烧录位流。
- 终结时核验：driver 退出、`pds_shell` 0、`native_phase.lock` 释放，无孤儿进程。恢复会话时仍须复核进程与锁，不按进程名批量杀。

## 2. 无时限轮启动（命令已固化为脚本）

`fpga/scripts/launch_deepseek_route_unlimited.ps1`：

- seed 13、decongestion 1，`--pnr-timeout-minutes 0`（官方语义：无原生动作限时）；
- `--phase-timeout-minutes 1440`（host 监督上限，工具强制必须为有限值；1440 分钟为其允许的最大值）；
- `--dump-congestion`、`--pause-file <session>/stop_requested.json`；未加 `--stop-after-timing`，STA 通过后自动 bitgen；
- 启动前仅翻转 `whole_design_route_allowed=true` 并写 reason；其余就绪状态不动。

启动前必须：① 确认无 PDS/python 进程与 `native_phase.lock`；② 重跑源/MAP/PCF SHA 预检；③ 清空 `place_route/`（内容已在本轮 ZIP 归档；不清理会重现 seed 7 的 Place-0006 类干扰）。

## 3. 语义与边界（重要）

- **布线确定性**：固定 seed 的 PnR 会重放已完成迭代后继续下降；因此无时限轮会先复现 0–20 迭代，再进入新区域。前 ~90 分钟的未布通曲线应与限时轮逐位重合，可用作运行正确性的自检。
- **"取消时间限制"的落地**：原生 `-action_timeout` 为 0（无限制）；host 监督仍保留 24 小时上限（工具安全结构要求有限值）。连续 24 小时是单次运行的硬边界；若届时未收敛，需另起一段（重放成本约等于已用时间）。停滞规则（5 轮窗口改善 <1% 且剩余 >1000）仍会终止。
- bitgen 只在 routed min/max STA 报告 `All Constraints Met` 后运行；不下载、不烧录板卡（仍未经授权）。
- 单机只允许一个 PDS 执行者；出现第二个 driver 会被 resume 脚本的"工程运行中"防护拒绝（已有先例，见 `deepseek_route_20261020_144655_6830244`）。

## 4. 监控与汇报（用户要求）

- 每约 10 分钟汇报：**必须含未布通子网数**；阶段、elapsed、迭代耗时、拥塞最大值同步给出。
- 速度明显变慢（单迭代 CPU 环比 ≥1.4×）或拥塞骤升（最新 CongestionNetInfo 最大拥塞值明显上升）时立即报告并给出日志位置：
  - `resume_*/place_route.log`、`resume_*/place_route_monitor.jsonl`
  - `place_route/CongestionNetInfo/CongestionNetInfo_N.txt`、`CongestionPlot_N.txt`
  - `session/driver_stdout.log`、`driver_stderr.log`
- 观察持久化：`python fpga/scripts/observe_route_session.py --session <session> --build <handoff>` 追加 `observations.jsonl`。

## 5. 停止与恢复

- 停止：写 `<session>/stop_requested.json`（格式见原始交接第 7 节），监督器下一次轮询（30s）终止自有 PID 树。PAUSED 不保证从最后一轮无损恢复。
- 崩溃/断连恢复：先读 `launch.json` → driver PID/创建时间 → 最新 `resume_*/place_route_monitor.jsonl` → `result.json`（若已产生）；**禁止重复启动**。
- 终结后：归档 `place_route/` 为带逐成员 SHA 的 ZIP；复位 `whole_design_route_allowed=false`；精确暂存本轮文件提交推送。

## 6. 结局判定标准（不变）

只有本轮原生 PnR 结束、STA 成功、输入 SHA 未变、`native_exit=0`、无工具错误，且新 `.rtr` 的 Design Summary 为 All Constraints Met 并复核 slow/fast setup/hold、recovery/removal 与约束覆盖，才记录"本轮内部物理时序通过"；位流生成后也仍需硬件验证。外部 IO/CDC/硬件保持未签核。

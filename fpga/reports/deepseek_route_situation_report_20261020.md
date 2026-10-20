# 布线当前情况报告与 1.5 小时超时重启（2026-10-20 14:36）

用户指令（本日 14:19–14:31）：总目标生成完整可烧录位流；单次布线超时改为 **1.5 小时**；不随意更换 seed，先出具报告说明当前情况，继续按当前方案布线，除非能证明当前方案无法布通；每 10 分钟汇报未布通子网数量。

## 当前情况

### 第 1 轮（seed 11，60 分钟预算）

- 12:55:18 启动 → 13:55:18 硬上限 TIMEOUT：13 个详细布线迭代，未布通 **45,542 / 88,195**。
- 结果按 TIMEOUT 原样保留；placement DB 与 13 份 CongestionNetInfo/Plot 已归档（`native_place_route_timeout.zip`，31 成员逐项 SHA，archive_sha256 `d234237d…5652a5`）。
- 已提交 `a177255f0` 并推送远端。

### 第 2 轮（seed 7，60 分钟预算）——已失败并已分析

- 14:21:54 启动，**150.2 秒后 FAILED**：`E: Place-0006: The I_ips_ddr_top/u_ddrphy_top/ddrphy_slice_top/i_ca_group[0].u_tserdes_ca0/oserdes_inst cannot be placed.`（Phase 2.2 Process placement，DDR PHY CA 组 OSERDES）。
- 状态按 FAILED 保留：`resume_20261020_142155_652622`（result.json、place_route.log、monitor、driver 回溯）。
- **原因判断**：第 1 轮从干净目录成功放置了同一 PHY 并运行 60 分钟，MAP 与冻结约束本身无问题；两轮唯一环境差异是第 2 轮启动时 `place_route/` 残留第 1 轮原生产物（seed-11 的 `pango_video_system_plc.adf` 与失败轮的 `prr.db`/`.prr`）。判定为启动环境问题，**不构成"当前方案无法布通"的证明**，故按用户指示继续 seed 7。

## 处置与重启

1. 残留隔离：`plc.adf`（seed 11 布局库，与 seed 7 不匹配，不可用于 `--from-placement`）、`prr.db`、`pango_video_system.prr` 移入 `handoff…/place_route_stale_quarantine_20261020/`（含 README 说明；原始字节在第 1 轮 ZIP 中另有归档）。
2. 预检复验通过：308+308 项源 SHA 一致；MAP `6f71a296…`、PCF `6076ff6f…` 未变；`prepared=true`。
3. 以干净目录重启 **seed 7**，预算 **90/90 分钟**（PnR native 与 host 监督一致），位流目标不变（bitgen 仅在 routed min/max STA 通过后运行）。
4. 启动过程一次瞬时文件锁（就绪记录被占用）导致首次尝试失败——重试成功，未产生任务；未完成会话目录已清理。

## 当前运行

| 项 | 值 |
| --- | --- |
| 会话 | `fpga/build/route_optimization/deepseek_route_20261020_143303_1632613` |
| 证据 | `handoff…/resume_20261020_143304_667663` |
| driver / PDS | 53592（14:33:03）→ 24372 → 37364（唯一任务树） |
| 参数 | seed 7、decongestion 1、PnR/STA 各 90 分钟、dump-congestion、bitgen-after-STA |
| 就绪门槛 | `whole_design_route_allowed=true`，reason 记录 seed 7 续跑与 1.5h 超时 |

## 监控与汇报承诺

- 每约 10 分钟汇报：阶段、已用时间、未布通子网数、最近迭代耗时。
- 速度明显变慢（单迭代 CPU 环比 ≥1.4×）或拥塞明显（最新 CongestionNetInfo 最大拥塞值骤升）时立即报告并给出日志路径：
  - 阶段日志 `resume_*/place_route.log`；监控流 `resume_*/place_route_monitor.jsonl`
  - 逐迭代拥塞导出 `place_route/CongestionNetInfo/CongestionNetInfo_N.txt` 与 `CongestionPlot_N.txt`
  - driver 输出 `session/driver_stdout.log`、`driver_stderr.log`
- 若 clean 目录下 seed 7 再次在同一位置（Phase 2.2 OSERDES）失败 → seed 相关问题，出具证据后评估；若 90 分钟 TIMEOUT → 保存分析并汇报，不自动扫 seed。只有能证明当前方案无法布通时才更换方案。

---

# 追加：seed 7 证明与第 3 轮终结（2026-10-20 16:20）

## seed 7 证明（2/2 确定性失败）

clean 目录重试（2b，`resume_20261020_143304_667663`）与首次（2，`resume_20261020_142155_652622`）**完全相同**：150 秒处 `Place-0006: I_ips_ddr_top/…/i_ca_group[0].u_tserdes_ca0/oserdes_inst cannot be placed`。变量唯一（seed 11→7），故 seed 7 在本设计上确定性失败于布局，与残留产物无关。残留产物已全部隔离于 `place_route_stale_quarantine_20261020/`（含 README）。

## 第 3 轮（seed 11，90 分钟）终结

- 14:46:10 启动 → 16:16:10 硬上限 TIMEOUT（5400.0s），17 个详细布线迭代（0–16），**未布通 41,449 / 88,195**。迭代 16 耗时 516.8s。
- 与第 1 轮（60 分钟）逐位重合至迭代 12（45,542），此后为新区域：44,291→43,230→42,332→41,449，每轮改善 2.7%→2.4%→2.1%→2.1%，单迭代 427s→517s。
- 停滞规则未触发（窗口改善 2.1% > 1% 阈值），由硬上限终结；`snapshot_intact=true`、无孤儿进程、锁已释放。
- STA 与位流未到达（bitgen 门槛正确拦截）；结果按 TIMEOUT 保留。
- 证据：`resume_20261020_144611_450798`（place_route.log、monitor、result.json）；原生产物归档 `native_place_route_timeout_90min.zip`（19,918,530 字节，39 成员，archive_sha256 `f35c69be5b6702a9f81fddd4df2a5ff07c19afc48cac569c5677a98ea045c04e`，已回读校验）。
- 会话：`deepseek_route_20261020_144608_3387834`（launch.json、observations.jsonl 10 行、driver 日志）。
- 就绪门槛已复位 `whole_design_route_allowed=false`，reason 记录本轮结果，等待用户指定下一轮。

## 三颗 seed 的确定性证据汇总

| seed | 结果 | 性质 |
| --- | --- | --- |
| 7 | 布局 150s 处 Place-0006 OSERDES 失败 | 2/2 确定性失败 |
| 11 | 60 分钟 45,542；90 分钟 41,449 | 两次运行逐位重合，确定性 |
| 13 | 未试 | 允许集合内最后一颗 |

seed 11 收敛曲线持续减速（改善率 2.1%/轮且下降、单迭代 517s 且上升）。按观测外推，布通到 0 需要数百迭代（数十小时量级）且改善率会先跌破 1% 停滞阈值——**仅靠延长同一 seed 预算难以收敛**。是否"证明无法布通"由用户判定；可选方向：seed 13 试验、pin-cost 单变量试验、拥塞驱动结构改动（RTL+仿真+重新 MAP）、或停止。

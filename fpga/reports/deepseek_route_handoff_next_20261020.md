# DeepSeek + Claude Code 布线下一轮交接（首轮 TIMEOUT 之后）

编写时间：2026-10-20 14:20（亚洲/上海）。接续对象为获得用户新分派的执行智能体。先读根目录 AGENTS.md、`fpga/reports/deepseek_claude_code_routing_handoff_20261020.md`（原始任务）与本轮终结报告 `fpga/reports/deepseek_route_progress_terminal_20261020.md`。

## 当前状态（按启动时间与日志互相确认，不按目录名猜）

- 项目：`D:\XDU\concept\26-FPGA-Pango`，分支 `codex/fpga-pds-project`。
- 本轮会话：`fpga/build/route_optimization/deepseek_route_20261020_125517_1325705`（`launch.json`：driver 21800，12:55:17；`observations.jsonl` 13 行；`driver_stdout/stderr.log`）。
- 本轮证据：`fpga/build/full_integration_20261013/handoff_20261020_053147_229875/resume_20261020_125518_926278`。
- 结果：seed 11 PnR 在 60 分钟硬上限 TIMEOUT，未布通 45,542 / 88,195；STA 未运行；无位流、无下载。状态原样保留，未改标。
- 进程与锁：driver 与全部 pds_shell 已退出（终结时核验 pds_shell 计数 0），`fpga/build/route_optimization/native_phase.lock` 已释放。**恢复对话时仍须先复核**：不要按 `pds_shell.exe`/python 进程名批量杀进程，只核验 PID 创建时间与父子关系；若发现残留，先确认归属再处理。
- 就绪记录：`fpga/config/implementation_readiness.json` 已复位 `whole_design_route_allowed=false`。下一轮只有获得用户分派、重跑第 5 节预检后，才可再次单独翻转该项；不要删除旧会话停止文件或 `session_complete.json`。

## 恢复原生大文件

raw placement DB（10.7MB）与 CongestionNetInfo（83MB）未直接入库，按设计阶段约定归档：

- 归档：`fpga/build/full_integration_20261013/handoff_20261020_053147_229875/resume_20261020_125518_926278/native_place_route_timeout.zip`（17,893,762 字节）。
- manifest：同目录 `native_place_route_timeout_manifest.json`，archive_sha256 `d234237da49418a6b77a1473a46b8545fc2e686c93191c2fad97f6f1dc5652a5`，31 个成员逐项 `{bytes, sha256}`。
- 恢复：先校验归档 SHA 与每个成员 SHA，再解压到 handoff 工程的 `place_route/` 下；已有不同内容的文件不得覆盖，拒绝越界路径。本地现有 `place_route/` 内容未删除，重新校验即可。
- handoff 工程 `device_map/*` 大型 DB（map.adf 等）保持未跟踪，云端克隆缺失时按原始交接第 5 节走 `native_mapping_0535.zip` + `restore_native_artifacts.json`。

## 下一轮可做与不可做（需用户分派后执行）

可做（单变量、独立证据目录、同样约束与预算）：

1. 只读拥塞分析（不启动 PDS）：13 份 `CongestionNetInfo_0..12`/`CongestionPlot_0..12` 定位热点网线（几何 u_result/tone_cursor、geo_src_slot、帧池 bank、DDR PHY 复位、快照复制、writer pack 等）与热点 tile。
2. 固定 seed 7 或 13 的小样本复现：同样 60 分钟预算与 `--stop-after-timing`，单变量。
3. 结构候选（每轮至多两个）：先仿真 + 重新 MAP（设计阶段流程），再开新物理轮次；RTL 变更不得复用旧 DB。

不可做：同 seed 自动重启、自动无限续时、扫 seed、无单变量理由叠加 effort/macro/planning 选项、把 TIMEOUT 改标通过、生成位流或板卡操作（仍未经授权）、改动冻结 `source/`、MAP、PCF 或时序约束。

## 交接必须写明

下一轮结束时同样要明确：是否布通、是否本轮内部 STA 通过（All Constraints Met + slow/fast setup/hold、recovery/removal 与约束覆盖复核）、哪些外部/CDC/硬件项未签核、是否仍有进程、是否已精确提交并推送远端。无位流与硬件结果就保持未完成。

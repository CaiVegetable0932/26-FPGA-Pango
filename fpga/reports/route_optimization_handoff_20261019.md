# FPGA 布线专项优化交接

状态：实施中，非最终验收。最后更新时间：2026-10-19 21:00（北京时间）。

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

GitHub 首次连接被重置，尚未完成本轮推送；后续必须写入实际提交号、推送结果和远端核对结果。

剩余验收：当前完整布线终态、setup/hold STA、外部/CDC 约束核对、有效候选的有限三 seed 稳定性、真实性能与效率比较。原基线从未合格完成时不计算加速比。没有实板测试、没有下载授权，不声称 1080p30 硬件已通过。

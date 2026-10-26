# 活动构建与仿真入口闭包审计（2026-10-21）

本审计针对 affine_lens 当前源码入口；未启动 PDS、未修改正在运行的 native 工程或任何既有冻结证据，未综合、布局布线、生成位流或上板。

## 修正清单

| 入口 | 审计结果与处理 |
| --- | --- |
| `scripts/build_full_integration.py` | 六个既有 unit 入口的依赖齐全；新增 `--closure-only`，仅冻结并校验文件路径、记录哈希，不启动原生工具。不会将文件齐全写成仿真或综合通过。 |
| `scripts/build_isp_geometry.ps1` | README 仍列为活动入口；源码表错误引用已退役 `perspective_divide.sv`，已删除该项，保持其余 affine/lens 算术依赖。四个当前注册边界 harness 可展开。 |
| `scripts/sim_isp_geometry.ps1` | 删除退役 divider 源文件和已移走的 `tb_perspective_divide`；保留 12 个默认单元/管线用例与两个 `-FullFrame` 用例，全部可展开。 |
| `scripts/probe_processing_domain_mapping.py` | 旧实验固定三用例证据、PROJECTIVE 参数替换与旧 adapter；现在执行前明确退出并指向当前 `build_video_system.py`。旧证据只能用其配套冻结脚本重现。 |
| `scripts/prepare_proc150_video_model.py` | 已有退役保护；更新退出信息，指向当前 `sim_video_verilator.py`。不再默认尝试套用旧 PROJECTIVE / 固定 290 输入基线。 |
| `scripts/build_video_system.py` / `scripts/sim_video_verilator.py` | 主入口已扫描 stabilization、image/control/memory/geometry，父代理负责本轮实际完整闭包验证。本次未改动。 |
| `scripts/sim_full_integration.py` | 已扫描新 stabilization/image/control 依赖并移除退役透视用例；本次未改动。Windows Icarus 对部分复杂结构体闭包的历史进程崩溃，不等价于 RTL 通过或失败；真实核心回归使用 Verilator。 |
| `scripts/probe_perspective_srl.py` / `scripts/synthesize_perspective_probe.py` | 已有入口即拒绝的退役保护；没有继续默认引用活动目录下已移走的透视 RTL。 |

## 实际验证

- Python AST：本次涉及的三个 Python 脚本均通过。
- PowerShell Parser：两个 PS 脚本均为 0 个语法错误；所列 RTL/fixture 路径全部存在。
- `build_full_integration.py --closure-only --units frame_memory_fabric geometry_tile_refill frame_pixel_writer dma_read_cdc geometry_frame_processor ov5640_integrated_startup`：冻结 30 个输入，`native_started=false`。
- Verilator 5.052 `--lint-only --timing -Wno-fatal --top-module ...`：6 个 unit + 4 个 timing harness + 12 个默认用例 + 2 个 FullFrame 用例，**24/24 展开退出码为 0，零 %Error**。警告保留在各日志中；这仅验证源码闭包、模块/端口及语法展开，不是执行用例、性能、STA 或硬件验证。
- 两个退役入口实际调用均以非零状态和明确的退役说明退出，未生成或启动 native 作业。

文件冻结证据：`build/full_integration_20261013/pds_20261021_182018_162469/closure_result.json`。
独立展开清单、逐顶层日志与输入哈希：`build/script_closure_audit_20261021_182106/result.json`、各子目录 `sources.json`。
本次五个脚本 SHA256：同目录 `scripts.json`。

## 版本与范围

`build_full_integration.py` 只综合它列出的六个旧 unit；不声称其 geometry_frame_processor 单元覆盖新 core 的双源 HISTORY、tone 管理或完整 motion。后者由 `sim_video_verilator.py --history-test/--motion-test` 及完整 core/system 路径验证。
旧实验、历史 README 记录与 frozen build 里的 PROJECTIVE 字样不自动变成当前可用入口；本次不改写历史产物。

PDS 操作边界核对依据：只读 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf` 的第 5.3 节（纸面 165–166 页）及 9.8 compile；同时查看 `reference/内容索引.md` 中 MINI 板卡/工具资料入口。没有修改工具命令、目标器件、封装、时钟或约束；现有 PG2L100H / FBG676 / -6 设置保持原值，不将其他示例当作本板结果。

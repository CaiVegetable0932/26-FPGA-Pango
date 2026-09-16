# FPGA 开发区

这里直接开发 PG2L100H FPGA 本体相关实现。当前已建立 PDS 原生工程和 IP 集成底座，尚非完整摄像头/视频系统；烧录前构建记录见 [工程构建报告](reports/pre_programming_build.md)。

当前架构为单路 OV5640 RAW8 DVP：一支写 S0 帧池并经板载千兆网发往 PC，另一支经基础 ISP、S1 帧池和硬件矫正生成 RGB888 结果，通过唯一 HDMI 输出。实现依据为[跨端回传方案](../output/OV5640_RAW8千兆网与HDMI双路回传方案.md)。

| 目录 | 内容 |
| --- | --- |
| `rtl/` | 视频输入、ISP、几何变换、S0/S1/结果帧池、MAC/IPv4/UDP、网络DMA、控制接口等 RTL |
| `ip/` | IP 配置、必要生成源码、依赖及来源说明 |
| `constraints/` | 管脚和时序约束 |
| `config/` | 器件、板卡、工具和源文件配置 |
| `project/` | PDS 工程及工程重建入口 |
| `sim/` | Testbench、仿真输入和预期结果 |
| `model/` | 浮点和位精确算法参考模型 |
| `scripts/` | 仿真、综合、布局布线、位流生成及下载脚本 |
| `build/` | 本开发区的构建结果和中间文件 |
| `reports/` | 仿真、资源、时序及 FPGA 实测报告 |
| `release/` | 阶段位流、配置、版本与校验记录 |

需求、设计和计划写在 [output](../output/README.md)，实现和生成结果写在本目录。云台、电机与光照设备端控制写在 [mcu](../mcu/README.md)，PC 上位机及测评软件写在 [host](../host/README.md)。在项目根目录打开 VS Code，PDS 引用本目录同一份源码。

旧开发方案中的 `rtl/`、`ip/`、`sim/`、`model/`、`constraints/`、`config/`、`build/` 等 FPGA 路径，现统一加 `fpga/` 前缀。本区脚本应根据自身位置解析路径，避免依赖终端当前目录。

所有子目录均受当前 Git 规则管理；`.gitkeep` 只用于保留空目录，可在添加实际文件后移除。

## PDS 工程入口

直接打开 [pango_video_top.pds](project/pango_video_top/pango_video_top.pds)。目标为 Logos2 / PG2L100H / FBG676 / -6，工具为 PDS 2022.2-SP6.4 build 146967。

在仓库根目录执行以下命令即可重建 IP、原生工程及烧录前流程（不调用下载器）：

```powershell
./fpga/scripts/build.ps1 -GenerateIps -LicenseFile '本机许可证的实际路径'
```

`-Stage compile` 只执行工程读取与编译；不加 `-GenerateIps` 时复用当前 IP 生成物。PDS 和 Python 路径可分别通过 `-PdsHome`、`-Python` 覆盖。许可证参数只影响子进程环境，脚本结束后恢复，不修改系统或用户设置；不要把许可证内容提交至 Git。

参数入口是 [ip_catalog.json](config/ip_catalog.json) 和 [board.json](config/board.json)。原生生成物归 `ip/`，工程归 `project/`，编译/综合/布局布线/时序/网表/位流/功耗报告归 `build/pango_video_top/`。不要直接改生成的 HDL 或手写 `.pds` 文件结构。

当前所有候选 IP 在 `rtl/memory/ip_integration_bank.v` 和板级顶层中实例化；集成观察逻辑不代表 ISP、帧池 DMA、网络协议或几何算法已经实现。DDR 地址请求保持空闲、网口 PHY 保持复位，HDMI 只包含原语及空白符号。2026-09-10 已完成原生重构建、复位/RGMII/TMDS 单元仿真和一次 SRAM 临时下载，但下载后出现 `over_temp=1`，回读校验已中止，**暂停再次上板或下载**。详细证据与未验证范围见[首次上板记录](reports/board_validation_20260910.md)。外部接口时序、DDR 实物参数、DQS 极性及 PHY 延时配置仍须单独签核；本工程没有完成完整功能或热稳定性验收。

## 本轮实现门槛

1. 先验证 RAW8 真实1080p30、DDR混合读写、RGMII与HDMI30，不以PHY链路灯、720p画面或旧200H位流认定通过。
2. 实现64字节应用头、最多1400字节载荷的网络V1及有界队列；CRC32图像报文与UART CRC16控制报文分别验证。
3. 帧池按主设计及跨端方案的76MiB布局，RAW DDR stride2048、网络stride1920；两个独立RGB快照槽用于S1/结果测评。
4. 暴露输入/处理/显示/网络完整帧、丢包、溢出及参数生效记录。普通HDMI采集不能自动获得源帧号。
5. 基础ISP与定点参考模型归model/；调试信号、无PC演示及功耗测量均保留真实证据。板级功耗不能命名为芯片核心功耗。

60FPS分支须采用真实60源，另行验证完整原图回传；不能把RAW8加协议超过千兆的链路列为已支持。

## 非烧录工具链入口（2026-09-07）

环境配置在 `config/toolchain.json`；可通过 `PDS_ROOT`、`MODELSIM_BIN` 覆盖工具路径。Python 需 3.10 或更高版本，流程本身只使用标准库。若当前终端尚未继承用户的 `PANGO_LICENSE_FILE`，入口只读取用户环境并注入当前子进程，不更改系统环境、不读取许可证正文。

在仓库根目录的 PowerShell 中执行；所有源码路径由脚本位置解析。下面路径参数指定新目录，不会覆盖旧构建。

```powershell
# 环境检查
./fpga/scripts/run.ps1 -Action doctor
# 编译当前安装版的 Logos2 Verilog 前后仿库
./fpga/scripts/run.ps1 -Action simlib -OutDir ./fpga/build/my_simlib
# RTL 自检
./fpga/scripts/run.ps1 -Action test -Stage rtl
# 完整构建（包括 setup/hold、综合网表、SDF、位流和功耗估算）
./fpga/scripts/run.ps1 -Action build -OutDir ./fpga/build/my_build
# 同一输入从另一个空目录复建
./fpga/scripts/run.ps1 -Action build -OutDir ./fpga/build/my_repeat
# 五类仿真；SDF 模型告警会使严格检查返回非零，这是当前已记录的限制
./fpga/scripts/run.ps1 -Action test -Stage all -OutDir ./fpga/build/my_tests -BuildDir ./fpga/build/my_build -SimlibDir ./fpga/build/my_simlib
# 汇总实际结果，生成 reports/latest.md 和 latest.json
./fpga/scripts/run.ps1 -Action report -BuildDir ./fpga/build/my_build -RepeatDir ./fpga/build/my_repeat -TestsDir ./fpga/build/my_tests -SimlibDir ./fpga/build/my_simlib
```

若 `python` 不在 PATH，给入口传 `-Python <python.exe的完整路径>`。等效 Python 入口是 `scripts/flow.py` 和 `scripts/report.py`。没有下载命令，生成的 `.sbit` 仅是工具链诊断产物，不能当作视频系统版本。

仿真对复位、连续计数、按键暂停/恢复和再次复位逐周期比较，超时、异常、缺失 PASS、SDF 回标失败或时序告警均保留为未通过。报告分别呈现功能比较与严格时序结果；PDS 返回 0 也必须同时通过日志与本次产物核验。

本次还运行了已有上位机软件测试，证据位于 `host/reports/pds-offline-20260907-host-tests.json`。后续汇总其它日期的跨端回归前，应更新对应证据输入，不把这份历史结果当作新的测试。

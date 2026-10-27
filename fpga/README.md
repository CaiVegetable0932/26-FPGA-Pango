# FPGA 开发区

## 2026-10-26 PC 动态控制精简版

当前板级启用 `PC_ONLY_CONTROL=1`、`SUMMARY_READBACK=1`：移除 MCU 自动姿态和运动诊断，保留 PC 图像/几何/参考/仿射动态控制。RAW8 千兆网、唯一 HDMI、DDR、基础 ISP 和矫正链路保留；没有缩减缓存或降低时钟。旧版不限时布线交接见 `reports/当前保存版本不限时布线交接_20261026.md`。新版本验证和资源结果以对应 build/reports 为准，源码完成不等于已布通。

> 2026-10-25 布线准备更新：43,633 LUT候选已完成新来源审查与预检，限定route许可开启，仅允许本文指定MAP的一轮90分钟PnR及成功后的STA，任务后自动关闭；bitgen=false，尚未启动PDS、未布通、未物理签核。使用[可执行布线交接](reports/LUT60可执行布线交接_20261025.md)的唯一入口；以下旧状态为历史记录。


> 2026-10-25 当前选择已更新：15个RTL文件采用本轮面积优化，显式SCF MAP为 **43,633/66,600（65.515015%）**，比旧L减少2,519 LUT；60%未达到，尚差3,673 LUT。完整1080p/显示、网络/上位机、MCU、CDC及独立oracle通过32项证据检查；综合DDR setup仍−1.555ns，新结构尚无PnR/物理时序/位流。route/bitgen均false。见[优化记录](reports/LUT60目标结构优化记录_20261025.md)与[新结构布线交接](reports/LUT60结构优化布线交接_20261025.md)。旧L/OFF及下列旧日期条目保留历史含义，不能作为当前来源。

> 2026-10-23当前候选：独立MCU V2 UART接入板级顶层，kind12提供会话、配置与时间证据批准；默认禁用。为满足严格LUT<70%，当前板级关闭自动曝光/AWB/自动tone、自定义LUT及独立C6固定裁边/缩放，保留手动图像控制、三条内置曲线、MCU/手动姿态、六参数仿射与镜头矫正。PC A0掩码0x1FCA、最大正文128字节。此条覆盖下列旧版功能描述；功能树、功能回归与实现细节见[本轮执行记录](reports/MCU板级接入执行记录_20261023.md)。本轮按最新要求停在布线之前，不生成或烧录新位流。

> 当前布线前交付：L `board_postsyn_20261023_221908_913042`，复用K冻结源码/SYN，显式加载SCF后完成MAP，46,152/66,600 LUT（69.2973%），14组同源功能验证通过。K原MAP漏载SCF的历史结果保留；L用于后续接续。本轮没有启动布局布线或位流，route/regional/bitgen均false。综合DDR setup估算仍−1.337ns，物理与[外部IO时序](reports/外部IO时序约束审查_20261023.md)尚未签核。详细证据及命令见[布线前验证与交接](reports/布线前验证与智能体交接_20261023.md)。

> 2026-10-22 修订：C4 视觉防抖已撤销。C3 MCU/手动姿态、A6、kind8 标定与 C6 固定裁边保留；视觉动态视窗和依赖视觉配准的 C5 补全不可用，历史缓存/DDR/清空释放框架保留。旧 C4 描述仅为历史设计，不作为当前能力或验收项。实施证据见 `fpga/reports/C4视觉防抖撤销执行记录_20261022.md`；未进行本轮实板验收。

2026-10-21 当前实现已切换为六参数仿射＋镜头映射，撤销视频快照及后置增强，接入统一实体、动态ISP/CCM、Gamma/LUT、受限运动与一帧历史补全、停流曝光控制。下列带日期的条目保留当时证据，不能作为本版验收。当前协议见 [ENTITY_CONTROL](config/integration/ENTITY_CONTROL.md)，本次验证及未完成条件见 [实施记录](reports/affine_implementation_20261021.md)。没有本版实板1080p30、LUT<70%或HDMI采集卡同源精度结论。

2026-10-13 完整视频集成正在实施：[pango_video_system.sv](rtl/board/pango_video_system.sv) 连接实际相机/原生 DDR/ISP/透视与镜头逆采样/HDMI/RAW 网络/同源快照/PC 参数控制。完整 1080p 合成帧与跨端字节验证通过，原生总体布线尚在收敛；本轮目前没有新的成功位流，也未烧录。构建入口 [build_video_system.py](scripts/build_video_system.py)，实际范围与结果见 [工作记录](reports/full_integration_20261013.md)，PC 接口见 [协议](config/integration/PC_RGB_CONTROL.md)。旧 pango_video_top/Top 候选保持旧范围。

2026-10-12 已完成主工程与单路720p诊断工程的总体布局布线和原生候选 `.sbit` 生成，交付文件及SHA-256见[位流生成记录](reports/bitstream_candidates_20261012.md)。候选放在 `release/candidates/20261012_220946/`，尚未获得硬件下载放行；两工程仍各自保持现有功能范围。

2026-10-12 时钟/复位/I/O 已新增共享原生 HDMI 启动控制、停钟失锁复位及 RGMII 各域复位门控，修正诊断像素时钟占空比并清理陈旧物理约束。两套顶层分别完成隔离 PnR/min-max 内部时序验证，共享工程已重生成并 Compile；外部 I/O、完整帧/DMA 恢复和实板验收仍未完成，加密 TMDS 仿真受许可证阻塞。详见[专项验证记录](reports/clock_reset_io_20261012.md)。

2026-10-11 MCU接入方向更新为 [MCU_POSE_V2](../output/MCU_POSE_V2云端同步实施计划.md)：F4独立UART提供XYZ归一化位置和F1舵机优先融合pitch/yaw，FPGA只查询/同步/接收，不下发运动；PC不逐包转发。version=2/profile=0x4D32，与现有PC配置口分开接入。2026-10-12 已新增独立 V2 UART/会话/状态队列及网络发送模块，完成局部离线回归与隔离内部时序验证，见[网络与控制报告](reports/network_control_20261012.md)。尚未接入板级顶层、生成放行位流或验证实板；yaw到图像补偿的映射需先标定。

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

## PDS 工程入口（按顶层区分）

完整视频主工程为 `pango_video_system`，通过 [build_video_system.py](scripts/build_video_system.py) 从 `rtl/`、IP 和真实板级约束生成冻结 PDS 工程；各次实际工程和结果位于 `build/full_integration_20261013/`。本轮候选、布局布线次数和验证状态以 [五次完整尝试批次索引](build/route_campaign_20261015/batch01/batch_index.json) 和 [优化记录](reports/route_campaign_1080p30_20261015.md) 为准。尚未通过实际布线/min-max/bitgen 的候选不能作为交付位流。

旧 IP 集成底座可打开 [pango_video_top.pds](project/pango_video_top/pango_video_top.pds)，其功能范围不等同完整视频主工程。共同目标为 Logos2 / PG2L100H / FBG676 / -6，工具为 PDS 2022.2-SP6.4 build 146967。

旧 IP 集成底座在仓库根目录使用以下重建命令（不调用下载器）：

```powershell
./fpga/scripts/build.ps1 -GenerateIps -LicenseFile '本机许可证的实际路径'
```

`-Stage compile` 只执行工程读取与编译；不加 `-GenerateIps` 时复用当前 IP 生成物。PDS 和 Python 路径可分别通过 `-PdsHome`、`-Python` 覆盖。许可证参数只影响子进程环境，脚本结束后恢复，不修改系统或用户设置；不要把许可证内容提交至 Git。

参数入口是 [ip_catalog.json](config/ip_catalog.json) 和 [board.json](config/board.json)。原生生成物归 `ip/`，工程归 `project/`，编译/综合/布局布线/时序/网表/位流/功耗报告归 `build/pango_video_top/`。不要直接改生成的 HDL 或手写 `.pds` 文件结构。

当前所有候选 IP 在 `rtl/memory/ip_integration_bank.v` 和板级顶层中实例化；集成观察逻辑不代表 ISP、帧池 DMA、网络协议或几何算法已经实现。DDR 地址请求保持空闲、网口 PHY 保持复位，HDMI 只包含原语及空白符号。2026-09-10 已完成原生重构建、复位/RGMII/TMDS 单元仿真和一次 SRAM 临时下载，但下载后出现 `over_temp=1`，回读校验已中止，**暂停再次上板或下载**。详细证据与未验证范围见[首次上板记录](reports/board_validation_20260910.md)。外部接口时序、DDR 实物参数、DQS 极性及 PHY 延时配置仍须单独签核；本工程没有完成完整功能或热稳定性验收。

## 本轮实现门槛

1. 先验证 RAW8 真实1080p30、DDR混合读写、RGMII与HDMI30，不以PHY链路灯、720p画面或旧200H位流认定通过。
2. 实现64字节应用头、最多1400字节载荷的网络V1及有界队列；CRC32图像报文与UART CRC16控制报文分别验证。
3. 帧池保留RAW/S1/结果三银行、64MiB地址区；RAW DDR stride2048、网络stride1920。删除两个独立RGB快照槽；历史补全从S1池持有一个明确HISTORY引用。
4. 暴露输入/处理/显示/网络完整帧、丢包、溢出及参数生效记录。普通HDMI采集不能自动获得源帧号。
5. 基础ISP与定点参考模型归model/；调试信号、无PC演示及功耗测量均保留真实证据。板级功耗不能命名为芯片核心功耗。

本版范围为单路真实1080p30，不保留60FPS/第二输入扩展。

## 2026-10-12 摄像头 PWM 固定测评模式

720p RGB565 诊断路径已新增 SCCB 读取、身份/时序快照、固定曝光/增益/白平衡提交与回读门控，以及就绪掉线后的预热恢复。默认仍为自动诊断模式；固定参数需先完成 XCLK、内部行时间和光强频率核验。8 组 RTL 回归、7 项曝光模型测试和 PDS Compile 通过，尚无消条纹实测、运行期参数切换或 PC 查询桥。详见[专项验证报告](reports/ov5640_pwm_20261012.md)和[使用说明](rtl/mini_camera_diag/OV5640_PWM_README.md)。本更新不解除既有热告警及下载放行条件。

## 2026-10-15 完整视频工程物理实现进展

完整顶层 `pango_video_system` 连接 RAW8、原生 DDR、FPGA ISP、透视/镜头矫正、HDMI、S0 网络、同源 RGB 快照及 PC 参数控制。最新要求保持1920×1080矫正至少30fps，按五次完整布局布线尝试失败后复盘；工具内部详细路由迭代不算一次完整尝试。

各次完整尝试在 [batch01](build/route_campaign_20261015/batch01/batch_index.json) 中登记，尚无本轮成功位流。已验证的地址/长度预计算、refill存储与DMA预取候选在独立冻结工程中运行；共享描述符和固定字节通道打包器继续接受完整模型及MAP验证。正式RTL尚未推广本轮候选，不能混用候选源码、模型和旧位流；进展和准确证据路径见 [优化记录](reports/route_campaign_1080p30_20261015.md)。旧O已自然拥塞失败，旧J已主动停止且不计为完整尝试，两者保留原始日志。

125MHz业务/DDR时钟、74.25MHz像素及371.25MHz串行时钟保持，未用放宽时序约束消除违例。只有同一真实routed数据库通过min/max时序后才生成并打包位流；模型周期和像素检查不冒充实板持续1080p30验收。本轮不烧录。MCU外部连接暂缓，自动Gamma及动态LUT上传未集成。历史集成说明见 [集成报告](reports/full_integration_20261013.md)，当前状态入口见 [active_work_state.json](build/full_integration_20261013/active_work_state.json)。

## 2026-10-15 DMA BRAM route repair / bitstream-only scope

Completed candidate `delay_20261015_111425_510321` compile/SYN/MAP with native exit 0, no E errors and all 290 source hashes intact (1330.769 seconds). MAP: 43,867 LUT / 42,536 FF / 1,809 distributed RAM / 125 APM / 86 DRM / 115 IO. Compared with H MAP: -937 LUT, -42 FF, -896 distributed RAM, +28 DRM. SYN: 43,874 LUT / 42,547 FF; controlsets remain 735.

The exact DMA source was promoted after checking the original live SHA and tested candidate SHA. Full 1080p/control/snapshot model `verilator_20261015_110249_115579`, six recovery regressions, 18 original/candidate burst regressions and frozen host decode `host/reports/fpga_rgb_vectors_20261015_111930_213424.json` passed. Last modeled geometry frame: 4,072,757 cycles at 125MHz = 32.582056ms; this is not measured hardware throughput.

Primary native PnR started at 11:36 in `resume_20261015_113643_076635`, Normal / seed11 / decon1 / control-chain500 / congest200, preserving every clock and I/O constraint. `complete_video_after_map.py` then requires actual routed min/max success before bitgen and strict source-bound packaging. J `phys_20261015_060945_294286` remains the sole backup. E was deliberately stopped at 11:30 with exact process-identity and before/after source guards; its Flow-0189 is a consequence of that stop, not a natural route failure.

No new routed timing pass or bitstream yet. No programming or programming preparation. Detailed evidence: `fpga/reports/route_efficiency_diagnosis_20261015.md`.


## 2026-10-15 12:17 route-only congestion-cost repair

K completed placement in 1160.92s; final detailed-placement wirelength 2,128,716, checksum 461BCEA49DA7CD60. Global routing took 100.52s; detailed routing contains 106,286 subnets. K0/1/2/3 left 81,540 / 78,172 / 74,883 / 72,185 subnets, with CPU 34.59375 / 39.125 / 66.5 / 356.03125s. J at the same first four rounds left 83,430 / 80,563 / 77,405 / 74,672, CPU 34.5625 / 35.171875 / 37.640625 / 42.984375s. Thus the BRAM change reduced resources but did not demonstrate early route acceleration. No eventual convergence or failure is inferred.

K was deliberately stopped at 12:15:54 after exact executable/parent/command/creation and all 290 before/after SHA guards. Its Flow-0189 and driver exit1 result from this stop. All evidence and the completed PLC remain preserved.

L `phys_20261015_121417_911429` copies the exact K290/MAP/PCF and completed PLC, SHA `ceeac3f728848fb736296eb221d848236792a7e22d6afce4232e2674179cc5d8`. Resume `resume_20261015_121627_645743` explicitly passes `-input_place_db_file` and `-pin_cost_increasing_speed 600`. The official installed guide p113/p252 and native help document this integer congestion-pin cost (default300); 600 is a task-selected repair value, not a vendor-recommended optimum. PDS accepted the native command and directly started routing, with exactly K's 89,621 nets, initial slack -2581 and TNS -50574. No new global placement occurred. The command's default seed7 does not describe the reused seed11 placement; source placement provenance is recorded separately.

Timing weight, clocks, constraints, functional RTL, model and host evidence are unchanged. `resume_video_system.py` now accepts an optional explicit pin cost; omission preserves existing behavior. `route_and_package.py` in L continues through strict routed min/max, bitgen and packaging only after success. J remains the only backup. This is not a new RTL optimization sweep. No new bitstream or hardware action.

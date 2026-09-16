# 2026-09-10 原生构建、离线仿真与首次上板记录

## 结论：已下载，但过温标志导致上板测试暂停

**请关闭板卡电源，排查供电、散热和状态异常，在原因明确前不要再次上电或下载。**

原生工具确认本轮位流配置成功、`DONE=1`；但下载后 JTAG 服务日志中的状态值为十进制 `135330944`，即 **`0x0810FC80`**，其 bit 27 `over_temp=1`。下载前状态为 `0x00180C80`，该位为 0。这里确认的是工具读取到的过温标志，不是温度传感器实测数值；尚不能区分真实过温、供电/散热问题或状态读取异常，也不能据此断言硬件已损坏。

发现该标志后已通知用户断电，并在 **21:42:51（Asia/Shanghai）** 核对进程身份后停止本轮配置客户端与其 JTAG 服务。原生回读校验最后记录进度 **45%**，没有完成，不能列为通过，也不是已经确认的配置位比较失败。中止后板卡实际运行状态未重新读取，是否已断电仍待用户确认。没有擦写启动 Flash、eFuse 或密钥，也没有操作用户 PDS GUI。

下载入口 [jtag_program_sram.tcl](../scripts/jtag_program_sram.tcl) 已停用，且已移除入口中的可执行硬件操作命令，防止误重试。实际执行版本只作为证据保存在本轮 `jtag/executed_program_sram.tcl`，禁止直接重跑。后续下载流程必须先读取并检查配置后状态，再另行执行校验，不能再次在过温检查之前进行长时间回读。

## 用户后续反馈与当前操作边界

2026-09-10，用户补充：**未使用外部辅助散热，现场感觉实际温度并不高**，并要求“先不作其他尝试，先将报告同步到云”。该信息作为用户现场观察记录；目前没有测温数值或测温方法，不能据此确认 FPGA 核心温度，也不足以判定 `over_temp` 为误报。是否已经断电、供电规格及异常原因仍未确认，原有测试结论不变。

按本次要求，仅整理并同步报告与必要证据，**不继续扫描、下载、回读、上电或开展其他测试**；保持下载入口停用，不改变板卡、参考资料或系统设置。结构化记录见 [validation_summary.json](../build/board_validation_20260910/validation_summary.json)。

## 本轮范围与环境

- 用户确认：盘古 100K MINI，PG2L100H-6FBG676；仅接 JTAG，未接网口、HDMI、OV5640。
- 工程目标：PG2L100H / FBG676 / -6；PDS 2022.2-SP6.4 build 146967；离线仿真为 ModelSim SE-64 10.1c。
- 分支保持 `codex/fpga-pds-project`；不切换、回退或推送其他分支。
- 主 PDS GUI 正打开工程，已将实现目录改回工程目录，并将旧产物移入各 `bak/`。本轮保留该现场，只对 **371 个当前输入文件**建立校验一致的独立快照，在快照内原生重建。没有覆盖主工程、原 RTL 或用户旧构建。
- 验证目录：[board_validation_20260910](../build/board_validation_20260910/)，输入记录：[source_snapshot.json](../build/board_validation_20260910/source_snapshot.json)。

## 实际完成的检查

| 项目 | 实际结果 | 范围说明 |
| --- | --- | --- |
| 15 个 IP 原生重生成 | 全部 0 error / 0 warning | 在独立快照中运行 IP Compiler |
| PDS 原生八阶段构建 | 通过严格审计，0 error | Compile、ADS 综合、Map、PnR、Timing、Netlist、Bitstream、Power |
| 内部静态时序 | `All Constraints Met.` | 快慢角 setup/hold/recovery/removal 无违例；不是外部 IO 签核 |
| 复位与 RGMII RTL 单元仿真 | **6,357 检查，0 错误** | 2/3/4 级复位链、16 组复位相位、停钟复位；512 组 TX 和 1,024 组 RX 字节/控制组合 |
| TMDS RTL 单元仿真 | **22,572 检查，0 错误** | 1,024 个恒定符号、主从位映射、差分互补、复位恢复；一次校准后固定采样相位 |
| JTAG 扫链与身份 | 识别 `PG2L100H`，ID `0x00602899` | 单条 USB Cable II、单个识别器件；不是仅凭 Windows USB 枚举判断 |
| 易失配置 SRAM 下载 | 原生 `Program` 成功，`DONE=1` | 写入本轮新位流；不固化 Flash；工具记录下载耗时 143.4 秒 |
| 配置回读校验 | **安全中止，未完成** | 45%；原生 Verify 仅比较非 DRM 配置位，不代替 RAM/DDR 数据测试 |
| 板上功能/热稳定性 | **未通过完整验收，暂停** | 过温标志待查，没有真实温度、功耗或接口吞吐测量 |

原生构建运行时间为 **20:58:10–21:03:07（Asia/Shanghai）**。最小内部恢复裕量仍为 **0.023 ns**，不代表加入后续逻辑后仍能闭合。主构建并非零告警：Compile 2923、Synthesize 3864、Map 31、Timing 127，其余阶段 0；完整告警保留，未改写厂商源码来消除告警。

TMDS 仿真采用本机 PDS 原生受保护子模型，没有替换成自编模型或解密。保留原生 `ts_ctrl` 位宽以及未连接 `TERM_FB/TFB` 等告警；测试通过仅覆盖声明的恒定符号场景，不代表完整 HDMI 协议或时序验证。仿真像素周期 13.4700 ns、高电平 5.3880 ns，为 1 ps 精度量化下的 40% 占空比结果，不是板上时钟实测。

## 时间线与原始证据

- 下载前只读探测：[probe_console.log](../build/board_validation_20260910/jtag/probe_console.log)，`DONE=0`、`over_temp=0`。
- 两次未写板的工具调用问题分别保留于 `program_console.log`、`program_retry_console.log`：原生文本占位符计数及命令展开异常；最终改用直接 Tcl 文件和临时进程变量，未修改系统环境变量。
- 成功下载调用：[program_native_console.log](../build/board_validation_20260910/jtag/program_native_console.log)。
- **21:18:35**，JTAG 服务记录下载后状态 `135330944`；**21:18:37** 开始回读。随后检查服务日志时发现 bit 27 置位，**21:42:51** 停止客户端 PID 54932 及其子服务 PID 102200。详细时间和进度见 [jtagserver.log](../build/board_validation_20260910/jtag/log/jtagserver.log)。
- 复位/RGMII 自检：[tb_board_io.sv](../sim/tb_board_io.sv)，[仿真日志](../build/board_validation_20260910/simulation/board_io_simulation.log)。
- TMDS 自检：[tb_tmds_serializer.sv](../sim/tb_tmds_serializer.sv)，[仿真日志](../build/board_validation_20260910/simulation/tmds_retry_simulation.log)。首次调用的 Windows 库路径解析错误另保留在 `tmds_simulation.log`，不能把首次失败日志当作最终通过证据。
- 构建证据：[all_result.json](../build/board_validation_20260910/workspace/fpga/build/pango_video_top/all_result.json)、[all_audit.json](../build/board_validation_20260910/workspace/fpga/build/pango_video_top/all_audit.json)。其中 `hardware_tested/programmed=false` 是构建步骤自己的边界，不应为迎合本次结果而改写。

本次实际下载位流位于独立快照的 `workspace/fpga/build/pango_video_top/generate_bitstream/pango_video_top.sbit`，SHA-256 为：

```text
66d5491f596a0dd94c368073df863efb0bd9a542236b17faa440b6966b9b7d18
```

同目录 `.smsk` 保留，二者各 3,791,112 字节。此位流未发布到 `release/`，没有获得再次上板或生产使用的批准。启动 Flash 内容未更改；易失配置在断电后丢失。

## 未执行、不能冒充通过的项目

当前顶层仍为 IP 集成工程：DDR 地址请求保持空闲、PHY 保持复位、HDMI 只输出固定符号。没有可用的 DDR BIST、状态读回接口、摄像头控制、完整 ISP/几何矫正、MAC/UDP 或视频时序链路。

因此本次没有验证 DDR 校准完成及真实读写、帧池、图像质量、1080p30/60FPS、网络吞吐、HDMI 画面、温升/功耗稳定性，也没有执行完整顶层/DDR 功能仿真、布局布线后带 SDF 仿真或完整 CDC/外部 IO 签核。COM13/COM14 来自 FTDI 下载线，不能当作已经连接的板载 CP2102 业务串口。

## 资料核对与下一步

使用 PDF 技能查阅项目内手册副本，依据安装版 `Fabric_Configuration_User_Guide.pdf` 第 4.5/4.6 节执行原生 Tcl，按第 5.2.3 节（PDF 101–102 页）解释 Logos2 状态位并触发本次安全暂停；依据 `Simulation_User_Guide.pdf` 使用原生 GTP 行为库。

MINI 硬件 V1.3 手册第 13–17 页的参考时钟、DDR 电压及 DQ/DQS/地址控制引脚与工程配置核对一致。手册对 DDR 总容量前后存在不一致（第 10 页与第 15 页），未将容量或实物颗粒写成已确认。手册来自 `reference/盘古100K200K MINI开发板/`；官方两份手册来自 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/`，均先复制到本轮 `manuals/` 后读取。官方/参考原文件没有修改；图像查看工具启动失败，未声称完成渲染页的视觉复核，电气/引脚核对依据可提取的原文表格。

下一步首先需要用户确认**已经断电**，提供供电电压/电源规格、散热片/风扇情况和板卡/接线照片。排除异常并得到继续测试的明确指示后，才制定受控的低活动率诊断方案；当前不自动重试下载，不用修改状态定义或屏蔽告警来绕过过温标志。

## 本次报告同步范围

本次按报告级归档整理：包含本报告、FPGA README 中的状态入口、结构化摘要、输入哈希清单、原生构建/IP 日志与审计、JTAG 记录及两个离线自检源文件和日志；下载入口以已停用版本纳入，历史下载脚本仅作证据。完整源文件快照、厂商手册/仿真库副本、编译数据库、本轮位流及未完成回读的二进制文件仍保留本地，不属于本次报告级同步。因此本次同步不等于完整验证工作区备份，也不构成位流发布或重新测试授权。

云端目标仅为既有 GitHub 仓库的 `codex/fpga-pds-project` 分支。本分支已有的未推送原生工程构建提交 `9d28b9a` 是报告提交的祖先，会随正常推送一并同步；不推送其他分支，不纳入许可证文件，也不纳入主工作区其他尚未提交的代码、注释及 GUI 产物变动。原始日志保持原样，未新增忽略规则。

# MINI 通信上板候选：离线构建与验证

日期：2026-09-22。分支：`codex/fpga-mcu-praw-protocol`。

后续更正：本文是e51d旧候选的离线历史记录，不代表当前实板状态。其中30ms PHY等待、MDIO高电平末端采样及相应旧模型验证已被板测证据否定；PLL带宽和LED极性也已修正。当前实现及分版失败/修复证据见[冷启动故障与修正记录](comms_cold_boot_20260922.md)，请勿重新把旧候选当作已通过上板验收的版本。

## 结论与范围

已从抽象通信模块推进到 PG2L100H-6FBG676 MINI 的独立板级工程，完成原生 IP、PDS 工程读取、编译、综合、布局布线、慢/快角 min/max 时序、SBIT 生成和 XT25F128 SFC 离线转换。最终时序在本文预算下闭合，28 个构建输入哈希与镜像一致。

**这是可供后续受控上板的通信联调候选，不是已验收的整机视频版本。** 输出为显式合成测试流，未实例化摄像头、DDR、ISP 或 HDMI。真实 MCU 接线尚未确认，板载 CP2102 仅供 PC 模拟 MCU。原真实摄像头 HDMI 基线和 main 不改动；本轮未烧录、未打开串口/实板网络、未采集视频。

严格原生 GPLL 仿真仍有初始化诊断，因此不能写成“全部仿真无错误通过”。详见下文限制。

发布目录：[comms_bringup_20260922_e51d3cc9c9ee](../release/comms_bringup_20260922_e51d3cc9c9ee/README.md)。SBIT 与原生转换后的 SFC 均为 3,791,112 字节，SHA256 均为：

`e51d3cc9c9ee85814fa7525621d9779b5a5679300f6e9933ee6d054dd7da9cbf`

## 本轮实现与优化

- `mini_comms_bringup`：只启用核对过的 19 个物理引脚。125 MHz 原生 PLL、同步复位释放、低速 LED 状态；不用未知 MCU 扩展脚。
- `mdio_clause22` / `rtl8211f_init`：10 ms PHY 硬复位、30 ms 等待、完整前导码、504 ns MDC 半周期、末端采样覆盖 300 ns MDIO 延迟。ID/ACK/寄存器回读失败锁存故障；仅允许 1000/full，关闭 EEE 广告，定期轮询链路。
- RGMII：时钟和数据 ODDR 共用 125 MHz 时钟树，由 PHY D08:11 bit8 提供 2 ns TXID，不再叠加 FPGA +90°。所有六路 TX 使用 16 mA FAST；较低驱动的时序失败记录保留。需要后续示波器确认信号完整性，不能仅凭驱动配置推断通过。
- IPv4 校验和：组合长加法改为流水线，保留线格式、双包缓存和独立 FCS。中断链路只阻止新帧准入；已接收帧排空，错误锁存后禁止继续产生新帧。
- `comms_boot_config`：115200/8N1，CRC16 检查的专用 0x70 启动配置；非零外部 epoch、明确单播 MAC/IP/端口，完整 ACK 和保护间隔后切换至原 MCU 端点。配置锁定至复位，无默认广播。
- `comms_test_source`：1920×1080、RAW8 形状，支持背压的棋盘/灰度合成字节；`descriptor_id=0x54534554` 标识 TEST，30 fps 仅为准入预算。
- 新增逐次生成、严格日志检查、最终时序/源码哈希审计及离线发布脚本；新增/修改功能块均有用途注释。PDS/官方资料及原示例未修改。

接口与启动命令详见[通信上板联调方案](../../output/FPGA通信上板联调方案.md)。PRAW V1 正式线格式不变，不把 RGB565 基线字节冒充 RAW8。

## 仿真实际结果

| 项目 | 实际结果及证据目录（均在 fpga/build） |
| --- | --- |
| MCU UART/会话/CRC/异常 | PASS；1.8432 MHz 压缩全用例 5378 checks，实际 125 MHz/115200 用例 2041 checks；`mcu_protocol_20260922_003335_032` |
| PRAW 分片与 host 解码 | PASS；1492 个包及故障注入；`praw_protocol_20260922_003346_955` |
| Ethernet/IPv4/UDP/FCS/IFG | PASS；47 个完整以太帧及 6 个预期错误事件；`udp_ethernet/sim_20260922_003353_077` |
| 视频网络组合 | PASS；3 帧/1484 包，含完整 1080p 与逐字节 host 重组；`video_network_20260922_003357_327` |
| 原生 ODDR 回归（默认 FPGA 相移模式） | PASS；56080 checks、3072 向量、4 次局部及 1 次全局复位；`rgmii_tx_20260922_003403_092` |
| PHY/MDIO（本候选 PHY_TXID=1） | PASS；23260 checks、67 事务；含 300 ns 数据延迟、链路变化、坏 ID/ACK/写回失败；`comms_board_sim/phy_20260922_002804_851` |
| 启动 UART 网关 | PASS；286 checks、6 回应，CRC、非法地址、字节序、停止位及切换保护；`comms_board_sim/boot_20260922_002140_966` |
| 合成源→PRAW→MAC→原生 ODDR 引脚→host 检查器 | PASS；1 帧、1482 包、2073600 字节逐个核对；`comms_board_sim/source_20260922_003122_374` |
| 原生 GPLL | **严格失败**；1000 次 8 ns 周期/2 ns 相位断言通过，但有初始化除零诊断；`comms_board_sim/pll_20260922_002107_882` |
| 离线启动报文生成工具 | PASS；CRC 黄金向量/字节布局/非法 MAC 共 6 项；`comms_board_refs/boot_encoder_selftest.log` |

协议测试中的 errors 计数包括主动故障注入的预期错误事件，不是未处理的测试失败。原 ODDR 回归还报告新增可选 `txc_reset_n` 未连接警告；该测试保持默认 `SEPARATE_TXC_RESET=0`，此输入不被使用，板级顶层显式连接。

本次源链路仿真使用理想 125 MHz 时钟与原生 ODDR，并非包含 GPLL/PHY 实物的整板验证。合成源完成提交需要 2,267,623 个周期（18.140984 ms），不代表最后一个以太帧已经到达 PC，也不是实测帧率。未执行实际网络吞吐、摄像头、MCU 固件或 HDMI 验收。

## 最终原生构建与时序

工具：PDS 2022.2-SP6.4 build 146967。工程：[mini_comms_bringup.pds](../project/mini_comms_bringup/mini_comms_bringup.pds)。最终运行：`build/mini_comms_bringup/native_20260922_003807_816`。

`gen_bit_stream` 在此安装版本会重跑前序阶段，因此验收使用生成镜像时的**最后一份** `implementation/report_timing/mini_comms_bringup.rtr`，不是仅采用更早的 stage_report。报告 SHA256：

`0d29cc1b64017f4ae30ae28a43da2c09974c14ecc29769d367f23dde272c7879`

Design Summary 为 All Constraints Met，两个角的最小脉宽检查通过。以下为最差余量，单位 ns：

| 路径/检查 | Slow | Fast |
| --- | ---: | ---: |
| NET125 内部 setup | 0.255 | 3.021 |
| NET125 内部 hold | 0.174 | 0.099 |
| NET125→PHY_SAMPLE setup | 0.126 | 0.143 |
| NET125→PHY_SAMPLE hold | 0.103 | 0.115 |
| 复位 recovery | 1.300 | 2.204 |
| 复位 removal | 0.243 | 0.137 |

NET125 周期 8 ns；PHY_SAMPLE 波形 {2,6} ns 表示 PHY 内部接收延迟，不代表 FPGA TXC 引脚真实偏移 2 ns。外部 max/min delay 为 ±1.450 ns：接收端 1 ns，加 PCB 偏斜 0.25 ns 和 PHY 延迟预算 0.20 ns；另有 0.10 ns 人工不确定度，工具自身不确定度未删除。**PCB 偏斜、PHY 实际延迟及波形尚未测量**，当前预算下最小外部余量 0.103 ns，必须在上板阶段核验。

最终布局报告：CLMA LUT 2843 + CLMS LUT 1651，FF 3830，1 个 GPLL、1 个 APM、1 个 DRM 物理资源、19 个 IO；逻辑综合统计的 LUT/DRM18K 口径不同，不混报。无 latch。六个 ODDR 分别驱动 TXC、CTL 与四位数据。

UART/MDIO 只对 pad→首级同步器设 false path，后级与复位释放仍检查。LED/UART TX/PHY 慢控制口有 0～10 ns max/min 路径边界，但不是同步 I/O delay；Timing-4086/4087 诊断保留，不把它们解释成已完成全物理接口验收。G25 为配置复用脚的诊断以及常量/无效分支等综合警告也保留；无 unresolved constraint 对象错误。不是零警告构建。

## 尚未解除的限制

1. ModelSim SE-64 10.1c 使用未修改的 PDS `GTP_GPLL.v` 时，在第 1026 行报告 vsim-8604 NaN 除零。reset/优化模式的尝试均保留日志。阅读模型发现 `midd_set` 初始化为零及组合 real 计算的调度关系，疑似模型启动问题；这不是厂商确认的结论。未屏蔽错误、未篡改官方模型，严格结果仍为失败。稳定交付前需用厂商支持环境复核或取得厂商说明。
2. 实际 MCU 型号、引脚、电平及共地未确认。CP2102 模拟协议不等于 MCU 互通，不能随意接扩展排针。
3. 真实 RAW8 采集、S0 帧池读 DMA、跨时钟描述符和帧槽所有权尚未接入；新候选没有摄像头/HDMI 功能。后续应在保留既有 HDMI 基线的前提下单独集成，不能把合成测试帧用于图像验收。
4. TX-only 单播，无 ARP/ICMP/DHCP/RX。网络目的地需显式配置；host 必须把 TEST 数据标为 synthetic，丢弃不完整帧。现有 host 线上接收与自动配置工具仍需后续实板联调。
5. 未执行烧录/Flash 回读/冷启动/长稳/功耗/温度/真实吞吐或 FPGA 接口示波测量，不能推断硬件已通过。

## SFC、复建与后续上板

官方未修改安装的 Flash 列表不支持 XT25F128，首次转换仅生成空文件并明确失败；该次产物移至最终 native 目录的 `export_failed_official/`，不作为发布物。随后只读使用本项目此前已有的 `D:/XDU/concept/26-FPGA-Pango-test/pds_cfg_runtime`，执行原生 `cfg_gen_sfc`，SPI X1、opcode 11、起始地址 0。未调用连接、扫描、擦除、下载、校验或 eFuse 命令。

独立 runtime 是既有项目副本，不能声称官方原装工具天然支持该 Flash。转换 exe 和 Flash 列表的前后哈希一致并记录于发布 manifest；没有新改运行时、官方安装或系统设置。此模式转换后 SBIT/SFC 字节相同，是工具实际输出，不是改扩展名冒充转换。

以下从仓库根目录运行；本机许可证仅作为子进程参数，不上传许可证正文。重新构建会更新此独立工程的 implementation；重新生成的镜像必须重新审计，不能沿用本报告哈希。

```powershell
./fpga/scripts/generate_ips.ps1 -Only comms_pll -LicenseFile '<本机许可证路径>'
./fpga/scripts/test_fpga_comms.ps1
./fpga/scripts/sim_comms_board.ps1 -Case phy -PhyTxDelay 1
./fpga/scripts/sim_comms_board.ps1 -Case boot
./fpga/scripts/sim_comms_board.ps1 -Case source
# 已知严格失败必须保留，不以流程继续运行掩盖此项。
./fpga/scripts/sim_comms_board.ps1 -Case pll
./fpga/scripts/build_mini_comms_bringup.ps1 -Stage report_timing -EmitBitstream -LicenseFile '<本机许可证路径>'
# Run 指向上一步打印的新 native 目录，下面是本次已核对的实例。
python -B fpga/scripts/audit_comms_candidate.py fpga/build/mini_comms_bringup/native_20260922_003807_816
./fpga/scripts/export_comms_candidate.ps1 -Run fpga/build/mini_comms_bringup/native_20260922_003807_816 -CfgRuntime 'D:/XDU/concept/26-FPGA-Pango-test/pds_cfg_runtime'
python -B fpga/scripts/prepare_comms_boot.py --self-test
```

发布脚本拒绝覆盖同名发布目录。恢复云端工程后，源码审计按当前 checkout 的 fpga 相对路径校验原始哈希；重新构建和导出需本机安装相应工具及现有受控 Flash runtime，不在仓库中分发工具安装程序。

后续需用户明确执行上板时，仍按已约定流程固化 Flash、回读校验并冷启动，分别记录三项结果。不要运行旧摄像头烧录脚本来烧本候选（目标路径不同），也不要只做 SRAM 下载后称已固化。恢复镜像保留为 `fpga/build/camera_div2_flash_20260921/Top.sfc`：

`317733DFC9A6D083971E2E09B203E403B8939E6163B33BD7EAB32667048CFAAC`

PDF 只读审阅及图表核对用于确认 MINI 网口/CP2102 针脚，不仅依赖文字抽取；临时渲染页不纳入发布。具体原始路径、安装版本和一次性接口预算见[联调方案的依据](../../output/FPGA通信上板联调方案.md#依据)。本次云端备份仅当前 FPGA 分支的实现、仿真/构建记录、位流及规划说明，不含实测视频/采集帧。

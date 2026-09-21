# FPGA通信子系统离线实现与验证（2026-09-21）

结论：MCU UART协议、PRAW视频分包、UDP/IPv4/Ethernet发送、Pango原生RGMII TX以及组合顶层已实现；完整离线回归通过，PDS原生工程能够生成、重读、编译、综合。**没有烧录，没有实物串口/网口通信；不是可上板验收版本。** 综合估计有hold违例，外部时序和完整板级集成仍未签核。

## 1. 分支、范围与现有工程

开发分支：`codex/fpga-mcu-praw-protocol`，基于云端main提交`f0a2ddd94a2a498a48121c268caf88b3c2878363`。本次只修改FPGA开发区与跨端规划文档，不改MCU/host实现，不合并到main，不改原工作区中的其他分支或现有HDMI摄像头工程。最终云端备份推送此FPGA分支。

当前已实测摄像头链仍是RGB565/720p HDMI。新增网络端点要求完整、紧凑RAW8帧或RGB888快照；本次**没有**把旧RGB565摄像头总线直接接入或改名为RAW8，没有完成RAW模式、ISP、DDR读DMA与帧池网络槽管理。仿真源明确为合成字节，不是摄像头图像。

未打开串口、JTAG、Flash、摄像头或实板网络接口；未更改系统环境/网络设置；未上传实测视频、抽帧图像或原始采集数据。官方PDS文档、原语模型和MINI参考资料只读。

## 2. 交付入口与实现

| 内容 | 入口 |
|---|---|
| MCU完整线格式、会话/事件身份、ACK/NACK | [FPGA_MCU通信协议V1](../../output/FPGA_MCU通信协议V1.md) |
| 网络协议、数据所有权与集成边界 | [FPGA通信子系统与PRAW发送实现V1](../../output/FPGA通信子系统与PRAW发送实现V1.md) |
| 组合顶层 | [fpga_comms_top.v](../rtl/control/fpga_comms_top.v) |
| MCU端点及4个依赖模块 | [mcu_protocol.v](../rtl/control/mcu_protocol.v) |
| 帧描述符/分包/CRC32/双包缓存 | [praw_packetizer.v](../rtl/network/praw_packetizer.v) |
| UDP/IP/MAC双缓存发送 | [udp_ipv4_eth_tx.v](../rtl/network/udp_ipv4_eth_tx.v) |
| 每帧锁存peer的网络组合核心 | [video_network_tx.v](../rtl/network/video_network_tx.v) |
| 原生ODDR RGMII发送 | [pango_rgmii_tx.v](../rtl/network/pango_rgmii_tx.v) |
| 原生PDS工程 | [fpga_comms.pds](../project/fpga_comms/fpga_comms.pds) |
| 离线全回归 | [test_fpga_comms.ps1](../scripts/test_fpga_comms.ps1) |
| 原生生成/编译/综合 | [build_fpga_comms.ps1](../scripts/build_fpga_comms.ps1) |

所有新增模块、功能块和脚本均说明用途。UART默认115200/8N1，CRC16-CCITT-FALSE，8项回复队列；坏CRC/版本/长度、截断、过载不产生环境事件副作用。事件去重不依赖可回绕的包seq，使用epoch/session/event身份；epoch由顶层可靠来源提供，未就绪时拒绝建立会话。环境接受时刻不冒充曝光时刻。

网络保持现有host的PRAW V1：64字节小端头、1400字节非尾块、应用CRC32；外包IPv4/UDP/以太网，IP校验和、FCS、零padding、至少12周期IFG。静态peer，无ARP/DHCP/ICMP、MDIO或接收通道；peer参数逐帧锁存。关闭enable仅禁止新帧，不截断已接受帧。异常输入不补零造帧，已发出的前缀包由host按不完整帧处理。

帧尺寸计算在描述符锁存后分阶段完成，32周期常数除法不在单周期输入路径上；该开销每帧一次。入口只接可背压DDR读流，同步跨域和实时DVP缓冲由后续帧池适配完成。

## 3. 最终完整回归

执行`./fpga/scripts/test_fpga_comms.ps1`，退出0，输出`FPGA_COMMS_REGRESSION_PASS`。ModelSim SE-64 10.1c；PDS 2022.2-SP6.4 build146967。下列是最终重跑目录，早期调试目录保留，不混作最终证据。

| 验证层 | 实际结果 | 最终证据 |
|---|---|---|
| MCU完整串行异常/会话回归 | 5,378项检查、56响应，通过 | [full.log](../build/mcu_protocol_20260921_225538_880/full.log) |
| MCU真实125MHz/115200、20ms超时 | 2,041项检查、21响应，通过 | [clock125.log](../build/mcu_protocol_20260921_225538_880/clock125.log) |
| PRAW → 现有host解码器 | 7帧、1492包、2,177,236应用字节；7类错误拒绝，通过 | [result.json](../build/praw_protocol_20260921_225549_381/result.json) |
| MAC独立检查 | 47完整以太帧；长度/CRC/超时/复位/双缓存竞争/IFG通过 | [check_result.json](../build/udp_ethernet/sim_20260921_225554_988/check_result.json) |
| 完整帧 → PRAW → MAC → host | 3帧、1484以太帧，全部像素逐字节一致 | [result.json](../build/video_network_20260921_225559_261/result.json) |
| 官方ODDR/GRS原语 | 3072组合、56,080检查、0错误 | [result.json](../build/rgmii_tx_20260921_225604_758/result.json) |

完整1080p RAW8帧为2,073,600字节、1482包，尾块200字节。连续可供数仿真从帧接收到MAC排空为2,269,232个125MHz周期，即18.153856ms、114.224 MB/s有效图像速率；仅为无DDR争用的RTL周期结果，不能称为真实1080p30、真实PHY吞吐或摄像头帧率通过。测试也验证了中途改描述符/地址不改变已接受帧、enable落下后仍排空。

详细单项报告：[MCU](mcu_protocol_sim_20260921.md)、[UDP/MAC](udp_ethernet_sim_20260921.md)、[原生RGMII](rgmii_tx_sim_20260921.md)。各运行目录保存日志、测试输出及源文件SHA256；PRAW与全链路同时记录现有host解码器哈希。源像素采用确定性公式，`.hex`是模拟信号证据，不是实测视频。

## 4. PDS原生工程、资源和时序限制

使用安装版`tcl2prj`从受控Tcl生成`.pds`，随后直接重读该文件执行compile/synthesize；没有手工构造PDS语法。原生写回后仅机械归一化实现目录到`fpga/build/fpga_comms/implementation`。工程目标Logos2 / PG2L100H / FBG676 / -6，源码依赖不落在被忽略reference目录。

最终原生结果：[result.json](../build/fpga_comms/native_20260921_225628_988/result.json)、[报告快照](../build/fpga_comms/native_20260921_225628_988/synthesis_report.snr)、[源哈希](../build/fpga_comms/native_20260921_225628_988/source_manifest.json)。

这是内部子系统综合工程，宽描述符/遥测端口不是1015根物理管脚。按官方ADS指南PDF页20/52使用`-disable_io_insertion`；不分配未知MCU管脚，不执行PNR、生成位流或下载。

- 资源：3706 LUT（5.56%）、2752寄存器（2.07%）、0锁存器、2个DRM18K（等效1个DRM36K）、1个APM、6个ODDR。PRAW包缓存映射为LUT RAM，MAC两个缓存映射为DRM。
- 125MHz综合setup WNS：+0.794ns；仅综合估算。
- 加入同FPGA内部边界1ns预算后，综合hold WHS：**−2.875ns，6794个违例端点**。原报告明确`Some Constraints Violated`，结果JSON也明确`synthesis_estimate_all_constraints_met=false`。没有通过放松/删除约束把它改报为通过。
- UART、异步复位及RGMII外部I/O尚无完整板级延时约束；日志保留未约束告警。常量传播环探测与fanout告警也保留，不宣称零告警。尚未执行完整时钟树、布局布线、后仿或外部setup/hold签核。

因此`passed=true`仅表示生成/编译/综合动作成功；不表示时序收敛、引脚正确或可烧录。上板前必须完成真正板级顶层中的时钟、复位、CDC、引脚、PHY TXID/相位、外部约束和PNR检查。

## 5. 复现与后续门槛

```powershell
# 纯离线协议全回归，不打开物理接口
./fpga/scripts/test_fpga_comms.ps1
# 原生内部子系统综合；许可证只注入当前子进程
./fpga/scripts/build_fpga_comms.ps1 -LicenseFile '本机许可证路径'
```

下一步不是直接烧录：先接RAW8完整帧读DMA/行尾剔除与帧池所有权，再补真实PHY初始化及静态peer配置来源、同源125MHz相位与复位、MCU独立UART固件适配和可靠epoch来源。现有MCU ASCII电机固件不兼容本二进制端点。曝光/帧身份与MCU环境时间的可靠配对也仍需独立实现及验证。

本次保留已完成摄像头HDMI固化基线；新功能以离线子系统交付，不替换板内Flash。

# UDP/IPv4/Ethernet GMII TX RTL 仿真报告（2026-09-21）

本轮实现双包缓存的 `udp_ipv4_eth_tx`，并完成指定 ModelSim 编译、RTL 仿真及 Python 独立逐字节验证。最终两组回归各校验 47 个完整帧，共 94 帧；均通过。结果仅证明 GMII 后端 RTL 功能和仿真周期吞吐，不代表 PG2L100H 综合、布局布线、125 MHz 时序收敛、RGMII/PHY 或真实 RAW1080p30 验收。

## 工作范围与来源

- 工作树：`C:/Users/ROG/.codex/worktrees/fpga-camera-main-publish/26-FPGA-Pango`。
- 分支：`codex/fpga-mcu-praw-protocol`。单项验证阶段未提交/推送；后续统一备份和顶层综合结果见[总报告](comms_offline_20260921.md)。没有操作硬件或烧录。
- 手工修改仅限本报告及 `fpga/rtl/network/udp_ipv4_eth_tx.v`、`fpga/sim/tb_udp_ipv4_eth_tx.sv`、`fpga/sim/check_ethernet_tx.py`、`fpga/scripts/sim_udp_ethernet.ps1`；运行产物在 `fpga/build/udp_ethernet/`。未修改其他协作实现。
- RTL 为独立 Verilog 实现，不依赖被忽略的 reference/PDS 目录或例程生成 IP；所有功能块均有用途和设计意图注释。

已只读核对以下原始资料；未在原目录生成文本、索引、日志或其他产物：

1. `D:/XDU/concept/26-FPGA-Pango/reference/盘古100K200K MINI开发板/2_Demo/2_11_ethernet_test/2_11_ethernet_test/source/` 下的 `rgmii_interface.v`、`mac_tx.v`、`udp_tx.v`、`ip_tx.v`、`crc32_gen.v`。核对 8 位 MAC 数据/valid、RGMII DDR 分界、前导码/SFD、UDP 长度/零校验和、CRC 输出约定。
2. 同例程 `ethernet_test.pds` 的器件为 **PG2L200H**；当前项目目标为 **Logos2 / PG2L100H / FBG676 / -6**。本轮未复用示例器件、引脚、时钟约束或其构建结果；RGMII 物理接口不在本次范围。
3. `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Simulation_User_Guide.pdf`，印刷页 5–8：区分行为仿真、综合后、布局布线后功能和时序仿真。本轮是行为级 RTL 仿真，无 GTP/VOP 实例，不需要器件仿真库。
4. 同目录 `ADS_Language_Support_Reference_Manual.pdf`，印刷页 35、37–40，尤其 4.1.3.2：同步 RAM 和 simple-dual-port 建模、同址冲突边界；以及 `ADS_Synthesis_User_Guide.pdf` 第 5.16 节、印刷页 93 的 `syn_ramstyle`。因此采用不复位数组的同步读写 RAM、`block_ram` 属性及分 bank 互斥使能。实际 DRM 映射和资源占用仍待综合验证。
5. UDP 零校验和语义参见 [RFC 768](https://www.rfc-editor.org/info/rfc768/)；MAC 零 padding 不纳入 IP length 参见 [RFC 894](https://www.rfc-editor.org/info/rfc894/)；DF=1、无分片的 atomic datagram 使用固定 ID 参见 [RFC 6864](https://www.rfc-editor.org/rfc/rfc6864.html#section-4.1)。

## 固定端口合同

模块名 `udp_ipv4_eth_tx`，参数 `integer RX_TIMEOUT_CYCLES=125000`（125 MHz 下 1 ms；小于 1 时钳为 1，不提供无限等待模式）。

| 端口 | 方向/宽度 | 合同 |
| --- | --- | --- |
| clk / reset_n | in / 1 | 125 MHz；低有效异步复位，系统负责同步释放与同域输入 |
| datagram_start / datagram_ready | in / out，1 | 两者同高的上升沿接受请求；start 可保持至握手 |
| udp_payload_length | in / 16 | 1..1464；接 PRAW 的 datagram_length |
| src_mac / dst_mac | in / 48 | start 握手锁存；最高有效字节先上网 |
| src_ip / dst_ip | in / 32 | start 握手锁存；网络序 |
| src_port / dst_port | in / 16 | start 握手锁存；动态端口，不硬编码现场值 |
| payload_valid / payload_ready | in / out，1 | 两者同高收一字节；首字节最早在 start 后下一上升沿 |
| payload_data | in / 8 | 按顺序收到声明长度后自动提交整包 |
| gmii_txd / gmii_tx_en | out / 8、1 | 连续逐字节 GMII，无 ready 输入 |
| gmii_tx_er | out / 1 | 恒 0；收包错误在发帧前丢弃 |
| busy | out / 1 | 任一包正在接收、排队、发送或执行 IFG |
| done | out / 1 | 单周期完成事件，与该包最后一字节 FCS 对齐 |
| error | out / 1 | 非法长度或当前接收包超时的事件脉冲 |

`datagram_ready` 独立于 `busy`；上层不得用 `!busy` 替代 ready。可以在发送前包、执行 IFG 时启动后包接收。两 bank 都占用时 start 被背压；不满足 ready 的 start 不接受、不报告长度错误。载荷 valid 不满足 ready 时不消费。

上层可配置 src=50001、dst=50000，但本模块无地址/端口默认常量。目的 MAC 必须由系统提供已知静态 peer；**未实现 ARP、DHCP、ICMP、链路协商、MDIO 或接收路径**。

## 缓存、边界与帧格式

两个 1464×8 载荷 bank 分别同步读写。RX 指针仅在收齐后前进，TX 指针仅在最后 FCS 后前进；发送期间保持 bank 占用，避免覆盖。超时不前进 RX 指针、不产生队列空洞。同步读端在 UDP 头最后一字节预取载荷首字节，后续持续提前一拍读，保证 GMII 不停顿。

超时定义为当前包连续 `RX_TIMEOUT_CYCLES` 个时钟没有载荷握手；每次握手清零计数。在截止周期发生握手时，以成功传输为先，不误超时。超时只丢弃未收齐的当前 bank，不影响另一 bank 的发送；上层观察 error 后应终止该包、重新申请 start，不能将余下字节当作新包。

0、1465..65535 的包长在 start 握手时拒绝，不收载荷、不发残帧。接收完成后没有下游背压：GMII 发送和 IFG 有固定有限时长。输入超时不是发送过程的 watchdog。

复位清空接收/排队/发送所有状态并立即撤销 GMII enable，不发 done/error。接收中复位不会产生残帧。**已开始发送时断言复位必然截断当前线上帧**，这是复位语义，不是正常收包错误的处理方式；系统须丢弃所有在途数据。两个 bank 的旧 RAM 字节不会在复位后泄漏。IFG 连续性检查按复位周期分段。

输出格式：

- 7×55 前导码 + D5 SFD；MAC header 14 字节，EtherType=0800。
- IPv4 固定 20 字节、IHL=5、DSCP/ECN=0、ID=0、DF=1/MF=0/offset=0、TTL=64、protocol=17；total length=payload+28，按网络序生成 header checksum。
- UDP 8 字节，length=payload+8，checksum=0000（IPv4 下表示未生成 UDP checksum）。
- MAC header 到 payload/padding 至少 60 字节，不含 FCS；padding 全 0，不改变 IP/UDP 长度。
- reflected CRC32：初值 FFFFFFFF、多项式 EDB88320、最终取反；覆盖 MAC header 至 padding，FCS 低字节先发，前导码/SFD 不参与。
- 排队有完整包时 IFG 恰为 12 个 `gmii_tx_en=0` 周期；缺包时允许更长。

## 实际执行与证据

工具为 `E:/ModelsimSE/win64` 的 ModelSim SE-64 10.1c（2012.07）；RTL 单独以 Verilog 编译，testbench 以 SystemVerilog 编译。Python 使用本机 Python 3.12 标准库，不依赖网络包或 DUT 的 CRC 函数。

复现命令（在上述工作树执行）：

```powershell
./fpga/scripts/sim_udp_ethernet.ps1 -Seed 1729 -RxTimeoutCycles 32
./fpga/scripts/sim_udp_ethernet.ps1 -Seed 20260921 -RxTimeoutCycles 64
```

每次运行创建新目录，保留 compile_rtl.log、compile_tb.log、simulation.log、transcript.log、gmii_trace.csv、python_check.log、check_result.json、run_result.json 和 work 仿真库。未清除旧运行证据。PowerShell 的 Select-String 均显式使用 -Path/-Pattern。

| 最终运行目录（fpga/build/udp_ethernet 下） | Seed / Timeout | 时钟数 | 完整帧 | error | 收发重叠周期 | start 背压周期 |
| --- | --- | ---: | ---: | ---: | ---: | ---: |
| sim_20260921_224929_341 | 1729 / 32 | 73795 | 47 | 6 | 26753 | 3047 |
| sim_20260921_224933_747 | 20260921 / 64 | 73345 | 47 | 6 | 27421 | 1921 |

两次均出现 UDP_ETH_PASS、ETHERNET_PYTHON_PASS、UDP_ETHERNET_SIM_PASS，外部进程退出为 0。ModelSim 对命令行 -do 中 onerror/onbreak 提示其用于 macro 的普通 Warning；没有编译 Error/Fatal。入口同时核对退出码、明确 PASS、失败标记及 Python 结果，不将退出 0 单独当作通过。

每组覆盖：

- 1、2、17、18、19、65、1463、1464 字节边界，以及 16 个随机长度包；跨最小帧 padding 边界。
- 随机源 valid 空泡、跨包 start 持续背压、传输期间改变元数据，逐包验证 start 时锁存的值。
- 0、1465、65535 三种非法长度，零发帧；无首字节、缺末尾、另一 bank 发送时超时共 3 次。
- 截止时钟载荷握手成功，以及首次握手后重启计时；各 2 次 deadline handshake。
- 一个接收末字节与另一个 bank 的末 FCS 同周期，两个所有权同时更新且顺序正确。
- 接收中复位 1 次；发送中复位 1 次同时清空排队包 1 个；复位后恢复新包。
- 16 个 1464 字节饱和连续包，所有 15 个起始间隔均为 1530 时钟，IFG 均为 12。

Python 按每周期真实 ready/start/valid 重建接收包与队列，核验所有 GMII 字节、busy、done、error、超时边界、队列占用、包间间隔和复位例外。FCS 用 zlib.crc32 与 little-endian struct.pack 独立计算；IPv4 checksum 用网络序 16 位求和独立核验。另对前导码、MAC、IP、UDP、载荷、FCS 和 padding 做 7 次故意破坏检查，部分重算合法 FCS，确认检查器仍会拒绝错误内容。

已验证 RTL SHA256：`700A88BF929784335D517B776D236E1F1AE84074184804739DF348EDEF67FFE4`。各运行的 run_result.json 保存四个源文件的 SHA256；check_result.json 保存逐帧时间、长度及 GMII trace SHA256。

## 周期吞吐

最大包的实际线上周期为 `8 + 14 + 20 + 8 + 1464 + 4 = 1518`；加 12 周期 IFG 后，稳态每包 **1530** 周期，而不是简单叠加接收和发送时间。

| 指标 | 两次仿真实测周期推导结果 |
| --- | ---: |
| 125 MHz 下 UDP 有效载荷 | 1464×125000000/1530 = **119.607843 MB/s** |
| 假设每包 PRAW 头 64 B + RAW 1400 B 的图像等效速率 | 1400×125000000/1530 = **114.379085 MB/s** |
| 16 包从首次 start 握手到末包末 FCS，含初始填充 | **25934 周期** |
| 上述包含初始填充的 UDP 平均速率 | **112.901982 MB/s** |
| RAW1920×1080×30 的净图像需求 | **62.208 MB/s** |

这些数值证明双缓存后端在该无停顿输入测试中具备超过 RAW1080p30 的周期预算；RAW1400 数值是对实际周期的应用负载折算，未在本独立回归中发送真实视频或验证完整 PRAW 帧。不能据此标注网络完整帧率、OV5640 真 1080p30、PC 接收、DDR 混合读写、功耗、RGMII 时序或板卡验收已通过。

本轮未运行 PDS 综合/布局布线/静态时序，未测 RAM 映射或 Fmax。主 agent 的 PRAW/subsystem/整帧集成测试属于独立证据，由其维护；本报告不代替其结论。

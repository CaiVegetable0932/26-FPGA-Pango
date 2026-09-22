# MINI 经拓展坞网口：首次实板连接检查

日期：2026-09-22。通信开发分支 `codex/fpga-mcu-praw-protocol`，候选提交 `5915f973`。

> 本文下方“首次检查/尚未安装”保留为当时的历史记录，不代表最新状态。后续用户明确允许安装后，官方 CP210x 11.6.0.420 已安装为 oem224.inf，设备现为 COM15、状态 OK。用户另行批准本轮 XT25F128 整片擦除/固化，e51d3cc9c9ee 候选已完成写入与回读校验；但冷启动后串口无应答、网口 Disconnected，尚未跑通。最新诊断见 [冷启动修正记录](../../fpga/reports/comms_cold_boot_20260922.md)。没有修改网卡 IP、路由或防火墙。

后续状态更正：以下为最初预检的历史记录。驱动后来经用户授权安装，6abc候选已完成冷启动及真实UDP合成帧接收；当前结果与缺包限制见[以太网实测结果](comms_ethernet_20260922/README.md)。不能把下方“尚未安装/未烧录”当作当前状态。

## 已执行及实际结果

- Windows 枚举到 ASIX USB to Gigabit Ethernet Family Adapter，接口“以太网”，ifIndex 16，MAC `20-7B-D2-C0-29-96`，USB `VID_0B95&PID_1790`。状态 Up，协商速率 1 Gbps。
- 当前 IPv4 `169.254.81.186/16`，状态 Preferred，自动链路本地地址。本轮没有改 IP、路由、驱动、网卡属性或防火墙。
- 在该地址 UDP 50000 端口成功绑定并被动监听 10 秒：UDP 0 包、PRAW magic 0 包、载荷 0 字节；同一窗口网卡 ReceivedBytes 增量 0、接收错误增量 0。没有发送启动配置，没有保存视频或图像。
- 首次 USB 枚举到 FTDI `VID_0403&PID_6010`（含 COM13/COM14），当时没有 CP2102。用户接线后新增 `USB\VID_10C4&PID_EA60\0001`，但状态 Error、Problem Code 28 / CM_PROB_FAILED_INSTALL、Problem Status 0xC0000490，没有驱动 INF、版本或服务，没有生成可用 COM 口。FTDI 虚拟 COM 不能未经核对就当作板载 UART 使用；未打开这些串口。
- 原生 PDS 只读 JTAG 探测识别 PG2L100H，ID `0x00602899`。配置 done=1、pll_lock=1、init_complete=1；状态 `0x081ffca0`，over_temp=1。CRC/ID 错误位为 0。状态寄存器不能证明当前配置就是通信候选，也不是温度数值测量。
- JTAG 工作目录和日志见 [只读探测](../../fpga/build/network_preflight_20260922_1256/probe.log)。本次启动的 JTAG 服务已停止，未关闭用户 PDS 窗口；未关联位流、擦除、下载、复位或操作 Flash/eFuse。

## 结论与继续条件

物理网口已建立千兆链路；**尚未完成 PRAW 数据链路验收**。启动 UART 不可用，未能下发明确目的 MAC/IP/端口，因此“没有收到包”不能直接归因于 RTL、网线或拓展坞故障，也不证明防火墙是原因。

通信候选不会上电自动发包，需要板载 USB-UART/CP2102 可用后下发专用 0x70 配置。当前线已接入，具体阻塞是驱动未安装，不再要求用户重复接线。它是 TX-only，不实现 ARP/ping；不使用 ping 作为此次验收。

待驱动安装且设备正常后，重新枚举并绑定实际串口、核对镜像和板卡状态，再配置单播并验证分片 CRC、完整帧、序号及丢包。若需替换 Flash，先核对擦除范围、恢复镜像和当前温度/告警情况；既往整片擦除授权不在本轮被直接套用。通信候选不含 HDMI，烧入后不能期待保留原镜像 HDMI 画面。

over_temp=1 原样保留，不根据既往“告警可能不准确”就当作已经解除，也不把它解释成已测得危险温度。后续烧录/持续负载前需复核实际状态。

本轮没有烧录，没有实测视频上传，没有修改系统网络设置。当前只能记录物理链路已建立及上述阻塞，不能报告网络视频收发通过。

## 驱动准备（尚未安装）

已从 [Silicon Labs 官方 CP210x VCP 页面](https://www.silabs.com/software-and-tools/usb-to-uart-bridge-vcp-drivers)所对应的官方软件地址取得 `CP210x_Universal_Windows_Driver.zip`，暂存在 `host/build/cp210x_driver_20260922/`。下载及解包没有执行安装程序、bat 或 reg 文件。

ZIP SHA256：`CE40EB9CDB52726E98986E03ED506E17AA5AA771CC0FF3E9C376BE399E07F992`。
INF DriverVer 为 08/14/2026,11.6.0.420，明确包含 VID_10C4&PID_EA60。
`silabser.cat` 的 Authenticode 状态 Valid，签名方 Microsoft Windows Hardware Compatibility Publisher；x64 `silabser.sys` 状态 Valid，签名方 Silicon Laboratories Inc.。其它架构 SYS 签名也为 Valid，但本机安装仅需匹配架构。

已向用户请求这项必要系统驱动变更的确认，尚未运行驱动安装或写入系统驱动库；不会关闭签名检查或执行包内额外注册表调整。

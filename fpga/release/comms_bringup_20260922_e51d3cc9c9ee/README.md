# PG2L100H MINI 通信联调候选

**合成测试流；不是摄像头/HDMI 镜像。未执行烧录或实板验证。**

目标：PG2L100H-6FBG676，100K MINI；工具 PDS 2022.2-SP6.4 build 146967。
构建/限制详情见[离线报告](../../reports/comms_board_candidate_20260922.md)，命令及线格式见[联调方案](../../../output/FPGA通信上板联调方案.md)。

## 文件核对

`mini_comms_bringup.sbit` 为原生位流，`mini_comms_bringup.sfc` 为原生 XT25F128/SPI-X1 格式转换结果。两者均 3,791,112 字节，SHA256 相同：

`e51d3cc9c9ee85814fa7525621d9779b5a5679300f6e9933ee6d054dd7da9cbf`

Flash 起始地址 0，opcode 11。`manifest.json` 记录转换运行时与文件哈希，`source_manifest.json` 记录 28 个构建输入，`audit.json` 与 `timing.rtr` 是最终位流对应的离线审计证据。工具生成成功不是 Flash 写入/回读/冷启动通过。

## 启动行为

- 复位后初始化 PHY；未完成 UART 显式配置或未建立 1000/full 链路时不发送 UDP。
- UART 是板载 CP2102：FPGA RX B24、TX C24，115200/8N1。**这不是已确认的 MCU 扩展脚接线。** 先发送专用 0x70 启动配置，完整 ACK 后转入原 MCU 二进制协议。启动命令必须使用本次新 epoch 和实际单播对端地址。
- 配置成功后输出 1920×1080 的棋盘/灰度合成字节，TEST 描述符为 0x54534554；并非 OV5640 Bayer 数据，30 fps 是设计预算而非实测。
- 不支持 ARP/ping/DHCP/网络 RX；重置才能改配置。链路或传输故障阻止新帧；PC 不得把不完整帧补齐冒充完整数据。
- LED0 心跳，LED1 PHY 配置成功，LED2 1000/full，LED3 已接受启动配置，LED4 故障；均为低电平点亮。LED 不是相机或 PC 收到画面的证明。
- **此镜像没有 HDMI 输出。** 如要恢复摄像头预览，应使用原摄像头恢复镜像；本候选不覆盖其仓库文件。

离线命令生成器为 `fpga/scripts/prepare_comms_boot.py`，要求 `--acknowledge-synthetic`、双方 MAC/IP 和 `--out fpga/...`；只生成待审查 hex/JSON，不自动发送，不修改 PC 网卡或防火墙。

## 上板前必须知道

慢/快角 setup/hold/recovery/removal 已在当前预算下闭合，最小外部 RGMII 余量 0.103 ns；PCB 偏斜与 PHY 延迟预算尚无实测支持，16 mA FAST 的信号完整性需验证。

原生 GPLL 在 ModelSim10.1c 中有初始化除零诊断；1000 次周期/相位检查通过，但严格仿真为**未通过**，没有屏蔽告警。UART/MDIO 异步及慢输出 I/O delay 警告也保留在报告中。这是带已知限制的联调候选，不是零警告/生产就绪或整机功能通过版本。

后续仅在明确执行上板时，核对目标/Flash/镜像和恢复路径，再执行 Flash 写入、回读及彻底断电重启；每一步分别留证。本轮没有执行这些动作，也没有上传任何实测视频。

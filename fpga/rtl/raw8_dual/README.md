# RAW8 dual-output core

独立于已验证的 720p RGB565 / 合成 Ethernet 顶层。当前为核心实现，不是板级发布。

模块职责、接口门槛、仿真范围及未完成整合工作见 [实际报告](../../reports/raw8_dual_20260922.md)；存储/跨端语义见 [实施约定](../../../output/FPGA1080pRAW8双路实施增量.md)。所有端口的时钟域必须遵循模块首部注释，不能直接把 DVP 接到可背压的网口。

离线命令（仓库根目录）：

```powershell
./fpga/scripts/sim_raw8_dual.ps1
./fpga/scripts/sim_raw8_native.ps1
./fpga/scripts/build_raw8_network_core.ps1
node host/tests/test_pixels.cjs
```

核心 PDS 项目只编译/综合 network endpoint，没有板级引脚约束或位流命令。两个新 FIFO 由安装版 IP Compiler 原生生成；不得手改生成 RTL 规避告警。没有加入测试源选择器，也不使用旧 TEST 启动信息冒充摄像头描述符。

# MINI RAW8 双路整板工程

目标为 PG2L100H-6FBG676 / 100K MINI。J10/CAM1 单路 OV5640 RAW8，经三个 DDR 帧槽分别送到千兆网 PRAW 和 HDMI RAW 采样灰阶。HDMI 不是 ISP S1 或几何矫正结果；无合成测试源兜底。

## 原生构建

在本仓库根目录执行；所有日志、网表和路由数据库留在 `fpga/build/mini_raw8_dual/`，不会在 PDS/reference 中生成文件：

```powershell
./fpga/scripts/build_mini_raw8_dual.ps1 -Stage report_timing -EmitBitstream -LicenseFile '<本机许可证路径>'
```

脚本用安装的 PDS 2022.2-SP6.4 `tcl2prj` 生成 `.pds`，执行综合、映射、布线和 min/max STA；只有时序通过且构建输入未变化才允许生成位流。PDS 原生写回后仅调整 implementation 相对路径。已生成的 `.pds` 可直接由 PDS 打开，也可从 `.tcl` 在新克隆中重建。

## 离线验证与导出

```powershell
./fpga/scripts/sim_raw8_dual.ps1
./fpga/scripts/sim_raw8_board_core.ps1
./fpga/scripts/sim_mcu_protocol.ps1
./fpga/scripts/sim_raw8_rgmii_clock.ps1
./fpga/scripts/sim_raw8_gmii_cdc.ps1
./fpga/scripts/export_raw8_candidate.ps1 -Run '<本次 native_* 目录>' -Simulation '<本次 raw8_board_sim_* 目录>' -ClockSimulation '<本次 raw8_rgmii_clock_* 目录>' -BridgeSimulation '<本次 raw8_gmii_cdc_* 目录>' -CfgRuntime '<项目内已有 XT25F128 支持的配置工具副本>'
```

导出器重新核对最终路由 STA、源码哈希、六帧完整核心仿真和配置晚到时的旧帧拒绝测试，再离线生成 `.sfc`。它不会探测 JTAG、连接串口、擦除 Flash、修改官方工具或操作网卡。不能把中间 `.sbit` 单独当作完整发布。

本工程复用 `fpga/ip/ddr3_controller`、`hdmi_tx_pll`、`comms_pll` 及原生 `raw8_word_cdc`/`raw8_capture_cdc`，正式依赖均在开发区。RGMII 独立 ETH125 经原生 FIFO 整包交接，不直接使用 DDR 反馈时钟。HMIC UI 地址是 32-bit 列地址，256-bit beat 前进 8 列；写端无 B 通道，读端无 RREADY，不能按其他平台 AXI 示例替换。

## 验收边界

当前发布状态和实跑结果以 [候选报告](../../reports/raw8_board_candidate_20260922.md) 为准。首次上板仍需独立完成 Flash 回读校验、冷启动、真实摄像头来源、DVP/HDMI/网口外部时序、双路完整帧率及稳定性验证。Bayer 物理相位和 HDMI 帧源身份尚未验证，严格同帧精度测试关闭。

启动协议与 PC 预览步骤见 [host 说明](../../../host/docs/RAW8双路候选启动与预览.md)。每次冷启动生成新 epoch，使用 RAW8 命令 0x71，不能复用旧 TEST 配置。

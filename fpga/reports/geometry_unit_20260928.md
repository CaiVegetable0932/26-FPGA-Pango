# FPGA 几何矫正单元阶段记录（2026-09-28）

- 开发分支：`codex/fpga-geometry-correction`，从主线已验证视频版本切出。未改 `mini_raw8_dual`、PDS 工程、参考资料或板上 Flash。
- 新增：仿射＋`k1/k2/p1/p2` 逆映射、RGB888 双线性、参数影子/帧边界提交、MCU V1 环境角度事件留口及会话失效保护；独立浮点/定点参考模型。
- 仿真：`fpga/scripts/sim_geometry.ps1` 的 ModelSim `GEOMETRY_PASS`；参考模型 `GEOMETRY_REFERENCE_PASS`。在 8 个演示角度、每个 300 个随机 1080p 坐标的参数集上，定点与浮点的最大坐标差约 0.018680 pixel（不是全工作域最坏值）。测试含末行末列、四畸变项、仿射旋转、越界掩码、RGB 插值、配置接受/拒绝、会话切换后角度失效、旧会话事件拦截、同拍写入延至下一帧。最近一次完整日志在 `fpga/build/geometry_sim_20260928_161403_813/`。
- 未完成：真实标定参数 UART 下发/读回、S1 RGB888 去马赛克、图块缓存与随机 DDR 访存、输出帧池、HDMI 接入、MCU 独立串口/坐标轴/曝光时刻同步、PDS 综合/时序/位流以及板测。不能把本单元仿真结果称为 1080p30 矫正视频已跑通。
- 参考核对：只读查阅安装版 PDS 2022.2-SP6.4 `Simulation_User_Guide.pdf` 中 ModelSim 调用章节及 MINI V1.3 板卡手册；未向官方或 `reference/` 写入。

# MCU 设备端开发区

这里开发云台、电机、光照控制等设备端固件。F4 龙门架工程位于 `firmware/longmenjia`，F1 云台工程位于 `firmware/yuntai`；原 `stm32`、`yuntai` 目录已移走，源码、依赖、参考资料和历史构建记录全部保留。

| 目录 | 内容 |
| --- | --- |
| `firmware/` | MCU 工程、云台与电机控制、光照控制、外设驱动和设备端通信 |
| `tests/` | 固件、驱动、设备端通信与板级测试 |
| `config/` | MCU 板卡、外设与固件参数配置 |
| `scripts/` | 固件构建、烧录及设备端测试脚本 |
| `data/` | MCU 板级调试数据与设备端测试记录 |
| `build/` | 固件构建结果和中间文件 |
| `reports/` | MCU 固件及板级验证报告 |
| `release/` | 固件发布产物、配置与版本记录 |

需求、接口设计和验收计划写在 [output](../output/README.md)；固件及设备端测试产物直接写入本目录。PC 界面、通信客户端、测试自动化、图像采集、测评数据和报告归独立的 [host](../host/README.md)，原 `mcu/host/` 已取消。FPGA 实现归 [fpga](../fpga/README.md)。

本区脚本按自身位置解析路径。所有子目录均受当前 Git 规则管理；`.gitkeep` 只用于保留空目录，可在添加实际文件后移除。

## 当前视频架构中的职责

主视频采用OV5640直接输入PG2L100H，S0 RAW8经板载千兆网到PC，FPGA结果经HDMI回采，见[跨端回传方案](../output/OV5640_RAW8千兆网与HDMI双路回传方案.md)。MCU不转发像素，不参与实时畸变矫正；继续负责光照、云台、电机和设备端反馈。

F1 直接用两只舵机的位置反馈生成 pitch/yaw（2026-10-20 起不再使用 MPU6050 姿态融合），再经 F4 独立双向 UART 回传 FPGA。PC 经 F4 下发运动，FPGA 仅查询、同步和接收状态。用于证明 FPGA 独立处理的板载旁路/矫正按键直接作用于 FPGA 逻辑。参见 [接口补充](../output/MCU_POSE_V2接口实现补充.md)、[板卡配置](config/board_interfaces.md) 和 [软件验证记录](reports/MCU_POSE_V2软件验证.md)。

在本目录运行：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Board yuntai -Configuration Release
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/build.ps1 -Board longmenjia -Configuration Release
powershell -NoProfile -ExecutionPolicy Bypass -File scripts/test.ps1
```

构建输出归 `build/f1`、`build/f4`，脚本仍接受 `-Board f1/f4` 别名；原产物作为历史文件保留，不证明新版已上板。新增全系统紧急 STOP 接口已取消，原驱动的 `stop n` 和本地故障处理保留。原同名交接文档保留于本目录，权威设计同步放在 `output/`。源码、依赖、配置、测试与构建结果按本地仓库规则管理；本次未导入云端根目录忽略规则，本地仍只排除根目录 `reference/` 和 `PDS/`。

2026-10-11 本机从 `origin/codex/mcu-test-system` 的 `adf340927` 导入 MCU_POSE_V2，旧本地交接稿保存在 `build/upstream-sync-20261011-adf340927/local-before-sync/`。本机 STM32CubeCLT 构建可给脚本传 `-ToolchainRoot 'E:\STM32CubeCLT\STM32CubeCLT_1.18.0'`；`-BuildRoot` 可指定 `mcu/build` 内独立目录，避免覆盖云端历史构建。原生测试可用 `-Compiler 'D:\C Tool Chains\mingw64\bin\gcc.exe'`。本机验证范围见 [同步记录](reports/云端MCU_POSE_V2同步记录_20261011.md)，后续开发按 [同步实施计划](../output/MCU_POSE_V2云端同步实施计划.md) 执行。

旧[串口修改方案](../output/MCU对接现有FPGA串口的修改方案.md)及[链路示意图](../output/MCU对FPGA通信方案.png)已归档到 `output/`。配置实体见 `config/machine_config.json`；每个构建目录的 `manifest.json` 记录配置、源码与固件 SHA-256。运行时行程、零位与偏置通过 GET_CONFIG 按启动代次和配置版本另行保存。


2026-10-21 已安全同步 `origin/codex/mcu-test-system` 的 `1db773613`（基线 `adf340927`），保留本地工具链适配。F1 使用舵机编码器位置反馈，F4 对外 capability 清除 IMU 融合位、`imu_type=0`；GET_CONFIG 角轴 `state_source=2`，STATE 单轴 `angle_source=1`（两轴有效打包为 0x05）。完整字节约定、上游文档修正与本机验证见 [同步记录](reports/编码器角度闭环同步记录_20261021.md)。本次不烧录、不宣称实板验证。

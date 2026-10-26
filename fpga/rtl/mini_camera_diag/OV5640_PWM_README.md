# OV5640 150 Hz PWM 固定测评模式

实现入口是 `vendor/camera/camera.v` 与 `ov5640_control.v`。本功能仅服务 MINI 单路 1280×720 RGB565 诊断，不代表正式 RAW8/1080p30 或光学防条纹验收。开发依据是[专项交接](../../../output/OV5640_150Hz_PWM照明防条纹专项优化交接.md)，验证记录见[本轮报告](../../reports/ov5640_pwm_20261012.md)。

## 初始化与固定参数

复位 → 原 244 项写表 → 36 项身份/配置快照 → 可选固定组 16 项写入及逐项回读 → 再读 36 项检查整组 → 采集就绪 → PCLK 域丢弃 10 个按尺寸计数完成的预热帧 → 允许 FIFO 写入。

默认 `Top.CAMERA_FIXED_MODE=0`，仍使用厂商自动诊断配置，但新增 ID=`0x5640` 和寄存器可读性门控。固定模式为 1 时必须配置下面各项；零曝光或零 HTS/VTS 会拒绝开放采集。

| Top 参数 | 含义 |
| --- | --- |
| `CAMERA_EXPOSURE` | 20 位 1/16 行曝光编码；按实测输入计算，禁止用毫秒标签代替 |
| `CAMERA_EXPECT_HTS/VTS` | 核验模式的 16 位值，必须与初始/最终回读一致 |
| `CAMERA_GAIN` | 10 位增益，允许 `0x010`～`0x3ff`，实际响应另测 |
| `CAMERA_WB_R/G/B` | 显式 12 位固定 RGB 增益；默认 `0x400` 是可重复单位增益候选，未色彩标定 |
| `CAMERA_VTS_MARGIN` | 默认 4 行工程余量，须核对本模式实际要求；不自动扩帧 |

固定组保留 `3503`、`3a00`、曝光/增益/AWB 高字节的无关位，设手动 AEC/AGC，关夜间、清 `350c/350d`，写完整曝光/增益；先冻结 AWB，再写显式 RGB 增益。无需依赖自动 AWB 曾经收敛到什么颜色。任何写、逐项校验或最终快照错误都保持采集关闭，不发布 version=1，复位后重试。

确认测量后，在 `Top.v` 的参数默认值或经过核验的工程参数覆盖中填入这些值，再由 `fpga/scripts/build_mini_camera_diag.ps1` 重建。工程 `.pds` 必须通过 `create_mini_camera_diag.tcl`/现有构建脚本生成，本轮已经同步两个新增模块。构建脚本不自动下载；现有硬件放行条件继续适用。

## 查询与证据端口

`camera` 的查询和状态端口工作在 `clk` 控制域：

- `query_start` 单周期脉冲，地址为 `query_addr`；仅 `query_ready=1` 接受，忙时输出 `query_rejected`，无排队。没有外部原始写端口。
- `query_done` 单周期返回完成；`query_status=0` 成功、1 NACK、2 总线超时/占用。错误时 `query_value` 不能当作有效回读。
- `config_fault`：0 无启动错误、1 NACK、2 超时/占用、3 回读不符、4 芯片 ID、5 参数/模式不符；`fault_addr` 指出错误寄存器。初始化失败也锁存并保持采集关闭。
- `config_version`：0 为原自动配置，1 为整组校验成功的固定配置。它是本次复位内的本地状态，不是跨复位唯一 ID，也不是已经接入网络帧元数据的版本。
- `snapshot_valid/addr/value/cycle` 逐项输出成功回读，cycle 为 32 位控制时钟计数，回绕后按模差处理。多个寄存器读取不是同帧原子快照。
- `row_ticks/frame_ticks/source_frames` 用控制时钟同步 HREF/VSYNC 边沿；`row_valid/frame_valid` 表示已有间隔样本，保持至复位。两个相邻有效 HREF 起点之间的间隔才更新 row_ticks，不把垂直消隐当作普通行。计数有同步量化误差和回绕边界，不能证明完整帧率或真实行关系。

**当前 Top 没有 PC 查询桥；以上查询/快照/节拍端口在 Top 中明确悬空输出、禁用输入，未使用的观察逻辑可能被综合裁剪。** 新增 SCCB 读取和启动校验实际接入初始化路径；读取状态到 PC/片上调试仍需后续接口集成，不分配 UART 报文编号，也不混用 MCU_POSE_V2。

运行期仅查询。切换固定参数需复位重新初始化；没有宣称已有 DMA 停机、FIFO/帧池清理、group launch 下一帧生效或运行期无缝切换。预热采用现有尺寸计数，不替代短行/坏帧合法性检测。

## 曝光计算与回归

填写 `fpga/config/ov5640_pwm_measurements.template.json` 中 XCLK、回读和光学频率证据。缺少 XCLK/回读则计算器拒绝输出；缺少实测行输入时，仅输出 `pll_prediction_unverified` 候选，始终保留 `hardware_verified=false/optical_verified=false`。HREF 行间隔必须先核对裁剪/抽样与内部行时间的关系，不能直接冒充内部行时间。

```powershell
python fpga/model/ov5640_pwm_exposure.py --input fpga/config/实际测量.json --output fpga/build/实际曝光候选.json
python -m unittest discover -s fpga/sim -p test_ov5640_pwm_exposure.py -v
./fpga/scripts/sim_ov5640_pwm.ps1 -Simulator Icarus -IcarusHome '本机便携 Icarus 的 bin 目录'
python fpga/scripts/audit_ov5640_pwm.py --output fpga/build/摄像头工程审计.json
```

仿真也支持 `-Simulator ModelSim -ModelSimHome ...`。本机 ModelSim 编译成功，执行因许可证不可用而未通过，最终回归使用隔离便携 Icarus；工具来源与哈希保存在 `fpga/build/ov5640_pwm_20261012/tools/sources.json`，没有运行系统安装器。

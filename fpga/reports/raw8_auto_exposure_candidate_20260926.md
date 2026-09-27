# 2026-09-26 OV5640 自动曝光/增益试验候选（已固化，待冷启动）

## 目的与变更边界

- 上一固化版 `18a5a3adee5e` 的同场景网口 RAW8 中位数约 32～33；HDMI 灰度中位数约 147，但暗部仍偏暗。当前 FPGA 增强曲线、HDMI 时序、网络 S0 数据格式均不改动，以便隔离摄像头自动曝光的实际效果。上一镜像 SFC 已在发布目录备份，SHA-256 为 `18a5a3adee5e2771a2ec9206db3d4e604495c02104b334c656d779bc7e642c92`。
- 仅在 `fpga/rtl/raw8_dual/ov5640_raw8_profile.v` 中把 `0x3503` 改为 `0x00`，由传感器控制 AEC/AGC；将厂商 720p 基线的 0x28～0x30 偏暗目标覆盖为 OV5640 数据手册默认 0x68～0x78 区间。设置 `0x3A00=0x78` 禁止夜景扩帧，50/60 Hz 最大曝光均为 1104 行（低于 1120 行 VTS），增益上限为代码 0x40（4×），不改变目标 1080p30 栅格。84 MHz/2500 HTS 对应 33,600 行/秒，50/60 Hz 防闪烁步长分别为 336/280 行；相关寄存器已重配。
- 移除配置表中手动曝光/增益以及额外 VTS 的动态输出寄存器 `0x3500～0x3502`、`0x350A～0x350D`；启动状态机会在开流后静态回读整张配置表，自动模式下这些值会变化，保留静态比较会误判启动失败。新增仿真断言禁止它们重返只读回验表，并核对曝光/增益上限及 30 fps 时钟配置。未修改根目录 `reference/` 或 PDS 官方文档。

## 资料依据

- 只读查阅 `D:/XDU/concept/26-FPGA-Pango/reference/盘古100K200K MINI开发板/4_IC_datasheet/OV5640/OV5640_DataSheet.pdf`：PDF 第 44～50、111～113 页定义 AEC/AGC 使能、稳定亮度范围、夜景降帧、50/60 Hz 曝光上限与增益 ceiling。DVP 模组应用指南同目录 PDF 第 44、58 页给出曝光行数与增益代码（16=1×），并指出夜景模式会插入虚拟行。
- 只读查阅 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf` 第 166～167 页的原生 Shell 流程；工程目标仍为 100K MINI 的 PG2L100H-6FBG676。

## 离线验证与发布状态

- 完整 RAW8 RTL 回归：`fpga/build/raw8_dual_sim_20260926_143509_572/`，包含 SCCB 配置/回读及双路像素和 host 解包，已通过。
- 原生 FIFO/三时钟板级六帧、晚启动 epoch 五帧回归：`fpga/build/raw8_board_sim_20260926_143616_839/`，均通过；这些模型不代表真实传感器内部 AEC 行为。
- PDS 原生实现和位流：`fpga/build/mini_raw8_dual/native_20260926_143618_870/`，272 项构建输入哈希审计通过，`Design Summary: All Constraints Met`；ETH125→PHY_SAMPLE min/max 检查仍覆盖各五端点。报告仍有 SCL/SDA、HREF/VSYNC 等异步/控制端口的 `Timing-4086/4087` 未约束警告，故这个总结不等于真实外部 DVP 时序已验收。发布目录 `fpga/release/raw8_dual_20260926_902830f4725d/` 包含 SBIT/SFC，二者 SHA-256 均为 `902830f4725d1a9635e68e3976d9ad8bdeb74eecbfef135d3435b4ff20c8731e`。
- 用户已授权本候选整片擦写。首次烧录日志 `fpga/build/raw8_flash_program_20260926_145727/program.log` 显示整片擦除和写入成功，但紧随其后的校验在 100% 时同时报出比较失败和 `JtagServer-0014` USB Cable II 传输错误；首次独立 500 KHz 复核 `fpga/build/raw8_flash_reverify_20260926_150455/verify.log` 也失败。因此未将这些尝试当作成功验证。
- 用户重新插拔 JTAG 后，`fpga/build/raw8_flash_probe_20260926_151106/probe.log` 重新识别 PG2L100H ID `0x00602899` 并扫描外部 Flash。随后 **未再次擦写**，以 500 KHz 对同一 SFC 做完整只读校验：`fpga/build/raw8_flash_reverify_20260926_151144/verify.log` 记录 `COMMAND[Verify Outer Flash] execute successfully`、`CAMERA_FLASH_READONLY_VERIFY_COMPLETED` 且无 `E:` 错误。由此确认首次写入的 Flash 内容与候选镜像一致；上一次失败是 JTAG 校验通信故障，不需要额外擦写。
- Flash 校验刚通过、尚未冷启动时，发布清单状态为 `programmed=true`、`flash_verified=true`、`cold_boot_verified=false`；当时不将其称为板级图像验证通过。随后用户执行了彻底断电再上电，结果记录于下节。PDS 状态读取仍报告 `over_temp=1`，该位未被屏蔽；它不构成温度安全性的证明。

## 冷启动后板测（用户确认已彻底断电再上电）

- 用户确认冷启动，观察到 LED0 闪烁、LED4 熄灭。串口会话前 Inspect 返回 `MCU endpoint not ready`，未将其当作镜像故障；本次一次性 epoch `161753457176649748` 位于 `host/config/raw8-ae-cold-20260926_152956/`。通过 COM15 下发 RAW8 Boot 后得到 CRC/序号有效且 result=0 的 ACK，证据 `host/reports/raw8-ae-cold-20260926_152956/boot.json`。随后 Inspect 见 sensor_ready/frame_published，几何为 1080 行、每行 1920 像素，未见 HDMI 下溢、帧池、DDR 桥或网络聚合故障；证据 `postboot.json`。这些只能证明配置及视频链路运行，未直接读取传感器动态曝光/增益寄存器。
- 启动期间网口 15 秒窗口收到 379 个完整 RAW8 帧，并保存 3 个原始 1920×1080 帧；证据 `host/reports/hardware_unverified-20260926T073033Z-3a1688b7/receiver.json` 与对应 `host/data/`。该窗口含串口配置前等待，不作为稳态帧率。启动后再开 10 秒接收窗口，得到 299 个完整帧，即约 29.9 完整帧/秒，帧 ID 范围内无未观测号；证据 `host/reports/hardware_unverified-20260926T073819Z-80ec0258/receiver.json`。两个有限窗口均在起始处记录 1 帧 timeout、停止处 1 帧 stopped，故接收程序严格返回非零；不能宣称零丢帧长时验收。
- Hagibis 唯一物理设备验证后采集 1920×1080 MJPEG 原流、解码 RGB/PNG 和预览视频，目录 `host/data/hdmi_diag_20260926_153316_677876/`。首帧下半部短暂呈绿色，故以保存流第 2.5 秒派生帧 `frame_2p5s_derived.png` 审校：完整场景轮廓可见，派生 PNG SHA-256 `79661b5d65e12ed9812a1f7174251fe505b5a2abb573a17738c62545e29517a2`。HDMI 采集为有损 MJPEG 且无板端帧 ID，不声称与网口 S0 逐帧配对或 30 fps HDMI 无丢帧。
- 对照**实际上一固件** `18a5a3adee5e` 的 `host/data/hdmi_diag_20260926_140918_369613/frame_2p5s_derived.png`，本次 HDMI 灰度均值/中位数约 `114.53/121`，上一版 `127.63/147`；下半部均值约 `48.94` 对 `49.29`，近白像素比例约 `12.05%` 对 `12.81%`。网口 S0 三帧均值约 `56.6～56.8`、中位数 `29`；上一固件采集约 `64.4～64.7`、`32～33`。两次不同时间采集，视角和光照未锁定，数值不能归因于 AEC 单一原因，但**本次自动曝光没有实现用户期待的整体/暗部提亮**；顶部灯条仍大片截白。是否自动曝光收敛到较低曝光仍需直接传感器读数或受控光照实验，不能据此断定。
- 发布清单据用户冷启动确认及板端响应更新为 `programmed=true`、`flash_verified=true`、`cold_boot_verified=true`；`camera_source_verified=false` 继续保留，因为本轮未做遮挡/恢复的来源挑战。PDS `over_temp=1` 状态位未屏蔽，未测得实际温度，也不把它视为安全证明。

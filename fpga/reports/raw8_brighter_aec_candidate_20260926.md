# 2026-09-26 OV5640 小幅提亮候选

## 变更与依据

- 在 FPGA 专属分支的 `ov5640_raw8_profile.v` 中，将 OV5640 自动曝光稳定区间的四个进入/退出阈值由 `0x68..0x78` 上移至 `0x70..0x80`；AGC 上限由 real-gain 代码 `0x0040`（4×）放宽至 `0x0050`（5×）。只改动摄像头配置和对应 SCCB 启动仿真断言，网口 RAW8 格式、HDMI 显示曲线和分帧逻辑不变。仍禁用夜景扩帧，50/60 Hz 最大曝光保留 1104 行，目标 1920×1080、30 fps。若动态曝光尚未达到旧上限，增益上限改动可能不发挥作用；不把预期亮度当作实测。
- 只读核对 `reference/盘古100K200K MINI开发板/4_IC_datasheet/OV5640/OV5640_DataSheet.pdf` 第 44～50、111～113 页：`0x3A0F/10/1B/1E` 控制平均亮度稳定区间，`0x3A18/19` 为增益上限，曝光优先于增益；增益提高可能增加噪声。只读核对 PDS 2022.2-SP6.4 官方 User Guide 第 166～167 页的原生命令行流程和 Fabric Configuration Guide 第 81、89～90 页的 JTAG 频率与 Flash 命令。官方目录及根参考资料未修改。

## 离线验证与发布

- RAW8 RTL 回归 `fpga/build/raw8_dual_sim_20260926_160350_914/` 通过，包含新 SCCB 参数断言、1080p 捕获和双路输出；原生 FIFO/三时钟板级回归 `fpga/build/raw8_board_sim_20260926_160343_738/` 正常与晚启动 epoch 均通过，并经过 host 解包。仿真不是 OV5640 实际 AEC 收敛证明。
- PDS 原生构建 `fpga/build/mini_raw8_dual/native_20260926_160634_843/` 完成 272 个构建输入哈希审计、布局布线与 min/max 时序，`Design Summary: All Constraints Met`。ETH125→PHY_SAMPLE 四组 setup/hold 余量为 `0.137/0.103/0.052/0.106 ns`，各有五个端点。SCL/SDA、HREF/VSYNC 等异步/控制端口仍有 `Timing-4086/4087` 未约束警告；不能声称外部 DVP 时序已全面验收。
- 从通过时序检查的同一布线数据库导出的 SBIT 经 PDS 原生 `cfg_gen_sfc` 转为 XT25F128 SPI-X1 SFC。离线发布目录 `fpga/release/raw8_dual_20260926_1f0c09ce8233/` 含两个 3,791,112 字节镜像，SHA-256 均为 `1f0c09ce82334727e2418e59d01725837b56c0401076f0a9bae653503990db9d`；转换日志在 `fpga/build/raw8_sfc_convert_20260926_162010/convert.log`。上一已验证镜像保留在 `fpga/release/raw8_dual_20260926_902830f4725d/`。
- 烧录前，用户单独授权本轮整片擦除 XT25F128、固化并回读校验。已用本项目专用释放脚本停止网页接收，核对新 SFC 与旧版恢复镜像哈希，且只读识别 PG2L100H ID `0x00602899`、外部 Flash 扫描成功；预检记录 `fpga/build/raw8_flash_probe_20260926_162318/probe.log`。PDS 状态位继续报 `over_temp=1`，未屏蔽，亦无实际温度测量。
- 首次以官方支持的 500 KHz 执行本轮整片擦写，日志 `fpga/build/raw8_flash_program_20260926_162413/program.log` 在**擦除进度约 25%**报 `JtagServer-0016` 读超时和 `Erase Outer Flash` 失败；PDS 未执行写入或校验。此时 Flash 可能部分擦除，旧镜像是否仍完整未知；**不得断电冷启动或声明烧录完成**。发布清单保持 `programmed=false`、`flash_verified=false`、`cold_boot_verified=false`。已请用户只重新插拔 JTAG USB，板卡保持上电，待重连后再做只读诊断并决定受控续写。

## 重连后的恢复与最终固化状态

- 用户确认仅重新插拔 JTAG USB，板卡持续上电。`fpga/build/raw8_flash_probe_20260926_162646/probe.log` 再次识别 PG2L100H 和外部 Flash。尝试 300 KHz 只读复核时，当前 USB Cable II 驱动明确列出的支持档位没有 300 KHz，命令在设频阶段拒绝，**未开始读取或写入**；相应脚本已限制为该烧录器实际支持的速率。
- 随后在 500 KHz 对旧镜像进行完整只读比较：`fpga/build/raw8_flash_old_verify_20260926_162915/verify.log` 已读至 100%，未有 `JtagServer` 错误，但比较失败，证实旧镜像内容已被中断的擦除改变。此时仍未让板卡断电。
- 使用同一授权继续在 500 KHz 重新整片擦除、写入新 SFC 并校验，原生日志 `fpga/build/raw8_flash_program_20260926_163122/program.log`：`Erase Outer Flash` / `Program Outer Flash` 均 `execute finish` 且对应 Tcl 命令 `successfully`，`Verify Outer Flash` `execute successfully`，`CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED` 出现，**无 `E:` 错误**。外层检查器曾错误地要求擦除/写入也打印 `execute successfully`，因此抛出误报；以原生命令日志为准。独立只读全镜像复核 `fpga/build/raw8_flash_reverify_20260926_163938/verify.log` 再次通过，记录 `CAMERA_FLASH_READONLY_VERIFY_COMPLETED` 且无错误。两份成功日志已复制到发布目录。
- 烧录刚完成时清单为 `programmed=true`、`flash_verified=true`、`cold_boot_verified=false`；当时旧固件仍在 FPGA 当前上电周期运行，没有把它的预览误当作新版。用户随后确认彻底断电再上电，新版实测见下节。

## 冷启动后双路视频复核

- 用户确认冷启动，LED0 闪烁、LED4 熄灭。新一次性配置 `host/config/raw8-brighter-cold-20260926_164934/` 使用 epoch `4839710493772049565`，COM15 RAW8 Boot ACK 的 CRC/序号/结果检查通过；证据 `host/reports/raw8-brighter-cold-20260926_164934/boot.json`。Inspect 报 sensor_ready、frame_published，连续帧几何 1080 行、每行 1920 像素，HDMI 无下溢，网口和帧池无故障；证据同目录 `inspect.json`。未直接读动态曝光寄存器，因此不能证明增益实际已达到 5× 上限。
- 本机网页预览 `http://127.0.0.1:8766/` 曾以每 150 帧归档，用于保存原始样本，运行 ID `web-hardware_unverified-20260926T085019Z-43d7e9f3`；观察时实时帧率约 30 fps、帧 ID 范围无未观测号。采样完成后用本项目安全释放脚本停止该接收器，以**零自动归档**重新开启同一硬件 epoch，现运行 ID `web-hardware_unverified-20260926T085639Z-4e321da1`，实时帧率观察值约 30.4 完整帧/秒、最近帧约 31 ms、无 Web 错误。后续瞬时值可变，不能当作长期无丢帧验收。
- Hagibis 唯一物理设备采集的 1920×1080 MJPEG/派生帧位于 `host/data/hdmi_diag_20260926_165432_599046/`；取保存流第 2.5 秒的 `frame_2p5s_derived.png`，SHA-256 `c44328bc74101b28942671fb8ffd99cc5475f9600b08047d233fbeae6292b630`，完整场景轮廓可见。与上一自动曝光候选 `host/data/hdmi_diag_20260926_153316_677876/frame_2p5s_derived.png` 对照，本次 HDMI 灰度均值约 `119.91` 对 `114.53`、中位数 `123` 对 `121`、下半部均值 `76.77` 对 `48.94`。但两次采集之间灯条及网格在画面中的位置明显改变，不能把这些差值全部归因于新的 AEC/AGC 参数；未做同帧 HDMI/网口配对或曝光寄存器读数。
- 新版网口 RAW8 早期归档样本均值约 `53～54`、中位数 `26～28`、下半部均值 `20～22`；上一自动曝光候选约 `56.6～56.8`、`29`、`17.9～18.0`。后期样本画面构图进一步变化、灯条移到右下，整体均值降至约 `22`，再次说明不能用非受控场景的全画面均值证明提亮幅度。用户可在持续预览中直接判断暗部和噪声；若需严格对照，应固定镜头/光照并取相同区域。
- 清单现为 `programmed=true`、`flash_verified=true`、`cold_boot_verified=true`。`camera_source_verified=false` 仍保留：本轮未执行遮挡/恢复来源挑战；`external_dvp_timing_verified=false` 也仍保留。未再次擦写或修改官方/参考目录。

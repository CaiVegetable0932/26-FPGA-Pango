# 网口 RAW8 与 HDMI 亮度对齐候选（2026-09-26）

## 诊断与实现

- 用户网页截图左侧为旧描述符 `0x38574152`/版本 1 的 S0 原始 Bayer RAW8，右侧为采集卡接收的 FPGA HDMI 增强灰阶。实时 API 曾读到连续帧号、30.4 完整帧/秒及每帧 2,073,600 字节；暗亮差异来自板侧 HDMI 独有的同相位中值/明暗曲线，而不是 Web 缓存、丢包或 host RAW 灰阶暗中调色。
- 新候选保留 DDR 内原始传感器 RAW8，在网口封包前加入与 HDMI 相同的 `raw8_display_enhance`；传输仍为 1920×1080、每像素 8 位的 Bayer RAW8、PRAW V1。新描述符 `0x484E4552`（RENH）/版本 2 表明网口负载是 `fpga_enhanced_raw8`，**不再是未经处理的 S0**。host RAW 灰阶逐字节解码，不额外增强；归档元数据也明确记录来源阶段。
- 为满足 125 MHz 时序，在网口增强与 PRAW 包缓存之间加入一拍、带 ready/valid 反压的弹性寄存器。改变像素值但不改变字节数量、帧身份、顺序或帧尾。HDMI 与网口仍是各自独立读取的帧，未证明同帧配对，采集卡也可能有缩放/色彩范围差异。

## 离线验证

- RAW8 回归 `fpga/build/raw8_dual_sim_20260926_203127_419/` 通过，包括连续字节流行末历史清除；原生 FIFO/DDR 行为模型整板回归 `fpga/build/raw8_board_sim_20260926_203120_095/` 通过，正常 6 帧 8,892 包、迟到 epoch 5 帧 7,410 包，经过生产 host PRAW 解包及独立像素比对。host 58 项 Python 测试和 10 项 JS 像素测试通过。
- PDS 2022.2-SP6.4 seed 1 出现 RGMII 快速角 setup −0.096 ns，seed 2 的未寄存版出现内部 PRAW 写入 setup −0.083 ns；两者均未导出/烧录。最终寄存版 `fpga/build/mini_raw8_dual/native_20260926_203204_428/` 原生布局布线与 min/max STA 显示 `Design Summary: All Constraints Met`，RGMII 四组 setup/hold 分别为 `0.137/0.103/0.052/0.106 ns`，各覆盖 5 个端点。SCL/SDA、HREF/VSYNC 等未约束外部端口警告仍存在；不得声称外部 DVP 全面时序验收。
- 最终位流经 `audit_raw8_candidate.py` 的源哈希、布线、仿真、原生时钟和 CDC 证据审计通过；离线发布于 `fpga/release/raw8_dual_20260926_b3fd240f7a23/`，新 SFC SHA-256 `B3FD240F7A232676D37F6A44A138700930DB76A13638705C035BFFF0EB6E6B06`。旧可恢复镜像 `fpga/release/raw8_dual_20260926_1f0c09ce8233/` 的 SFC SHA-256 `1F0C09CE82334727E2418E59D01725837B56C0401076F0A9BAE653503990DB9D`，烧录前已与当时 Flash 完整只读比对通过。

## 上板状态（2026-09-27，用户视觉审校待反馈）

- 用户本轮明确允许整片擦除 XT25F128 并回读校验。使用现有隔离 PDS 配置运行时只读识别 PG2L100H `0x00602899` 与外部 Flash；官方安装/参考目录未修改。此前用不含 XT25F128 表的官方 JTAG 服务扫描会报“不支持”，切换回项目已有隔离运行时即扫描成功。
- 500 kHz 尝试 `fpga/build/raw8_flash_program_20260926_dual_enhance/`：整片擦除完成，编程进度至 100% 后 `JtagServer-0016` 读超时，原生 Program 失败。随后的 100 kHz 只读整片比较 `fpga/build/raw8_flash_posttimeout_verify_20260926/` 到 100% 但明确报内容不匹配，不能视为成功固化。
- 同一授权内 100 kHz 恢复尝试 `fpga/build/raw8_flash_program_retry100_20260926/`：再次整片擦除完成，编程约 20% 又遇 `JtagServer-0016` 读超时。用户随后仅重新插拔 JTAG USB，未冷启动。500 kHz 再次整擦与写入 `fpga/build/raw8_flash_program_after_replug_20260926/` 虽报告编程完成，但原生 Verify 失败。独立只读回读 `fpga/build/raw8_flash_readback_mismatch_20260926/` 确认前 2,912,000 字节与候选完全相同、剩余 879,112 字节全为擦除态 `FF`，因此没有把 100% 进度当成烧录成功。
- 针对上述已匹配前缀/已擦除尾段，使用受控不擦除补写 `fpga/scripts/jtag_camera_flash_program_only.tcl`，记录在 `fpga/build/raw8_flash_program_only_recovery_20260927/`：PDS 原生 Program 与 Verify 均成功；再次独立只读回读 `flash_readback_verified.sfc` 与候选逐字节相同，SHA-256 同为 `B3FD240F7A232676D37F6A44A138700930DB76A13638705C035BFFF0EB6E6B06`。补写前未冷启动；仅在全部校验通过后请用户断电冷启动。
- 用户确认已彻底冷启动。新会话 `host/config/raw8-enhanced-cold-20260927_125230/` 通过 COM15 CRC 校验 Boot ACK，板上状态 `host/reports/raw8-enhanced-cold-20260927_125230/uart-inspect.json` 显示 sensor_ready/frame_published，未报告 HDMI 欠载、DDR/帧池/网口故障。Web 硬件接收会话 `web-hardware_unverified-20260927T045325Z-782fe524` 收到连续完整 1920×1080 帧，约 29.6～30.54 fps，每帧 2,073,600 字节，描述符 `0x484E4552`/版本 2，`source_stage=fpga_enhanced_raw8`，不启用模拟源。归档 `host/data/web-hardware_unverified-20260927T045325Z-782fe524/e18273013170809185274_f22122_t1_d1213089106/image.raw` 直接灰度解码均值约 113.89，无 PC 亮度增强。
- HDMI 短时采集 `host/data/hdmi_diag_20260927_125646_216599/` 首帧部分绿色，2.4 秒帧已显示正常网格场景；首帧判断为采集启动瞬态，不将其当成稳定画质。网口归档帧与 HDMI 采集时刻/视野不同，且采集卡可缩放或转换色彩范围，因此目前证实双路各自有真实图像与新描述符链路，却**未完成同帧亮度定量一致性验收**；待用户直接审校网页连续预览效果。HDMI 帧来源身份仍为 unverified。

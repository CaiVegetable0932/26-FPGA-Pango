# 摄像头镜像 Flash 固化测试

## 冷启动反馈与只读检查

### LED1 极性复核（更正此前口头推断）

用户补充 LED1 上电亮起并在不足半秒后熄灭，LED0 比 LED2 闪烁快。使用 PDF 视觉检查核对 MINI 硬件手册 V1.3 第35页 LED 电路：FPGA 引脚经限流电阻驱动 LED 阳极，阴极接地，因此是高电平点亮。原 Top.v 的 active-low 注释错误，本轮仅更正注释，不改变逻辑或 Flash。

当前 cam_led1 = !cam_init_done_0，因此先亮后灭支持配置状态从未完成转为完成；不能据此认定 SCCB 停滞。配置完成只代表当前控制器判定各写事务 ACK，不代表寄存器读回验证或帧格式正确。

LED0 按每 24000000 个 PCLK 翻转，LED2 按每 125000000 个 DDR core_clk 翻转；两灯速率不同由各自时钟/分频决定，肉眼快慢不能换算摄像头帧率。现有观测尚不能区分未生成完整帧、DMA/帧池停滞、读 FIFO 缺数据或 HDMI 传输不稳定。下一诊断应增加完整帧计数/显示有效状态观测，保留真实摄像头路径，不能把诊断图冒充摄像头画面。

用户释放预览后，身份绑定 Hagibis 的采集成功：host/data/hdmi_diag_20260920_143833_452734/。实际只获得9帧，不能宣称30fps有效视频；blackdetect 检出 black_start=0、black_end=2.654，解码首帧 SHA256=822E3A311BC34185394AEB709BB83310F1243089B95CDADC218EEE179B1D6F78，与此前 No Signal 图像哈希不同。存在非单调时间戳告警，尚不能排除 HDMI 链路稳定性问题。用户确认黑屏出现在 host 与 PotPlayer 的采集预览，尚无独立显示器验证。摄像头配置指示 LED1 状态仍待确认。

用户断电重启后反馈 LED0/LED2 闪烁、HDMI 黑屏且未显示 No Signal。按 MINI 硬件手册 V1.3 第35页，LED0=A20、LED1=C19、LED2=C18；对应当前 cam_led0、cam_led1、heart_beat_led。因此 LED0 支持摄像头 PCLK 有活动，LED2 支持 DDR 初始化完成后 core_clk 计数正常；不能据此认定有效帧捕获或 DDR 完整帧读写成功。

本轮只读 JTAG 返回 0x081ffca0：DONE=1、pll_lock=1、gouten=1，配置 CRC/ID 错误为0；over_temp 仍为1。此前下载后 PLL/输出使能为0的状态已不再出现，但未确定此前异常的根因。

当前 RTL 在 display_valid_sync=0 时强制输出黑色，该信号需要帧池发布完成帧并收到读 DMA 握手；这是待排查方向而非已确认故障点。也未排除 HDMI 像素/串行时序或接收端问题。

身份绑定 Hagibis 的3秒采集未能启动：DirectShow Could not run graph，可能被其他应用占用。证据 host/data/hdmi_diag_20260920_143646_708164/，没有有效采集帧。已请用户关闭预览并确认 LED1 状态、黑屏显示位置。本轮没有再次擦写 Flash。

## 最终进展：授权整片擦除后，原生写入与校验通过

用户明确授权擦除整颗 XT25F128。2026-09-20 再次执行原生 Erase → Program → Verify：擦除 13.1 秒，写入 91.3 秒，校验 31.5 秒。日志包含三个操作成功标记及 CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED，随后断开 JTAG；复查无遗留 cdt_js/cdt_cfg_shell 进程。

证据：fpga/build/camera_flash_erase_20260920_142848/program.log。镜像仍为本报告所列 8D2818CD…91D668 摄像头候选。外层 PowerShell 命令返回 1，不能将其作为原生下载退出码；本次通过依据是原生完整日志中明确的擦除、写入、校验成功及脚本结束标记。

整片原内容已清除，旧 HDMI 恢复镜像仍保存在前述证据目录中；未触及 eFuse/安全密钥。新增带显式整片授权开关的脚本 fpga/scripts/jtag_camera_flash_erase_program.tcl，后续不再假设 Program 自动擦除。

Flash 校验通过不等于摄像头视频通过。尚待用户断电重启，随后检查 DONE/PLL/输出使能并采集 HDMI。当前未完成冷启动、LED 或摄像头画面验收。

## 实测结果：首次写入校验失败，不能认定固化成功

用户授权只读解析官方 PDF 并要求写入 Flash。已只读查阅 PDS 2022.2-SP6.4 Fabric Configuration 手册第 89、90、92 页，未修改官方文件。

- FPGA：PG2L100H，ID 0x00602899。
- 外部 Flash ID：0x0B4018；官方运行环境在 1 MHz 与 100 kHz 均不识别。使用此前已支持 XT25F128 的独立运行副本后成功扫描。
- 独立运行副本：D:/XDU/concept/26-FPGA-Pango-test/pds_cfg_runtime；未修改该副本。Flash 数据库 SHA256 为 BC4450F2B04FA17D9C35FC9C2605AFD55A14782D005FC85FBCE0185541B0A3CA。官方数据库哈希仍为 CAE7A96B1ED5ADF77AFDB61A60E628E22DCE5D14497B4409750299DD4328D8D5。
- 摄像头 SBIT/SFC 哈希均为 8D2818CDA75309CC64B722D2BD46451D495CC081E17CD6D62601CEF1BA91D668，长度 3791112 字节，SPI X1 0x0B、起始地址 0。
- 原生 Program 完成，耗时 91.1 秒；随后 Verify 失败。Flash 已被改写，不再保证旧镜像可启动。
- 回读与目标有 199732 字节不一致；全文件逐字节检查发现回读恰好等于旧镜像与新镜像按位 AND（不一致数 0）。说明本次 Program 未包含擦除，NOR Flash 原有的零位未恢复为一。此前脚本声称 Program 会内部准备擦除范围的注释不适用于本次实测，不能沿用该假设。
- 旧 HDMI 恢复镜像已复制到 fpga/build/camera_flash_20260920/previous_hdmi_pattern_recovery.sfc，哈希 6226169A4388B7E66AAA3C059A41B8BAF6A3C6E9F58FB7FE720D53E81C65F441。它是已保存镜像，不是整颗 Flash 备份。

证据目录：fpga/build/camera_flash_20260920/。正在进行降速只读复核；尚未擦除整片 Flash，已向用户确认其他区域是否允许擦除。未进行断电启动或新的 HDMI 视频验证，不宣称摄像头功能通过。不得在校验失败时交付为可重启镜像。

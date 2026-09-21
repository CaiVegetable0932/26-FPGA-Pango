# OV5640 启动与 RGB565 采集重写

## 范围与当前状态

工作区为 `C:/Users/ROG/.codex/worktrees/fpga-camera-hdmi-preview/26-FPGA-Pango`，分支 `codex/fpga-camera-hdmi-preview`。仅修改 FPGA 开发区，不改原工作区、MCU、参考源或系统设置。该诊断链仍为 CAM1/J10 的 1280×720 RGB565 → DDR → HDMI，不是 RAW8/千兆网生产链路。

已完成实现、仿真、PDS原生全流程及Flash擦除/写入/校验；等待断电重启后的实物图像验收。这些结果不能互相替代。

## 实现

- `rtl/mini_camera_diag/ov5640_sccb.v`：新增读写控制器，16 位寄存器地址、8 位数据；开漏、输入同步、逐字节 ACK、拉伸超时。读取采用地址写入后 STOP，再单独读地址、8 位数据、NA、STOP。原 SCCB 写控制器保留供旧表回归参考。
- `rtl/mini_camera_diag/ov5640_startup.v`：硬复位 10ms、释放后等待 40ms，先读 300A/300B 必须为 56/40；先选 PAD 时钟，再使用原 244 项调校表，其中早期 3008=02 改为 42 待机、3103=02 改为指南的 03；最后明确 4740=20，再写 3008=02 开启输出，等待 50ms 并回读 14 项关键寄存器。共 247 次写、16 次读。软复位后仍等待 5ms，普通表项写后等待 1ms。
- 回读检查运行位、1280×720 尺寸、RGB565 格式、DVP 极性、输出使能、PLL 配置、DVP/MIPI 选择、关闭测试图案；不检查会随自动曝光变化的寄存器。
- 失败最多重试两次（总共三次），每次均重新硬复位；最终失败保持摄像头复位、ready=0。错误码 1=单独事务总线错误，2=ID 错误，3=配置表事务错误，4=回读不符，5=非法步骤。verify_index/last_read 保留最后验证项和值。这些内部端口暂未接主机遥测，不能声称已读出实物错误码。
- `vendor/camera/camera.v` 使用新启动器；init_done 现在表示身份及配置回读已验证，不再只是整表 ACK 完成。
- `vendor/camera/camera_data.v` 重写为显式高/低字节配对、逐行计数、逐帧准入。VSYNC/HREF/data 同拍采样；首字节与 VSYNC 下降沿重合不会丢失。短/长行中止该帧剩余采集，下一帧重新对齐；预热只累计完整几何的最后行，前十帧不输出。cfg/DDR 仍只对就绪位使用 2FF。
- DDR、帧池、HDMI 和引脚不变；保留先前 FIFO 写长度修复。所有新增/修改功能块有用途注释。

边界：接收器不能撤回已经写入 FIFO 的前缀；若错误直到已输出最后一个像素后才出现（例如最后行的额外字节），不是严格整帧事务回滚实现。未声称增加了任意畸形帧的全量完整性签核。

## 依据（原资料只读）

- 本机 PDS 2022.2-SP6.4 `doc/Pango_Design_Suite_User_Guide.pdf` 配置位流、report_timing 命令；`Fabric_Configuration_User_Guide.pdf` 第89–92页的 JTAG Flash 扫描/擦除/编程/校验及 cfg_gen_sfc。
- `reference/盘古100K200K MINI开发板/4_IC_datasheet/OV5640/OV5640_DataSheet.pdf`：芯片 ID、启动等待、寄存器字段。
- 同目录 `OV5640_AF_Imaging_Module_Application_Guide_(DVP_Interface).pdf` 第14页待机初始化顺序、第27页 DVP 极性；仅移植启动顺序，不把其 VGA/YUV 表当 RGB565720p 表。
- OmniVision 原始 [SCCB 规范](https://file.hstatic.net/1000180878/file/omnivision_technologies_seril_camera_control_bus_sccb__specification.pdf)，读取前设定子地址、单字节读取用高 NA 结束；OV5640 使用 16 位子地址扩展。
- J10 接线与模块板上 24MHz 时钟/PWDN 接地沿用本项目 `ov5640_j10_interface_review_20260914.md`；未更改模块连接。

## 仿真证据

可重放脚本：`fpga/scripts/sim_ov5640_verified.ps1`；完整通过目录 `fpga/build/camera_verified_sim_20260920_191824/`。

| 测试 | 实际结果 |
| --- | --- |
| SCCB 双向独立引脚模型 | 12 项通过；00/FF/AA/55 读写、忙时输入变化、读地址 NACK、SCL 超时与释放 |
| 启动全链路故障注入 | 10 项通过；正常 247 写/16 读、错误 ID、无 ACK、回读错误、三次封顶、外部复位恢复 |
| 默认 27MHz 真实参数仿真 | 10ms RESETB、40ms 启动等待、5ms 软复位间隔通过；仿真启动耗时 448.416234ms |
| RGB565 单元测试 | 26 项通过；字节序、SOP/EOP、短行终止、就绪门控 |
| 预热 | 12 个短帧不计数、前10个完整帧丢弃、第11帧放行 |
| 完整720p边界 | 0–6周期首行间隔；7帧×921600像素逐一检查，通过 |

补充封装层回归：`fpga/build/camera_rewrite_20260920/tb_camera_startup_audit.log`，真实默认参数、247写/16读完成；仅有 PCLK、无 HREF/VSYNC 时始终无像素输出，STARTUP_PASS。此项已加入可重放脚本；原 ACK-only 测试改用双向寄存器模型。`git diff --check` 在本次 FPGA 源码、脚本、测试、报告及工程 Tcl 范围通过。

SCCB 独立模型依据真实 SCL/SDA 解码而非 DUT 内部状态。曾发现测试模型在故意 NACK 后仍发送数据，已修正为 NACK 后释放总线并重跑通过；不是把失败日志当成成功。脚本明确检查 PASS，并拒绝 FAIL/Fatal/Timeout，即便 ModelSim 返回0。

## PDS / Flash / 实物验收

PDS 原生构建 `native_20260920_191635_496`：19:16:43–19:24:51，退出码0、错误数0，完成 compile/synthesize/dev_map/pnr/report_timing/gen_bit_stream，报告 `All Constraints Met`。现有 CDC 约束保持不变；摄像头时钟域慢角 setup 裕量5.990ns、快角 hold裕量0.170ns。HDMI 集成静态回归另有4项通过。构建后仅整理了两处注释/空白，没有修改已构建的功能逻辑。

本次烧录前只读探测：PG2L100H ID=00602899，状态081FFCA0，DONE/PLL/GOUTEN=1、CRC/ID错误=0，over_temp=1；Flash服务器日志确认 flash_id=b4018。仍使用先前登记 XT25F128 的私有配置工具副本，未修改官方安装或数据库。本次镜像归档 `fpga/build/camera_verified_flash_20260920/Top.sbit` 和 `Top.sfc`，两者 SHA256均为 `C7CFCF224E1DA9121893330C1B5D6879E2D5D6E4F680096DF77D053BA5AADF88`。恢复文件 `camera_flash_20260920/previous_hdmi_pattern_recovery.sfc` 保留，SHA256为 `6226169A4388B7E66AAA3C059A41B8BAF6A3C6E9F58FB7FE720D53E81C65F441`。

Flash 状态：擦除13.0秒、写入91.4秒、回读校验31.5秒均成功，`program.log` 包含 `CAMERA_FLASH_ERASE_PROGRAM_VERIFY_COMPLETED`，外层退出码0；JTAG已断开，专用服务已退出。整颗XT25F128原内容按授权擦除并被新镜像替换；保留的是已知HDMI恢复位流，不是全部Flash数据的备份。未执行 SRAM-only 下载、安全配置或 eFuse 操作。新图像必须冷启动后通过 Hagibis/host 或 PotPlayer 观察，并遮挡 CAM1 验证来源。当前未宣称黑屏已排除，也没有真实摄像头图像成功证据。

四页 LED 不改变：LED1:LED0=00 时 LED3/4 为 VSYNC/HREF 活动；01 为正确行/完整几何帧；10 为已输出像素/显示帧池就绪；11 为摄像头已通过身份和配置回读/DDR初始化。LED2 为心跳。顶部 reset 指示不参与编号。

既有 DVP 100MHz 仅为内部分析预算，未填造外部 input_delay，外部 DVP 电气与 setup/hold 尚未签核。此前 over_temp 状态位曾为1，不等同温度读数；未屏蔽告警或改动保护。

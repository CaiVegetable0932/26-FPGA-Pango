# HDMI 主线功能集成（2026-09-19）

## 实现与边界

这不是把独立测试工程原样并入 main。共用实现归入 `fpga/rtl/hdmi/`，两个现有 PDS 工程均引用同一份编码器、串行器、上电复位和板级 PLL。

- `pango_video_top`：替换固定消隐符号发送，接入完整 720p60 行场时序、显式动态自检图与 RGB888 TMDS 发送。保留原有 DDR/IP 集成、RGMII/PHY 安全状态。
- `mini_camera_diag/Top`：保留摄像头配置、DVP、帧池所有权及 DDR 读出；将真实 `vout_data_0` 经 RGB565 全范围扩展接入共用发送器。完整帧发布前输出具有有效行场时序的黑色，不切换到彩条冒充摄像头。
- `host/src/hdmi_diag_capture.py`：延续主线 FFmpeg 采集实现，新增即时 DirectShow 枚举、Hagibis 名称和 VID/PID 双重校验，按唯一物理路径打开设备。保留压缩原流、解码 RGB、PNG、MP4 和元数据。

main 的正式顶层原本未实现摄像头/RAW8/ISP/几何矫正；本次不会把 RGB565 诊断模式改写成 RAW8 产品基线。共用发送器的正式输入契约为同一 `pixel_clk` 域的 `rgb[23:0] + data_enable + hsync + vsync`；将来 S2/S3 扫描输出应接该接口。它不接受 DVP 异步数据，也不提供帧缓存/缩放/跨时钟转换。

当前 720p 模式是链路集成与诊断模式，不是 1080p30 系统验收。HDMI 发送 1280×720@60，像素时钟 74.25 MHz、串行时钟 371.25 MHz；Hagibis UVC 采集为 1280×720@30/MJPEG。没有音频、HDCP 或 HDMI 数据岛；RGB 视频为 DVI-compatible TMDS。

## 依赖与约束

- PDS 2022.2-SP6.4 build 146967；目标 PG2L100H / FBG676 / -6。
- `ip/hdmi_tx_pll/clk_hdmi.v` 是板卡参考的原样副本，SHA256 `B65AB143B4A61FB4AAFDBA60C99850B919F90C445C61624E0A9CCE0289B7599E`。来源：`reference/盘古100K200K MINI开发板/2_Demo/5_1 双目摄像头例程/ov5640_200k/prj/ipcore/clk_hdmi/clk_hdmi.v`。
- TMDS 主从 DDR10TO1 级联来自同板 `2_10_hdmi_loop` 参考，经过隔离工程 `26-FPGA-Pango-test/camera_rgb565_hdmi` 重写和板上验证。编码器/时序发生器保留原作者说明。
- 27 MHz=D18；CLK=N21/N22；D0=R25/P25，D1=P23/P24，D2=N23/N24；TMDS/3.3 V。核对 `ov5640_200k/ov5640.fdc`，不是其他例程的 LVDS25/2.5 V。
- 官方只读参考：`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/User_Constraint_Editor_User_Guide.pdf` 的生成时钟和时序例外说明，以及安装目录的 `GTP_OSERDES_E2.v` 原生模型。官方目录未改写。
- 旧单输出 `video_pll` 生成物保留为历史依赖，不再被这两个 PDS 工程使用；`ip_catalog.json` 的 `rtl_replacement` 明确记录替代关系。主线审计验证已验证 PLL 的来源、371.25 MHz 串行频率、原生 /5 像素时钟及其 40% 占空比。HDMI 引脚上的转发时钟由 1111100000 串行符号产生，仍为 50% 占空比。

## 集成中修复的复位问题

隔离工程把像素域上电计数器路径作为例外；直接复制双 PLL 输出到 main 的两个全局时钟网络会产生 IOL 恢复/移除违例。本次保留 main 原有的单源原生 I/O 时钟结构：已验证的 clk_hdmi 仅使用 371.25 MHz 输出，经区域缓冲和 GTP_IOCLKDIV_E2 /5 得到同源 74.25 MHz 像素时钟；分频器由 serial 域同步链释放，公共上电计数器再等待稳定像素时钟。每通道两负载寄存器在像素上升沿释放原生 ASYNC_RESET 主从串行器，沿用 main 已建立的局部区域和优先布线。最终不新增内部复位 false-path 或 min-delay 覆盖，计数器、局部寄存器和 IOL 路径均由原生 STA 检查。

上电计数器明确初始化为零，避免分频器复位期间没有像素边沿而导致冷启动状态未定义。原生模型同时覆盖冷启动、重新复位及四通道一致字相位。PLL 约束按 UCE 2.2.1.2 使用原生 PLL/分频器推导；PLLLock 失效期间不视为有效视频，重新锁定后必须完成公共上电等待期。

阶段性失败（公共复位过长、局部复位过短、双全局时钟网络下的不同复位边沿/同步模式候选及最小延时覆盖）不作为验收结果。最终构建与回归证据见本文后续验收记录。

## 可复现入口

在任意工作树根目录执行；业务源/输出均留在开发区，不依赖外部测试目录：

```powershell
./fpga/scripts/build.ps1 -Stage all
./fpga/scripts/build_mini_camera_diag.ps1 -Stage report_timing
./fpga/scripts/sim_hdmi_main.ps1
./fpga/scripts/sim_hdmi_native.ps1
./fpga/scripts/sim_mini_video.ps1
./fpga/scripts/sim_mini_frame_pool.ps1
python -B fpga/sim/test_hdmi_integration.py
python -B host/tests/test_hdmi_device_identity.py
python host/src/hdmi_diag_capture.py --seconds 3
```

ModelSim 默认 `E:/ModelsimSE/win64`。原生模型测试默认使用已有的 `fpga/build/simlib_verified`，也可通过 `-SimLibrary` 指定本机按 `fpga/scripts/simlib.tcl` 编译的 PDS 同版本库。主线采集继续使用 `host/build/capture_runtime` 中的 imageio-ffmpeg 0.6.0；无需把隔离工程的 OpenCV 包复制进主线。

## 实测身份边界

本次主线采集软件实测证据：`host/data/hdmi_diag_20260919_221732_827992/`。名称和物理路径同时确认 Hagibis（VID_1DE1/PID_F105），首帧人工检查可见彩条、边框、横线与移动标记。图像来自板上此前烧录的隔离测试位流（已知发布 SHA256 `6226169A4388B7E66AAA3C059A41B8BAF6A3C6E9F58FB7FE720D53E81C65F441`），本次没有重新读回核验该哈希。

这只能证明主线采集软件能接收已工作的板上链路，不能证明新集成位流已上板，也不能证明摄像头内容/源帧身份。元数据继续保持 `source_frame_id=null`、`pairing_status=unverified`。PNG/MP4/解码 RGB 均不是 FPGA RAW8 原始证据。PotPlayer 未在本轮重新验证。

本次未修改 MCU、RAW8 网络协议及系统设计基线；未写 Flash、eFuse 或安全设置。现有主工作区的未提交改动没有被覆盖或混入提交。

## 最终验收记录

最终通过证据按原始字节归档在 `fpga/reports/hdmi_main_20260919/`，失败候选与大型工具缓存不纳入本次提交。历史 `fpga/build/` 的旧提交产物不代表本次源码，应重新构建或查阅本次归档。

- 主工程完整 PDS 构建：2026-09-19 23:07:15 至 23:12:26，原生退出码 0、错误数 0、审计退出码 0；慢/快角 setup、hold、recovery、removal 均无失败端点，`flow_passed=true`，证据 `main/`。
- 摄像头工程原生布局布线及 STA：23:10:58 至 23:14:53，`All Constraints Met`，证据 `camera/`。这不是传感器、DDR 外部时序或摄像头上板功能验收。
- 最终逻辑回归：RGB565 全部 65536 个输入、1650×750 总时序、1280×720 有效区、2474995 次 RGB/控制检查通过，证据 `logic_sim/`。
- 原生四通道串行回归：1024 个符号、46167 次检查、错误 0，冷启动和重置恢复通过；原生像素周期 13.470 ns、高电平 5.388 ns，证据 `native_sim/`。
- 原有视频/帧池回归分别 `VIDEO_PASS`（2 帧、1843200 像素、4319640 检查）和 `FRAME_POOL_PASS`（144 检查），证据 `video_sim/`、`pool_sim/`。
- FPGA 集成静态测试 4 项通过；上位机完整测试 68 项通过，报告 `host/reports/hdmi_integration_tests_20260919.json`。

主工程未烧录候选位流保存为 `fpga/release/hdmi_main_20260919/pango_video_top_unprogrammed.sbit`，SHA256 `9C77D25270D42887DA40AFEAF9D04523502FD090CB6A0D3CF2288AA1501F00F8`。它是主顶层动态自检图版本，不是摄像头/ISP 产品位流；`hardware_tested=false`、`programmed=false`、`external_io_timing_signed_off=false`、`bitstream_approved_for_programming=false`。本次完成的是源码功能集成、软件/原生模型回归和内部时序收敛，不将隔离工程的上板结果转移给新位流。

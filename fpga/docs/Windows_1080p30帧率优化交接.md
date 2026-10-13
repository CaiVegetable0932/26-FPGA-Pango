# Windows 开发交接：1080p30 的板端处理与上位机预览

## 当前结论与目标

本次定位到两个独立问题：Jetson 上位机接收/预览负载造成 UDP socket 丢包和浏览器更新变慢；当前板端共用处理链路的结果发布也低于摄像头输入。不能用网页的协商 30 FPS 或 HDMI 固定扫描频率代替有效图像帧率。

独立 DVP 监测显示摄像头输入约 30 FPS；当前 FPGA 结果发布约 25 FPS。隐藏网页预览后这一板端差异仍存在。关闭标记，分别使用 FPGA 原图和矫正模式，均得到相同量级的差异；采集拒绝、采集溢出和处理故障计数没有增加。因此已有证据将板端瓶颈范围收敛到原图/矫正共用的采样、灰度 ISP、DDR 仲裁/写回、租约及发布链路，尚未确定其中哪个模块消耗最多等待周期。

早期窗口曾出现约 30 FPS 的结果发布；它们没有同步记录独立 DVP、实际显示模式和完整参数身份，不能作为当前矫正配置已达到 30 FPS 的验收。下一轮必须在同一 epoch/session、参数版本及显示模式下重新建立基线。

目标是摄像头 1920×1080/30 输入时，原图及矫正模式都稳定发布 30 个新结果/秒，同时维持以太网增强 RAW8 原图回传。HDMI 继续输出 FPGA 结果；不把几何处理移到 PC，也不修改现有标定算法、标记位置合同和数据阶段标签。

本文只交接结论、代码入口与开发要求。视频、RAW、照片、浏览器会话和实测报告保留在 Jetson，不随核心提交上传。

最终一次 20 秒窗口中，HOST 网口完整接收及左侧绘制接近 30 FPS，HDMI 网页回调约 29.5 FPS，socket 丢包为 0，而 FPGA 新结果仍约 25 FPS。该短窗口验证了接收/显示路径可以接近目标，不证明所有负载下长期稳定；同时说明 UVC/网页的约 30 次更新会包含板端重复结果，不能据此跳过 FPGA 优化。

## 先核对版本与参考

Jetson 后续补充的分路 CPU/接收/显示对照见 [帧率瓶颈复验](../../host/docs/帧率瓶颈复验说明.md)。使用 Runtime-only 观察器，避免整帧 WebSocket 调试流量污染结果；新增位图导出、主线程等待及真实 Worker 队列统计。临时原图/矫正对照不更改参数与位流，返回原模式。当前实测文件继续只在 Jetson 本机留存，不把网页优化当作板端吞吐问题已解决。

- Git 拉取 main 前检查本机未提交文件，保留 Windows 标定和开发成果。起始核心版本包含 `17af7a4ce` 的 Windows 标定成果和后续 Jetson 接入。
- 当前发布镜像为 `fpga/release/geometry_20261007_e4dd5bbb06e6/mini_raw8_geometry.sfc`，SHA-256：`E4DD5BBB06E659C55ECB87B7A4F66385D0680A2D1C4DE46F838830B7AFA180A2`。文件身份不等于板上 Flash 回读证明；实测前仍核对所烧镜像。
- 当前关键处理 RTL 的文件哈希已与该发布目录 `source_manifest.json` 对照一致。发布 README 的历史离线 STA/仿真记录不能替代本次硬件帧率测试。
- PDS 版本为 2022.2-SP6.4，目标 PG2L100H-6FBG676 / 盘古 100K MINI。涉及工程、IP、仿真、STA、下载前，按根目录 AGENTS.md 只读查阅 `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc`，同时核对 `reference/` 的目标板资料。不要在官方目录生成索引、日志、工程或输出。

当前标定配置入口为 `host/config/calibration/fpga-fisheye-rgb33-20261010.json`，模型是四系数 `fisheye_equidistant`，参考尺寸 1920×1080，输出 FOV 100°。复现时用 Web 上传并回读激活版本，不能只读 JSON 就认为板上参数一致。不要把网络 RENH v2 的 `param_version=2` 当作几何参数版本。

## 可直接复测的工具

先按 `host/docs/一键启动说明.md` 启动现有工作台，确认串口与网口连接正确。工具只连接本机 `127.0.0.1:8765`，复用服务的 UART 锁，不再直接打开一个竞争的串口。

Windows 使用项目 Python 3.12+ 环境或已经配好的项目 Python：

```powershell
python -B host/scripts/check_fpga_processing_framerate.py --seconds 60
python -B host/scripts/check_fpga_processing_framerate.py --seconds 60 --compare-original
```

第一条只读计数，不切换模式。第二条暂时关闭标记，依次比较原图/矫正模式，在 `finally` 中恢复进入测试前的 mode/markers/diameter；不上传新 K/D、不重置板卡、不修改电源、不操作 Flash。运行前保持参数不变，避免另一窗口同时操作显示控制。固件必须同时支持几何和 DVP 诊断；缺失时应显式报错。报告输出到本机 `host/reports/fpga-processing-fps-*`，不需要将其提交到 Git。

Jetson 上对应命令：

```bash
host/build/environment/venv/bin/python -B host/scripts/check_fpga_processing_framerate.py --seconds 60
host/build/environment/venv/bin/python -B host/scripts/check_link_framerates.py --seconds 20 --views live settings live
```

第二条同时比较网页可见/隐藏时的 DVP、结果发布、网口完整帧、Canvas 绘制、HDMI 回调及 socket/NIC 丢包。它依赖 Jetson 的网卡 `enP8p1s0`、Linux `/proc/net/udp` 和已有浏览器 CDP，不是 Windows 通用测试脚本。

只读 HTTP 为 `GET /api/board/performance`。`result_published` 是 32 位累计结果数；`dvp_frame_count` 是独立监测物理 VSYNC 的 16 位数，分别按各自 `counter_time` / `dvp_counter_time` 求差并处理回绕。DVP 快照为 `0x07`，进度为 `0x08`；它们带原有 CRC/序号/epoch/session 校验。

## 下一步 RTL 工作顺序

1. **补全按完成帧锁存的周期证据。** `geometry_gray_processor.v` 的 READ bank1/index18 是运行中计时器，下一帧 start 会清零；随机读到的值不能当作上一个完成帧耗时。增加完成帧周期、最小/最大周期、采样帧数以及状态等待周期，并与完成 source_id/epoch/version 同时锁存。读接口增加稳定快照/生成号，防止 UART 多次读拼接不同帧。同步更新协议、HOST 解码与 fake-UART 测试。
2. **测量共用链路的停顿比例。** 在 `raw8_geometry_core.v` 区分结果槽申请、源租约等待、处理中、marker_ready 等待及发布阶段；在采样/写回处区分 cache miss、read_ready、DDR read_done、writer_ready、AW/W、最终 fence 等待。保持完成结果的内存 fence 和源/结果租约释放顺序。
3. **根据实测比例优化。** 重点检查 `geometry_window_cache.v` 的 miss/fill/replay、三路 RAM 与窗口局部性，`geometry_read_arbiter.v` 的 HDMI/网口/几何读仲裁，以及 `geometry_result_stream_writer.v` / `geometry_write_arbiter.v` 的单 beat 写与背压。当前 cache 已有两槽弹性流水和 hit II=1，不能依据 sampler 旧的“两拍/像素”注释断言它尚未流水化。扩大缓存、预取、增大写突发或修改仲裁都需重新验证 RAM 打包、租约、安全背压和时序，不能仅凭面积/理论带宽估算宣布有效。
4. **以真实输入压力回归。** 源采集、网络满速发送、HDMI 读出和结果写回同时开启；覆盖真实 K/D/FOV、原图与矫正、标记开关、随机 DDR 背压、帧边界参数切换、reset/invalidate 以及异常源窗口。保持独立模型/旧实现像素与掩码一致。优先检查 `fpga/scripts/sim_cache_valid_parallel.ps1`、现有 geometry full-frame/DDR 回归及发布门禁的适用范围。

核心位置：

| 文件 | 责任 |
| --- | --- |
| `fpga/rtl/raw8_dual/raw8_dvp_monitor.v` | 与采集准入独立的 VSYNC/行几何计数 |
| `fpga/rtl/geometry/raw8_geometry_core.v` | 源/结果帧池租约、处理状态、完成身份和结果发布 |
| `fpga/rtl/geometry/geometry_gray_processor.v` | 映射、采样、灰度处理、写回/fence 与帧周期计数 |
| `fpga/rtl/geometry/geometry_window_sampler.v`、`geometry_window_cache.v` | 邻域读取、cache miss/fill/replay 与背压 |
| `fpga/rtl/geometry/geometry_result_stream_writer.v` | 灰度/掩码打包、队列、DDR 写与完成 fence |
| `fpga/rtl/geometry/geometry_read_arbiter.v`、`geometry_write_arbiter.v` | 同时运行时的读写仲裁 |
| `fpga/rtl/geometry/geometry_view_snapshot.v` | HDMI 实际显示模式/版本的元数据确认 |

按板级配置 125 MHz，30 FPS 的单帧预算约 4,166,667 周期；应给最差 DDR 背压留出余量，而非只让均值刚好达标。频率是当前设计配置，不是本次示波器实测。不要通过放宽时序约束、删除 fence/CRC、扩大无界队列、覆盖未完成帧或抬高显示 FPS 数字完成验收。

## 上位机已保留的修复

Linux UDP `recvmmsg` 批量由 32 增至 256，仍非阻塞排空现有报文；本机服务 Python GIL 切换间隔设为 1 ms；网页状态轮询使用轻量摘要，完整失败历史仍保留在默认诊断 API。实测中这些措施降低了 host 丢包并提高完整接收率，但没有实现所有窗口稳定 30 FPS。

HDMI 显示 FPS 只计实际观察到的新 mediaTime 回调，不补计跳过的合成提交；浏览器 quality 总数/丢弃数单独标注，且矛盾时明确显示。实际 callback 不等于显示器/远程桌面最终更新数，也不能证明每帧都有不同 FPGA 内容。帧源身份仍为 `null/unverified`。

Jetson WebGL 已用于左侧预览。额外试验的 NVIDIA MJPEG 硬件解码路径没有提高两路同时运行的总体性能，已从正式服务、网页和启动配置撤回；不要把安装了 GPU 插件视为有效加速。NVIDIA 论坛也有类似 MJPEG 解码兼容性/延迟案例，参考：[USB camera nvjpegdec](https://forums.developer.nvidia.com/t/nvjpegdec-does-not-work-for-usb-camera/280767)、[MJPEG hardware decoding](https://forums.developer.nvidia.com/t/hardware-decoding-of-mjpeg/284525)。这些旧版本案例不是当前 JetPack 缺陷的确认，不据此替换本机驱动。

## 完成标准与交付

在同一版本、参数与输入下分别持续测试至少 120 秒；记录 DVP 输入、FPGA 新结果发布、原图网络完整帧、HDMI 新内容/实际回调和网页提交数，报告 1 秒窗口、长停顿及平均值。HDMI 30 Hz 扫描可以重复旧帧；须用板端完成 ID/稳定快照或可验证内容证明不同结果，不能按 USB 到达顺序拼接 source_frame_id。

Windows 交付新的 RTL、必要协议/HOST 变更、回归说明、严格 STA、冻结构建/镜像 manifest 和 SHA。实测数据仅留本机，核心 Git 提交不上传录像、RAW、数据集、浏览器会话或本地安装环境。新镜像不能在未烧录时声称已生效；最终 Flash 型号、地址及恢复镜像先核对，完成写入校验后另做彻底断电重启验证。

当前交接不是“已实现稳定 1080p30”的声明。需要 Windows/PDS 完成板端定位、优化、构建及上板复测。

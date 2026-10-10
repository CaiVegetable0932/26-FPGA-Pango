# 上位机开发区

2026-10-10：新增[RGB33 实测标定交付包](reports/rgb33-calibration-20261010/README.md)与[Jetson 最终上位机/控制器接入说明](docs/Jetson_RGB33标定接入说明.md)。推荐后续使用[鱼眼 FPGA 参数记录](config/calibration/fpga-fisheye-rgb33-20261010.json)（1920×1080、100°输出），明确区分原标定候选、当前 model=2 编码及未执行的硬件验证；旧手填预置不会隐式替换，本次未下发板卡。

2026-10-04：新增 [FPGA 几何参数上传器](scripts/fpga_geometry.py)，用于独立 `mini_raw8_geometry` 工程声明的 CAPS 0x80 扩展。沿用用户审校鱼眼预设，PC 只编码 K/D/仿射参数、回读并确认按帧生效，不处理主视频；详见 [接口及使用流程](../output/FPGA灰度鱼眼矫正参数接口.md)。当前网页的即时鱼眼画面仍是软件参考，不会自动改成 FPGA 结果或给 HDMI 提供可信源帧号。
2026-10-06：本轮仅上传核心实现与构建文件，采集与测试记录留在本机，详见[核心版本提交范围](docs/核心版本提交范围.md)。

板卡上电后的日常入口见[一键连接与预览](docs/板卡上电一键启动.md)：首次选择 CP2102 和直连网卡，后续启动 host 可自动完成 RAW8 UART 配置、UDP 接收与采集卡恢复；Windows/Linux 共用实现。

2026-10-06：HDMI 预览 FPS 改为实际观察到的新帧回调计数，跳过的回调不再补计，并增加解码 FPS、跳过更新、最长间隔；新增独立“以太网恢复默认并重连”按钮。用法见[启动说明](docs/板卡上电一键启动.md)，验证边界与结果见修复验证记录（本机留存：`reports/hdmi-fps-ethernet-reset-20261006/README.md`）。

2026-10-04：本机 Jetson 日常启动使用 `sh /home/cai/26-FPGA-Pango/26-FPGA-Pango/host/scripts/start_workbench.sh`，启动后台服务并复用工作台页。已接入网口完整帧和两个预览的实时 FPS，HDMI 默认请求 1920×1080 / 30 FPS；本次真实硬件性能、原始证据和测试边界见1080p30 双路性能验收（本机留存：`reports/preview-performance-20261004/README.md`）。以下较早报告保留各自当时的验收范围。

2026-10-04 双路波动复测：默认启用 Worker/GPU 派生预览、减少逐帧界面开销，1080p 请求目标 30 FPS 并保留 31 FPS 浏览器交付容差（实际 UVC 仍为 30）。连续 61 秒完整接收 30.00、网口彩色显示 29.92、HDMI 解码 29.87 FPS；短窗口仍有波动，详见双路预览优化与实测（本机留存：`reports/dual-preview-stability-20261004/README.md`）。

2026-10-02：Linux/Jetson 环境与本地标定工作台合并。Linux 提交 `931f2da6` 的历史 Jetson Ubuntu 22.04 ARM64 验证（77 项 Python、11 项前端像素及桌面浏览器检查）见[本机环境配置](docs/本机环境配置.md)和[原验证报告](reports/environment_20261002/README.md)，不代表合并版本已在 Jetson 实板复验。合并版本的 Windows/Linux 软件回归见[合并报告](reports/host_linux_merge_20261002/README.md)。已有 Jetson 环境更新后先执行 `source host/scripts/env.sh` 和 `python host/scripts/setup_calibration.py` 补齐标定依赖，再运行 `sh host/scripts/start_web.sh`。

## 镜头与相机标定（开发中）

本分支新增本机 `/calibration` 工作台：手动记录镜头—图卡实测距离及其参考面、图卡尺寸、镜头/相机/焦点、光照、曝光、云台角度和龙门架位置；支持网口完整 RAW8、采集卡 RGB 和图像导入，分别保存原始证据与派生角点图。OpenCV 提供鱼眼等距模型及受限针孔模型的候选拟合和独立验证；鱼眼系数不兼容旧 FPGA Brown 针孔寄存器，新灰度候选须显式选择 model=2 并独立下发。网页不会自动下发或宣称板端完成矫正。安装可选依赖：`python host/scripts/setup_calibration.py`。使用边界与步骤见[标定工作台](docs/标定工作台.md)。

`/calibration#manual-preview` 提供用户指定的手动鱼眼软件参考：默认采用 2026-10-02 用户审校组合（1920×1080；fx/fy=770/752，cx/cy=945/553；D=0.121/-0.118/0/0.036；输出139°），并保留通用光学假设预置。支持焦距、主点、k1～k4 和输出视场即时调参、同输入原图对比、冻结、JSON 导入导出。来源为已保存样本或显式打开的采集卡；结果标记为 PC 软件参考，不替代正式 FPGA 视频链路或标定验收。

1080p RAW8 双路候选的串口配置、网络接收与 Hagibis 独立预览见 [启动说明](docs/RAW8双路候选启动与预览.md)。新 0x71/RAW8 与旧 TEST 严格区分；本轮只做离线验证，不宣称已经收到实际双路相机画面。

本目录承载PC上位机软件及其配置、采集证据、测评报告和发布产物。当前已有PRAW V1网络编解码、帧重组、UDP接收、原始证据归档及模拟验证核心；本机Web界面已接入S0采集、基础预览、连接设置与原始证据管理；浏览器视频采集卡设备选择与预览接口已接入；UART、HDMI原始证据归档、设备联调和硬件验收尚未完成。

## Web工作台

Windows 双击 [start_web.cmd](scripts/start_web.cmd)；Ubuntu 在项目根目录执行 `sh host/scripts/start_web.sh`。启动后自动打开本机界面，默认 http://127.0.0.1:8765；重复启动可复用同一目录已运行的服务。点击“开始模拟”即可走真实UDP链路；采集记录显示全部图像、运行与生成报告，可多选删除、回看并下载RAW与元数据。两路视频使用等大的16:9面板与蓝白主题。视频采集卡在“连接设置”中选择，保存配置不要求输入信号；需要显示设备输出时再单独打开预览。

- [Windows / Ubuntu 一键启动与退出说明](docs/一键启动说明.md)
- [视频采集卡选择、无信号配置与预览接口](docs/视频采集设备接入说明.md)
- [Web界面与核心接入说明](docs/Web界面与核心接入说明.md)
- [Web软件验证记录](reports/Web_UI软件验证记录.md)
- [全量记录、删除与双路对比更新验证](reports/Web_UI记录管理更新验证.md)
- [界面入口](web/index.html)、[会话适配](src/pango_video/web_session.py)、[HTTP服务](src/pango_video/web_server.py)

## 已实现的网络接收核心

- [完整协议与核心API](docs/千兆网视频协议与上位机实现.md)
- [Ubuntu 24.04与Windows运行说明](docs/Ubuntu24.04与Windows运行说明.md)
- [软件验证记录](reports/PRAW_V1软件验证记录.md)
- [源码入口](src/pango_video/receiver.py)、[启动脚本](scripts/praw.py)、[测试脚本](scripts/test.py)

在项目根目录执行 python -B host/scripts/test.py 可复核软件；执行 python -B host/scripts/smoke.py 可验证两个本机进程的合成RAW8传输和归档。Ubuntu使用python3。默认配置只连127.0.0.1，实板地址/身份/epoch须回读确认。

## 文档入口与阅读顺序

| 顺序 | 文档 | 主要内容 |
| --- | --- | --- |
| 00 | [输入输出与数据约定](../output/host/00_输入输出与数据约定.md) | 职责边界、外部输入输出、运行模式、帧身份、标准数据对象、模型接口、数据与报告归档 |
| 01 | [硬件连接与通信](../output/host/01_硬件连接与通信.md) | S0千兆网与结果HDMI、PC/FPGA/MCU/IMU接线、UART协议、同帧快照、同步和重连 |
| 02 | [算法处理与测评](../output/host/02_算法处理与测评.md) | 真实标定、冻结模型调用、有效域、坐标/像素/直线/姿态/MTF/光照/性能评价 |
| 03 | [开发流程和规划](../output/host/03_开发流程和规划.md) | 建议技术路线、模块输入输出、并发与队列、八周计划、测试检查点和发布要求 |

上位机总体需求、跨端接口、测评设计和开发规划存放在 [output/host规划目录](../output/host/README.md)；本目录保留开发入口、已实现模块的协议与使用说明（host/docs）、实际实现、配置和运行产物。跨端总体架构与整机验收仍参考 [output规划区](../output/README.md)。上述文档均为待实施规格，不代表可执行程序、真实数据或测量报告。

## 实现与产物落点

| 目录 | 内容 |
| --- | --- |
| docs/ | 已实现模块的协议细则、核心API和运行说明 |
| web/ | 本机Web界面、样式、交互与Worker像素预览 |
| src/ | RAW网络重组、HDMI采集、FPGA/MCU客户端、基础预览、标定、参考适配、测评与自动测试 |
| config/ | 设备连接、测试流程、ROI、标定及上位机配置 |
| tests/ | 单元测试、通信模拟、集成、回放与端到端测试 |
| scripts/ | 本区启动、构建、打包、测试和数据处理脚本 |
| data/ | 采集图像、同帧证据、实际参数、事件日志、模型调用中间证据和回放输入 |
| reports/ | 由上位机产生的指标、曲线、测评结果及报告 |
| build/ | 上位机构建结果与中间文件 |
| release/ | 软件发布包、冻结依赖、版本、配置、操作说明与校验记录 |

同一运行的证据在host/data/<run_id>/，报告在host/reports/<run_id>/，通过run_id、版本和哈希关联。网络核心已有实现与软件证据；其余模块是否完成以对应代码和实际验证为准。

## 与其他开发区的边界

- [FPGA开发区](../fpga/README.md)负责RTL、ISP、帧缓存、硬件算法、PDS和位流。浮点与位精确权威参考模型归fpga/model；host适配调用冻结版本，不维护另一套模型源码。
- [MCU开发区](../mcu/README.md)负责云台、电机、灯光、外设驱动和设备端保护。host只负责PC控制客户端和试验编排，MCU型号和SDK仍待确认。
- FPGA资源与时序原报告归fpga/reports；host测评报告可引用或带来源复制，不伪造重新测量。
- 原mcu/host/不再使用，PC功能统一归本区；MCU板级数据仍归mcu/data。

## 当前基线与后续第一步

硬件基线为PG2L100H（盘古100Kmini）＋单路OV5640，真实1080p30为交付目标。S0 RAW8通过板载千兆网接收，FPGA结果通过单HDMI采集通道接收；PC不向FPGA转发主视频，手动鱼眼预览仅是明确标记的软件参考，不属于板端实时矫正。采用串口融合IMU直连FPGA的方向，具体模块和协议待落实。当前界面采用浏览器＋Python标准库本机服务，替代此前PySide6建议；核心不依赖第三方包，标定功能需 OpenCV/NumPy，Linux 设备工具与 Jetson 环境依赖及验收边界见上方说明。

先按03文档推进可靠控制、S0网络接收、结果HDMI回采与板端同帧证据采集，再接入测评与自动报告。无硬件时可以用显式标注的mock/replay推进软件，不计作新的实时硬件验收。

## 依据与仓库规则

- [项目工作约定](../AGENTS.md)
- [当前FPGA详细设计](../output/PG2L100H_1080p畸变矫正详细设计方案.md)
- [整机测评方案](../output/可控光照箱与上位机测评详细实施方案.md)
- [两个月开发计划](../output/两个月开发规划表.md)

在项目根目录打开VS Code可同时管理三个开发区。业务脚本按自身位置和显式配置解析路径，避免依赖终端当前目录。Git规则保持不变：仅排除根目录reference/和PDS/，本目录全部默认纳入；新增或修改内容按仓库约定暂存、提交并推送；不增加额外忽略目录。

## 原图、结果和证据的边界

HDMI 联调入口为 `python host/src/hdmi_diag_capture.py --seconds 3`。采集前即时枚举并强制校验唯一 Hagibis（`VID_1DE1&PID_F105`）物理路径；不回退到电脑 USB Cam。当前联调配置是 HDMI 源 720p60 / UVC 采集 720p30 MJPEG，不代表真实摄像头 60 FPS 或 1080p 系统验收。实现和实测边界见 [HDMI 主线集成报告](../fpga/reports/hdmi_main_integration_20260919.md)。

- 网络接收S0为完整1920×1080 RAW8，62.208MB/s；PC基础去马赛克仅用于原图可视化，不自动等价于FPGA S1。
- 普通HDMI CaptureFrame保留采集设备序号与时戳；未验证源帧关联时source_frame_id为null、pairing_status为unverified。
- 正式精度样本由FPGA复制S1和同源S2/S3至独立快照槽，再经限流网络导出。原始文件用.raw/.rgb＋元数据，PNG只作为派生展示。
- 无完整字节覆盖、校验失败、缺少必要参数或源帧身份时，拒绝对应测评；不得补零后标为完整帧，也不得自动使用软件矫正结果代替掉线的FPGA。
- 网络、采集、显示刷新和测评独立计数；GUI卡顿不能被隐藏成硬件30FPS通过。按[跨端回传方案](../output/OV5640_RAW8千兆网与HDMI双路回传方案.md)实现队列与接口。

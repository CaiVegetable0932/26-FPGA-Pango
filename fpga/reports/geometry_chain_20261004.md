# FPGA 灰度鱼眼矫正链路实现与验证记录

日期：2026-10-04。开发分支：`codex/fpga-geometry-correction`；工作区为 `fpga-camera-hdmi-preview/26-FPGA-Pango`。本轮先将本地 `main` 的 `82654174` 合入该 FPGA 分支，合并提交为 `27c56bd1`，再在该分支实现下述内容；未更改主工作区的未提交内容、未向 main 合并或推送。

## 核查结论与完成范围

核查时，主线 `mini_raw8_dual` 仍是 RAW8 摄像头、增强、DDR、以太网和 HDMI 回传；早期几何单元只有独立 Brown 逆映射、RGB 双线性插值与参数帧边界控制，未接入实际摄像头/DDR/HDMI 顶层。网页鱼眼矫正是 PC 软件参考，不是 FPGA 已完成矫正。因此，原状态不是“链路已完备、只差填参数”。

本轮新增独立 PDS 工程 `mini_raw8_geometry`，在板端连通：RAW 帧租约 → 灰度邻域 → 鱼眼/Brown 逆映射 → 双线性插值 → 结果及有效掩码写回 → 写可见性栅栏 → 结果发布 → HDMI。以太网保留原增强 Bayer RAW8 分支，不依赖 PC 转发或实时几何处理。保留旧工程与旧模块默认行为，没有直接替换已烧录固件。

这是多周期灰度功能实现，不是正式彩色 S1/S2/S3 的全部验收，也不是已达到 1080p30 的矫正处理器。烧录、物理画面、真实帧率及严格同帧测量本轮均未执行。

## 实现落点

- `fpga/rtl/geometry/geometry_lens_lut.v`：配置时在 FPGA 内生成双银行径向表，使用整数开方、CORDIC 与除法；不接收 PC 逐像素映射表。表正值、可表示范围与单调性检查失败时保留上一活动版本。
- `geometry_map_engine.v`：逆映射、Q12 亚像素坐标、闭区间源边界及黑边有效位；鱼眼四系数与 Brown 径向/切向模式分别解释参数。
- `geometry_config_bank.v`：14 字影子参数、逐字回读、版本/会话检查、构表、整组参数按处理帧原子生效。
- `geometry_byte_cache.v` / `geometry_gray_sampler.v`：当前帧源字缓存，因果 Bayer 2×2 灰度和双线性插值。灰度增强只执行一次；随机访问不使用旧 HDMI 历史中值滤波。
- `geometry_result_writer.v` / `geometry_gray_processor.v`：Y8 与逐像素掩码写回、最终掩码读回栅栏、完整帧发布、周期与缓存诊断。
- `geometry_read_arbiter.v` / `geometry_write_arbiter.v`：适配 HMIC 的无 RREADY 读口及 AW/W 事务归属；FIFO 为完整突发预留空间。
- `raw8_geometry_core.v` / `fpga/rtl/board/mini_raw8_geometry.v`：实际板卡管脚、摄像头启动、DDR、网口、HDMI 与 UART 的连接；结果灰度直接复制到 RGB，不重复增强。
- `host/src/pango_video/geometry_control.py` / `host/scripts/fpga_geometry.py`：只编码、下发并核对参数，不处理主视频。旧固件能力位、无完整源帧、坏表或会话改变均不能冒充已应用成功。

新增与修改的功能块已同步用途注释。修复了“结果发布与读租约同周期发生”时应锁存所选槽的发布序号、而非读取后来全局计数的问题；旧 RAW8 与新灰度链路均进行了回归。

## 实际验证结果

| 检查 | 实际结果 | 证据 |
| --- | --- | --- |
| 鱼眼映射 | 305 个独立解析向量通过，最大误差 31/4096 px，约 0.00757 px | `fpga/build/geometry_chain_20261004_181335_739/tb_geometry_lens.log` |
| Brown + 27° 旋转 | 含非零切向项的 305 向量通过，最大误差 1/4096 px | 同目录 `brown.log` |
| 径向表 | 两种模式各比较 1024 表项；允许误差 128 Q26 单位 | 同目录 lens 日志与测试源码 |
| 灰度、缓存、写回 | 两帧共 512 像素逐值核对，包含分数位平移、掩码、行填充、延迟 DDR、帧间缓存失效与配置切换 | 同目录 `tb_geometry_pipeline.log` |
| UART 参数事务 | 6073 项检查、63 次回复通过，涵盖 CRC/长度、epoch/session、重复、冲突、坏表、回读及帧边界应用 | 同目录 `tb_geometry_uart.log` |
| 帧池租约并发 | 发布与租约同周期的身份冻结检查通过 | 同目录 `tb_geometry_pool.log` |
| 新 1080p 板级核心 | 两个 1920×1080 源帧、一个完整结果、2073600 个有效 HDMI 像素、两个网络帧通过 | `fpga/build/geometry_board_20261004_182142_296/simulation.log` |
| 旧 RAW8 回归 | 正常场景 6 个完整帧、迟到 epoch 场景 5 个完整帧及网络 CRC 重组通过 | `fpga/build/raw8_board_sim_20261004_180058_205/` |
| 旧 MCU 默认顶层 | 1.8432 MHz 测试 6538 项 / 68 回复，生产 125 MHz 测试 3201 项 / 33 回复通过 | `fpga/build/mcu_protocol_20261004_174311_376/` |
| host 全量测试 | 106 项通过，0 失败、0 错误、0 跳过 | `host/reports/geometry_host_final_20261004.json` |

完整板级核心仿真使用项目内原生 FIFO 及 PDS 的 Logos2 usim/vsim 库；DDR 为含响应延迟、突发/RID 检查的模型，不包含实际 DDR PHY 校准和物理摄像头。1080p 测试使用非恒等半/四分之一像素平移、均匀源图和应裁掉的末行末列；非均匀像素插值在小帧逐值测试中覆盖。不能把仿真输出当成板上实测图像。

鱼眼及 Brown 的误差只覆盖上述参数和向量，不能外推到全部合法参数范围。host 的首次全量尝试在不含 OpenCV 的打包 Python 中有两个导入错误，原始失败报告保留为 `geometry_host_20261004.json`；随后使用已经安装 OpenCV/numpy 的 Python 3.12.4 完成全部 106 项测试，没有安装依赖或修改系统设置。

## 处理速度与 PDS 状态

完整帧测试锁存第一次成功结果的 96,726,247 个 mem_clk 周期；仿真时钟 125 MHz，对应约 0.77381 秒/帧。这只是该 Brown 平移测试的处理延迟，不是物理板卡、用户鱼眼参数或网络的实测 FPS。其倒数约 1.29，远低于每 33.33 ms 生成一张新矫正图的 1080p30 要求。固定 30 Hz HDMI 会重复显示上一完整结果；不能据显示接口刷新率声称矫正已达 30 FPS。

PDS 使用当前安装的 2022.2-SP6.4、Logos2 PG2L100H-6FBG676、已有原生 DDR/FIFO/PLL IP 和旧板级约束。通过原生 Tcl 生成 `.pds`，不手写 PDS S 表达式。当前位宽优化后的工程编译、综合和器件映射成功；综合报告为 18,707 LUT（28.09%）、21,249 寄存器（15.95%）、29 DRM（18.71%）、78 APM（32.50%）。

最终原生布线/时序运行目录为 `fpga/build/mini_raw8_geometry/native_20261004_181139_573/`。布线成功，最终 min/max STA 报告为 `Some Constraints Violated`，125 MHz `ddrphy_sysclk` 慢角建立时间 WNS=-4.240 ns、TNS=-4424.548 ns、2751 个失败端点；快角建立时间 WNS=-0.713 ns。该时钟域的保持时间检查通过，但不能因此认定整体时序通过。结果记录确认本次运行输入哈希未变化、未生成位流、未上板。

最差路径从 `u_core/u_geometry/u_map/xq[35]`，经过归一化范围保护逻辑与级联 APM，至 `N237_m4/gopapm/PI`；不是摄像头启动或网页处理问题。对应坐标平方/乘积的宽乘法仍需显式拆分、增加级间寄存器。仅把功能 FSM 分成多周期，并不自动缩短单个时钟内的级联乘法路径；后续要先解决这一时序瓶颈，再扩展持续像素流水线的吞吐。

第一次 15 分钟布线预算曾超时；当前 30 分钟预算下完成路由，未放宽时钟、PHY 要求或添加广泛 false path。独立 PLC DB 诊断仅用于观察，既不是最终走线延迟，也不能替代 min/max STA；单独加载未携带全部 FDC 时已改为显式加载相同约束。最终走线报告见该运行目录 `stage_report.rtr`，机器状态见 `result.json`。

本轮未导出可发布位流；未关闭的时序使生成门槛失败，脚本以非零状态退出。构建脚本只有在新鲜 min/max STA 全部约束通过、约束对象有效、输入哈希未变化时才允许显式 `-EmitBitstream`。DVP 外部数据偏斜/建立保持、RGMII PCB 延迟与真实显示信号仍需要物理核验。

## 参数与 MCU 入口

完整格式与命令见 [FPGA 灰度鱼眼矫正参数接口](../../output/FPGA灰度鱼眼矫正参数接口.md)。支持当前手动近似鱼眼预设 fx=770、fy=752、cx=945、cy=553、D=(0.121,-0.118,0,0.036)、参考 1920×1080、输出水平 FOV=139°；不是已标定参数。冷启动默认灰度几何旁路，UART 下发后才启用相应模型；配置为易失状态。

MCU 角度环境事件保留可读端口、事件序号、会话与 FPGA 接纳时间，并在处理帧边界锁存结果上下文。尚不直接转成几何旋转：实际云台轴、零点、坐标系、曝光时刻与事件时延需要标定。显式人工平面旋转可由参数编码器指定，不把它冒充实际云台补偿。

当前网络仍为增强 Bayer RAW8 描述符 RENH/v2，不能称为原始 S0 或矫正结果。灰度结果使用独立 0x04000000/0x04400000/0x04800000 三槽，每槽 4 MiB、Y stride=2048、掩码偏移 0x280000；此布局与正式 RGB 同帧快照布局互斥。普通 HDMI 采集的源帧身份保持 null/unverified。

## 重现与后续门槛

在本分支工作目录执行：

```powershell
powershell -File fpga/scripts/sim_geometry_chain.ps1
powershell -File fpga/scripts/sim_geometry_board.ps1
python host/scripts/test.py --report host/reports/geometry_host_retest.json
powershell -File fpga/scripts/build_mini_raw8_geometry.ps1 -Stage report_timing
python host/scripts/fpga_geometry.py host/config/calibration/fisheye-user-reviewed-20261002.json
```

最后一行只离线编码，不打开串口、网卡或 JTAG。真正下发需新固件、有效 epoch/session、唯一串口使用者及显式 `--port`，ACK 后仍需核对活动参数版本和首次生效源帧号。构建会生成自己的 `fpga/build/` 输出；不要同时运行两个写同一 native implementation 目录的构建。

下一步需要完成最终时序收敛；为新结果 30 FPS 重构计算流水线和突发/分块缓存；再做真实鱼眼画面与校准误差、完整彩色 ISP、同帧证据及 MCU 姿态同步验收。此次没有烧录、擦除 Flash、自动改主线、推送或改写官方/reference 资料。

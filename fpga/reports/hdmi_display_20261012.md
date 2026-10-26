# HDMI RGB888 / 1080p30 局部优化与验证

2026-10-12，05 专项。实施依据：[显示方案](../../output/FPGA分区优化交接/05_HDMI显示优化方案.md)、[总览](../../output/FPGA分区优化交接/README.md)、跨端方案 §7 和主设计 §3/§7。优先级为性能 > 时序 > 资源。

**完成正式显示局部 RTL、事务模型回归和 PG2L100H 隔离 PnR；尚未接入共享板级顶层/真实 DDR 跨域桥/帧池事务适配器，未上板。** 普通 HDMI 回采身份仍 `null/unverified`，既有过温告警及硬件放行限制保持。

## 1. 改动与候选选择

新增 `fpga/rtl/video/` 中的固定扫描、双完整行预取、RGB888 解包、显示引用与容错控制、TMDS 封装及 PnR 夹具。源字节顺序 R/G/B、6144 B DDR stride、5760 B 有效行；不改变外部网络/快照协议，不在图像内写 OSD 或标识。既有两套顶层、工程、PLL、全局约束、诊断 vendor 和 03/04 模块均未修改。

建立了同功能、同 40% 像素时钟、同器件与夹具的两个候选：

- A：64 B reservoir，变位移追加 RGB beat，完整扫描/引用/计数功能齐全。
- B：活动区在剩余 6/7/8 B 时启动同步 RAM 读取，响应时只剩 0/1/2 B；改为三个固定追加位置，reservoir 为 34 B。增加残留不变量故障检测；整行缓冲容量不缩减。

B 保持每像素时钟一个 RGB888 像素，服务期限/外部 DMA 事务不变。选用 B；下面资源降幅只比较 A/B 的局部夹具，不能写成整机或旧 720p 工程优化百分比。

| 项目 | 候选 A | 候选 B | 层级与含义 |
| --- | ---: | ---: | --- |
| 正式有效模式 | 1920×1080，30 Hz | 相同 | 扫描计数/74.25 MHz 计算，离线 RTL 验证 |
| 活动区启动间隔 | 1 pixel clock | 相同 | 正常显示无停顿 |
| RGB888 行有效长度 / stride | 5760 / 6144 B | 相同 | 逐字节地址与像素检查 |
| 连续竞争读下最大行填充 | 1564 pixel cycles | 1564 pixel cycles | 1920×16、实际 DMA RTL、双客户端模型 |
| LUT | 2774 | **1940** | 同夹具综合报告，减少 834 / 30.06% |
| 寄存器 | 2345 | **2104** | 同夹具综合报告，减少 241 / 10.28% |
| DRM36K / APM | 8 / 0 | **8 / 0** | 完整行银行不缩减 |
| 原生 OSERDES / GPLL / IOCLKBUF / IOCLKDIV | 8 / 1 / 1 / 1 | 相同 | 原生 4 通道、每通道主从串行器 |
| pixel→pixel setup WNS，slow corner | 5.564 ns | **6.404 ns** | 最终 post-PnR report_timing，增加 0.840 ns |
| ref27→pixel setup WNS，slow corner | 1.075 ns | **1.194 ns** | 启动/释放路径仍计时 |
| serial→serial setup WNS，slow corner | 1.746 ns | **1.746 ns** | 371.25 MHz 原生时钟 |
| pixel→pixel hold WHS，fast corner | 0.146 ns | **0.118 ns** | 正余量，取最终原始报告 |
| 已约束路径 TNS/THS | 0 | 0 | slow/fast、setup/hold/recovery/removal 均检查 |

夹具总量包含本地 LFSR 流量源/完成状态/计数观察逻辑；B 的显示子层为 1521 LUT、1263 FF、8 DRM，其中 reader 为 1231 LUT、794 FF、8 DRM。夹具中部分常量元数据被优化，**不能据此给完整 CDC/帧池/DDR/整机预留资源签核**。estimated frequency 不是实板可提频证据；正式模式仍保持 74.25 / 371.25 MHz。

## 2. 预取、期限与延迟

使用两个完成后才置 READY 的整行 RAM，行号与 bank 一起校验。只读有效像素，最大 16×32 B 突发，在 4096 B 物理列边界拆分。最后读 beat 后必须收到/ACK `done`，才能提交行；cancelled/error/tag 不匹配不得提交。待接受 VALID 不因失锁撤回，接受后 cancel 并排空。

默认扫描为 HT=2200、VT=1125，H_SYNC/BP/FP=44/148/88、V_SYNC/BP/FP=5/36/4；正同步。行 n 最末像素 `h=2111` 消费到行 n+2 prepare `h=188`：

```text
2*2200 + 188 - 2111 = 2477 pixel cycles
首个行头 VALID→完成行 READY：2477 - 2(发请求) - 1(严格早于 prepare) = 2474 cycles
```

预算约 33.32 μs。实际 DMA + 持续竞争读回归最大行填充 1564 周期，余量 910 周期、约 12.26 μs；有行需求时最长未接收 beat 计数 141 周期、约 1.90 μs。1080p 全尺寸独立 DMA 模型最大行填充 809 周期、最长未接收 beat 26 周期。

上述是明确事务模型下的局部结果；04 还必须证明整个行的最坏服务上界，包含七客户端/网络/写流量、刷新、真实控制器、CDC 及完成栅栏。单个无服务间隔或平均 186.624 MB/s 不能独立证明行 deadline。当前不声称整机混合服务已经满足。

场消隐提供首行预取时间。场边界 acquire 后到第一活动像素约 90392 周期；任意 READY 时刻且 release ACK 不背压、旧事务已经排空时，上界为一场周期加前置消隐，约 **34.55 ms**。测试在特定 READY 时刻测到最大 99280 周期、约 **1.337 ms**，不是任意到达时刻的最坏保证。release 被背压或 DDR 不能按期限排空时，可能多场等待，计 repeat/failed/empty；没有无条件有限延迟承诺。

`max_no_service_cycles`、`low_water_cycles` 是像素域计数；low water 为少于两个完整行就绪的持续时间。恢复时保持扫描，把坏帧剩余部分置黑、清楚计数，并等待下一合法场边界。不能用后续旧像素填丢失位置，也不能暂停像素时钟。

## 3. 引用、身份与统计

仅在场边界原子更换完整结果槽；整帧保持 base/slot/generation/epoch/frame_id。无新帧时整帧重读同一引用。释放需同时排空 DMA done ACK、客户端返回队列和本地预取读；关闭/失锁可在排空后场外释放。共享 03/04 的 acquire/release、issue/complete token/ticket 与跨域适配要求已冻结在 [模块 README](../rtl/video/README.md)，不能直接跨时钟接线。

RGB/HS/VS/DE/坐标/tag 共用一拍输出寄存；TMDS 编码再三拍。RGB 字节到 TMDS 通道为 R→lane2、G→lane1、B→lane0，只有蓝通道携带消隐 HS/VS 控制。内部 tag 是源码/仿真证据，未嵌入有效像素，也不提供普通采集卡源身份。

统计满足 `scan=new+repeat+failed+empty`，仅完整成功输出的帧计 new/repeat；欠载 event 每个受影响帧首次发生计一次。`underflow_pixels` 计持有引用期间的黑色容错采样；引用释放后的无源黑色不归入该计数，仍由 failed/empty 扫描统计覆盖。处理帧由 03/06、采集设备帧由 host 独立计数。正式精度继续使用板端同帧 S1 与 S2/S3 快照，不把此 pattern 验证当作摄像头来源证明。

## 4. 实际执行的验证

使用 Icarus Verilog 12.0、PDS 2022.2-SP6.4 build146967；ModelSim SE-64 10.1c 编译安装版原生库后尝试仿真。测试均为本机离线；没有下载器、采集卡、功率仪或真实 DDR 操作。

| 回归 | 实际结果 | 覆盖范围 |
| --- | --- | --- |
| 故障小尺寸 | PASS；4 new、4 repeat、3 failed、1 underflow event | 场切换、release ACK 背压、空行、黑色恢复、失锁时 stalled VALID、取消排空、错误 generation |
| 真有效尺寸 1080p | PASS；**6,220,800 个有效像素**逐像素正确、2 new+1 repeat、failed=0、underflow=0 | 三帧有效图像、两个完整总扫描周期及第三帧有效区；首末像素、跨 beat、逐行 poison padding、HS/VS/DE/tag、随机停顿 |
| 实际 DMA 竞争 | PASS；1920×16、3 帧、**92,160 个像素**，持续另一客户端 16 beat 读，failed=0、underflow=0 | 真实 `ddr_native_dma` 同钟连接、紧急/普通仲裁、byte→word 地址转换、无 RREADY 原生响应模型、返回/完成栅栏；并非 1080p 整机混合验收 |
| 三通道 TMDS | PASS；16,412 项检查 | 所有 byte 值、长活动串、独立整数 running disparity、四消隐符号、lane 对应、三拍 tag、编码器复位 |
| 既有 720p | PASS；1,843,200 像素、4,319,640 项检查 | 原有 raster/单拍 FIFO 模型/编码链未回退 |
| 原生串行器 1024 符号 | **本轮运行未完成** | 模型/RTL 编译成功，`qhsimvl/msimhdlsim` 许可证 checkout 失败；无新的原生 bit 顺序验证声明 |
| PG2L100H 隔离 PnR | PASS，已约束内部路径 | 固定 native PLL/IO 时钟/OSERDES packing、双行 DRM、两角 min/max 与局部复位；外部 TMDS/电气未签核 |

可移植 TMDS 回归使用显式 `HDMI_ENCODER_ONLY` 串行器占位，只核验真实 encoder 输出与 tag；**占位不模拟串行输出，不能作为 bit 顺序/原生 reset/锁定实测证明**。占位文件不加入综合或原生仿真工程。

## 5. 原始证据与复现

- B 全部五项回归：`fpga/build/hdmi_display/sim_20261012_155128_953/`，冻结源码在 `source/`，哈希 `source_snapshot.json`，逐项日志和 `result.json`。
- B PnR：`fpga/build/hdmi_display/pnr_20261012_155142_155/`，完整源快照、`report_timing.console.log`、`report_timing/hdmi_display_pnr_probe.rtr`、`synthesize/hdmi_display_pnr_probe.snr`、`place_route/clock_utilization.txt`。
- A 同配置回归：`fpga/build/hdmi_display/sim_20261012_154856_111/`；A PnR：`fpga/build/hdmi_display/pnr_20261012_154130_711/`。两者为可比较的 40% 波形版本。
- 首轮探索：`pnr_20261012_153631_729/` 按默认 /5 产生 50% 约束，仅保存探索证据，不用于最终时序签核/对比；PDS 默认 all flow 还生成了夹具 `.sbit`，**该文件不能发布/上板**。最终脚本显式 `-run report_timing`，没有生成下载位流。
- 原生仿真受阻：`fpga/build/hdmi_display/tmds_20261012_153418_823/`；`native.log/compile.log/tmds_serializer.log` 与 `vendor_source.json` 保留实际编译和许可证失败。
- 本轮机器核验：`fpga/build/hdmi_display/evidence_20261012.json`，绑定源码快照、五项回归、PnR 两角结果和 A/B 对比；外部签核/硬件/回采身份显式未验证。

```powershell
./fpga/scripts/sim_hdmi_display.ps1
./fpga/scripts/build_hdmi_display.ps1
python fpga/scripts/audit_hdmi_display.py --sim fpga/build/hdmi_display/sim_20261012_155128_953 --pnr fpga/build/hdmi_display/pnr_20261012_155142_155 --baseline fpga/build/hdmi_display/pnr_20261012_154130_711 --out fpga/build/hdmi_display/evidence_20261012.json
```

这些命令仅在 `fpga/` 内写证据。模拟器参数可覆盖其安装路径；需要原生串行器复验时运行 `sim_hdmi_tmds.ps1` 并提供有效现有许可证环境。脚本冻结输入，避免长回归期间修改被误归于已编译输入。

## 6. 官方资料与时序限制

只读查阅安装版 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/`：Timing Analyzer §4.1（PDF pp.14–16，min/max、路径筛选与例外）、UCE §1.3.4.1/2（PDF pp.19–22，generated clock 与 edges）、Physical Constraint Editor/Route Constraint Editor 的 DB/约束作用范围，以及 ADS Synthesis §5.16（PDF pp.94–95，同步 inferred RAM）。提取内容没有写回官方目录。

核对安装版 `arch/vendor/pango/verilog/simulation/GTP_OSERDES_E2.v`、`example/PG2L100H_lvds4to1/rtl/pgd_ddr_lvds4to1_tx_top.v`，以及 MINI `2_Demo/2_10_hdmi_loop/2_10_hdmi_loop/source/outputserdes.v` 的主从级联。官方 LVDS 例程仅说明原语/专用启动复位，不能把 DDR4TO1 例程当作本板 TMDS10:1 已完成验证。板型/管脚使用本项目 PG2L100H-6IFBG676 的 `fpga/config/board.json`；未沿用 200H 专用 pin。

最终 FDC `-edges {1 5 11}` 与报告 `{0.0000 5.3870}` / period=13.4680 ns 一致。两个 false path 仅为外部 reset 和专用 `video_div_reset_n` 初始化寄存器；pixel 数据、TMDS encoder/serializer 路径没有新增 false path。最终报告包含 slow/fast 的 setup/hold/recovery/removal/pulse width；没有按逻辑层数筛选来代替最差余量。

外部 HDMI/status pin 仍有 unconstrained output 提示，reset 是异步例外；驱动/电气、真实 TMDS 接收窗口/PLL 抖动/板级走线和实板热稳定性尚未签核。`All Constraints Met` 只指当前已施加的内部约束。

## 7. 共享集成与尚未覆盖

共享文件由集成负责人合并：向正式工程添加四个业务模块和原有 `tmds_encoder/tmds_serializer`，保留已验证的 native 时钟/专用启动复位，替换固定符号输出；把 03 DST 的按序 acquire/release/token/ticket 与 04 显示读 client 通过经过验证的 CDC 接入。完整端口、地址/数据顺序、握手和预算见模块 README。

仍须完成：实际 DDR 域 CDC 与独立时钟停止恢复、03/04 真正事务适配、七客户端/刷新/网络/快照混合最大服务、摄像头/ISP/矫正正式链集成、原生串行器本轮功能回归与 SDF 后仿、目标整机 PnR/电气、真实 HDMI1080p30 与 RGB24/BGR24/色彩范围/长稳/来源证据。无硬件操作，未解除过温告警，不宣称完整相机系统或硬件验收已完成。

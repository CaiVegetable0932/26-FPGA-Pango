# 20 点标记与 FPGA 矫正流水线集成记录

## 范围与验收状态

工作分支：`codex/fpga-geometry-correction`。Jetson main `8873a2392` 已通过
`f7af90e2c` 合并进入本分支，保留 Linux/Jetson host 及独立 GPU 软件参考。
本轮不烧录、不访问摄像头/串口/JTAG，不修改官方资料或系统设置。

当前记录为构建中间记录；只有最终 min/max STA 合格、源码哈希匹配并成功导出
SBIT/SFC，才能将发布包标为离线可上板候选。不得将此前镜像的板测结果用于本候选。

## 数据通路改造

- `geometry_map_stream.v`：输出像素到源像素的定点空间流水线，替换每像素复用
  状态机；保留 Q26/Q16/Q12 截断规则，支持背压和信用队列。独立旧实现作为数值参考。
- `geometry_window_cache.v` / `geometry_window_sampler.v`：1024 个 256-bit 字缓存，
  按 16 行 × 64 字寻址；三个双读端口镜像同时提供采样窗口，命中可每拍接受一点。
  同步 RAM 读端口与填充端口互斥，不依赖碰撞时读写返回值。
- `geometry_gray_stream.v`：灰度、原有增强及双线性采样分级流水，原图模式仅绕过
  几何映射，不改变亮度/ISP 阶段。
- `geometry_result_stream_writer.v`：像素打包与 DDR 写事务分离，队列承受 AW/W
  独立背压；有效性掩码和末尾读回 fence 成功后才发布完整结果帧。
- `geometry_gray_processor.v`：只在帧启动采纳参数和模式；前帧 token 排空后才
  进入下一帧，防止坐标、采样、写回使用不同版本。

缓存探针使用当前安装 PDS 2022.2-SP6.4：
`fpga/build/cache_ram_probe_20261006_224126_835`。
单个 1024×256 双读 RAM 被识别为 TRUE_DUAL_PORT / READ_BEFORE_WRITE，使用 8 DRM；
旧互斥读模板会复制为两个 SDP、使用 16 DRM。此处是独立探针，整板资源另行统计。

## 标记与控制

`geometry_marker_catalog.v` 从原生图像尺寸定义与 JS 相同的 20 点、编号和颜色。
`geometry_marker_map.v` / `geometry_marker_table.v` 在 FPGA 内计算正向标记映射；
与图像逆映射分开，越界位置不钳至边缘。当前前向支持鱼眼、旁路和无切向项的
Brown；切向 Brown / 奇异变换返回明确失败状态，不能冒充有效坐标。

`geometry_marker_overlay.v` 位于 HDMI 末端，黑色描边、彩色点及编号；RGB/HS/VS/DE
统一延迟两拍。没有摄像头、网络或归档写回路径。
`geometry_view_snapshot.v` 将元数据绑定结果槽，经 held-bus request/ack 跨时钟域
传递，并在相应显示帧边界切换。元数据 generation 只在实际显示配置变化时递增，
不是 HDMI 源帧编号。

- CAPS 新增 `0x100` 显示控制能力。
- `0x35`：epoch/session + revision + flags + size，选择原图/矫正、显示/隐藏标记。
  默认 size=10，允许 4..32；回复区分请求 revision 与实际显示 revision。
- `0x34` bank 2：实际参数版本、控制版本、可见性、状态及每点源坐标、目的 Q12
  坐标和 RGB。host 扫描前后检查 generation，变化时重试。
- 完整协议及用法见 `fpga/reports/geometry_markers_20261006.md` 与
  `host/docs/FPGA几何与显示Web接口.md`。

网口当前基线是 FPGA 增强 Bayer RAW8（RENH v2），不是传感器未处理 S0；标记不
改变其像素。host 只按板端元数据绘制叠加层，计算机矫正明确标为独立软件参考。
没有可信 HDMI 身份时 frame_id 保持 `null/unverified`，不使用到达顺序配对。

## 已执行全尺寸功能验证

| 测试 | 证据目录 | 结果 |
| --- | --- | --- |
| 1080p 默认鱼眼 | `fpga/build/geometry_board_20261006_224235_360` | PASS |
| 1080p 原图模式 | `fpga/build/geometry_board_20261006_224930_823` | PASS |
| 几何/参数/物理 UART 链 | `fpga/build/geometry_chain_20261006_224849_893` | PASS |
| 20 点/异步切换/元数据/242 帧叠加 | `fpga/build/geometry_markers_20261006_230740_712` | PASS，41 个输入前后哈希相同 |
| 1024/64/256 字窗口等价 | `fpga/build/geometry_window_20261006_224711_815` | PASS，860,160 像素 |
| 三模型流水映射 | `fpga/build/map_stream_20261006_224711_200` | PASS，各 2048 向量 |
| 排队写回/错误 fence | `fpga/build/stream_writer_20261006_224710_218` | PASS |
| 缓存周期等价 | `fpga/build/cache_timing_20261006_224710_050` | PASS，200,000 检查 |
| 原有算法效率等价 | `fpga/build/geometry_efficiency_20261006_224712_499` | PASS |
| MCU UART 默认/125MHz | `fpga/build/mcu_protocol_20261006_224715_944` | PASS，6538/3201 检查 |
| 回复队列 RAM | `fpga/build/mcu_reply_queue_ram_20261006_224716_390` | PASS，101,306 检查 |
| 回复译码 16 组合 | `fpga/build/mcu_decoder_equivalence_20261006_224716_290` | PASS，2,097,152 检查 |
| 状态快照 | `fpga/build/mcu_snapshot_20261006_224718_038` | PASS，100,000 周期 |
| RTL 网口报文与 host 解码 | `fpga/build/praw_protocol_20261006_224837_803` | PASS，含完整 1080p RAW |

两种全帧测试各输入 2 帧，生成 2 个结果；逐像素检查完整 HDMI 光栅，以及
4,147,200 个源 RAW 字节、4,147,200 个网络字节。鱼眼有效性与独立解析参考比较；
只有距边界 0.025 像素以内的 327 点允许边界量化差异，不放宽其它像素检查。
全帧场景使用不同恒定灰度作为内容；非均匀像素、随机 DDR 延迟与背压由窗口采样
旧实现逐字节比对测试承担，不宣称全帧已经使用实拍图像验证。

默认鱼眼首结果 3,112,712 个 125 MHz 模拟时钟周期，即 24.901696 ms。
缓存 miss=66,836、hit=1,390,820；与独立全帧访问轨迹一致。
此前 256 字缓存候选为 7,819,721 周期，约 62.56 ms。
原图首结果 3,082,297 周期，即 24.658376 ms。
这些是仿真内存模型下的处理耗时，**不是**摄像头实测 FPS、网络完整帧率、
FPGA 实板结果帧率或浏览器显示帧率，也不保证所有参数组合均满足 30 FPS。

## 原生构建（待最终回填）

首轮 `fpga/build/mini_raw8_geometry/native_20261006_224308_400` 已完成原生流程，
但最终 STA **失败，因此没有生成位流**；输入哈希未改变。其 map/placed/routed
数据库和报告已保存在本目录的 `checkpoint/`，不被下一轮共享 implementation 覆盖。
综合资源：41,072 LUT（61.67%）、51,095 FF（38.36%）、72.5 DRM（46.77%）、
103 APM（42.92%），无 latch。综合估计不替代布线后 STA。
新增 CDC 约束只覆盖第一同步级与协议保证稳定的 held bus；不豁免普通流水线时序。

首轮真实布线结果：全部连接布通；最终 mem setup -1.111 ns，DDR 跨时钟 setup
-2.847 ns，DDR 读有效 hold -0.838 ns。布局报告曾显示 +0.152 ns，说明布局估计
不能替代实际布线签核。失败原因包括 UART 地址/银行译码到回复数据的长路由、
缓存读字节选择到增强 ROM 的寄存级被吸收，以及 DDR 写控制长绕线/读有效短路径。

第二轮修复：保护 `geometry_gray_stream.raw_q` 的真实寄存级；去掉元数据比较
padding 的保留常量 flop（其 reset 曾被综合为 SRB 伪时钟）；对实测 DDR 写控制
两个长绕线网增加 geometry 专用原生 RCF 优先级；切换 seed 1，保留 decongestion 3。
全部时钟、PHY 相位、setup/hold 预算不变。配置读回进一步优化及本轮重新仿真、
综合/布线结果待回填，不能继续使用首轮输入哈希的旧仿真当作最终源码验证。

第二轮已冻结源码并启动 `fpga/build/mini_raw8_geometry/native_20261007_001305_839`。
配置块新增 `PREDECODE_READ`，默认 0 保留即时组合接口；UART 整板显式启用 1，
只预译码地址/银行 one-hot，不缓存数据。UART payload 完成后还有 CRC 字节时间，
故不会改变接受沿、回复延迟或实时版本/状态。专项 RTL 仿真记录：125MHz 下
最短地址稳定 21,702 个边沿、112 个回复、76 次 READ，含接受前状态更新。

| 第二轮冻结源码验证 | 证据目录 | 结果 |
| --- | --- | --- |
| 1080p 默认鱼眼 | `fpga/build/geometry_board_20261007_001326_601` | PASS，3,112,712 周期 |
| 1080p 原图 | `fpga/build/geometry_board_20261007_001748_169` | PASS，3,082,297 周期 |
| 几何/参数/UART 链 | `fpga/build/geometry_chain_20261007_001014_418` | PASS |
| 标记/帧边界/元数据 | `fpga/build/geometry_markers_20261007_001029_277` | PASS，242 叠加帧 |
| 窗口字节等价 | `fpga/build/geometry_window_20261007_000649_799` | PASS |
| 历史算法默认接口等价 | `fpga/build/geometry_efficiency_20261007_002001_207` | PASS |
| READ 默认等价与双时钟 UART | `fpga/build/geometry_config_predecode_20261007_000935_174` | PASS |

第二轮综合资源：40,553 LUT（60.89%）、51,036 FF（38.32%）、72.5 DRM、103 APM。
综合网表确认 raw_q 为 `GTP_DFF_E`，具备 `PAP_PRESERVE=TRUE`、
`PAP_ALLOW_RETIMING=FALSE`；地址预译码同样为独立寄存器。此项只证明结构实现，
不等于最终布线时序通过。

第二轮在布线前主动停止：检查发现 PDS 原生工程只保留一个 RCF，新增 RCF
替换了原有 DDR/HDMI 优先级。未使用该轮生成位流。其 map/PCF/综合报告已保存到
`native_20261007_001305_839/checkpoint/`。
第三轮 `native_20261007_003538_119` 合并所有 6 条原有优先级和 2 条新增优先级，
只加载一个 RCF；只读单一 RCF 检查已通过。RTL 没有再变更，沿用第二轮冻结源码
验证证据。辅助重布线脚本同样改为只加载合并 RCF，发布前再次执行检查。

第三轮最终结果：全部连接布通，详细布线 352 次迭代/1021.16 秒；最终 STA
仍失败，门禁未生成位流，输入哈希一致。DDR core→phy1 setup 已恢复为
+0.903ns，phy1→core hold slow/fast 为 +0.640/+0.142ns，core→phy1 hold 为
+0.463/+0.108ns。剩余 mem setup -0.970ns：DDR 输出长连线与字节选择直达
`geometry_window_cache.saved`，以及 DRM 读选择直达同一寄存器。
RGMII D21 setup slow/fast 为 -0.009/-0.101ns，hold 为 +0.314/+0.261ns。
所有数据库和报告保留在该轮 `checkpoint/`。

下一轮改动：缓存响应及 miss 保存路径继续寄存分级；geometry 专用引脚副本
`geometry_pins.fdc` 仅将 D21 从 12mA 恢复为其余 RGMII 输出使用的 16mA。
共享 `pins.fdc` 不变。此电气调整必须重新通过双角 setup/hold，不凭估算放行。
原生工程生成后已增加单一 RCF 的自动构建前审计。

第四轮冻结源码构建：`native_20261007_014344_816`，304 项构建输入哈希已核对，
RCF 自动门禁通过。缓存新增 A/B 两槽弹性流水、16:1/4:1 分级字节选择，以及
DDR 完整 beat→提取字节→保存窗口三级；miss 填充会使预取槽失效并重放。
命中 II=1，响应接口不增加 RREADY 假设；done 与本地流水排空分别管理。
RTL cache SHA256：`EAFFC22FB126A34529CDD202DA6675EF226960C450823E81A11D27FED0DB0C63`。

| 第四轮冻结源码验证 | 证据目录 | 结果 |
| --- | --- | --- |
| 1080p 默认鱼眼 | `fpga/build/geometry_board_20261007_013758_511` | PASS，3,291,847 周期 / 26.334776ms |
| 1080p 原图 | `fpga/build/geometry_board_20261007_014402_376` | PASS，3,280,934 周期 / 26.247472ms |
| 几何/参数/UART 链 | `fpga/build/geometry_chain_20261007_014457_336` | PASS |
| 标记/帧边界/元数据 | `fpga/build/geometry_markers_20261007_014518_122` | PASS，242 叠加帧 |
| 窗口字节等价/协议错误 | `fpga/build/geometry_window_20261007_013729_730` | PASS，1024/64/256，命中 II=1 |
| READ 默认等价与双时钟 UART | `fpga/build/geometry_config_predecode_20261007_014602_016` | PASS |

334 项回归输入哈希全部匹配。窗口测试增加 grant 同拍返回、延迟 done、
迟到/重复响应、busy/queued/pipeline invalidate、长背压与 miss 后重放。
两种全帧仍各核对 4,147,200 源 RAW 字节和等量网口字节，未改变算法结果。
上述耗时仍仅是 RTL/行为 DDR 模型测量，不能替代实板四类 FPS 验收。

第四轮综合：41,521 LUT（62.34%）、51,900 FF（38.96%）、72.5 DRM
（46.77%）、103 APM（42.92%），无 latch。综合网表确认新增完整响应寄存器、
提取字节寄存器及 RAM 字节选择中间寄存器均被保留且禁止 retiming。
映射数据库、原生 PCF、布局数据库、综合报告和源码清单已逐文件核对 SHA256，
保存在本轮 `checkpoint/`。布局估计最差余量 +0.173ns，仅供阶段诊断；
最终发布必须使用布线后的双角 setup/hold 结果，不以此估计放行。

第四轮于 2026-10-07 03:49 完成，**最终 STA 失败，没有位流**。详细布线
585 次迭代 / 4869.05 秒，全部连接布通；完整原生 compile→STA 耗时约 2h05m。
最终核心 mem setup 为 -0.503ns（40 个失败端点，TNS -3.908ns），最差路径已
从缓存字节选择移到配置 READ→MCU 回复，主要为 7.125ns 路由延迟。
DDR core→phy1 setup -1.716ns，phy1→core setup -0.696ns；core→phy1 hold
slow/fast -0.801/-0.775ns，phy1→core hold -0.340/-0.516ns。RGMII setup
slow/fast +0.153/+0.170ns，而 hold -0.077/-0.018ns，故 16mA 不能仅按 setup
结果放行。最终报告与 PNR 数据库已经逐文件核对哈希并保存在该轮 checkpoint。

第五轮 `resumed_20261007_035557_253` 从上述相同映射数据库重新布局，seed=2、
decongestion=3；RTL、引脚、电气属性、时钟、时序预算和回归输入均不变。
这是原生物理实现重试，不能把第四轮失败结果或布局估计改标为成功。

第五轮于 04:40 完成，最终仍失败，未生成位流。全部布通，详细布线
324 次迭代 / 1305.53 秒；最终 mem setup -1.078ns（110 个失败端点），
最差路径为 MCU payload 地址 → bank-2 的 /5 地址译码 → 读回复。
另一条 -0.616ns 路径是标记除法器 96 位 bits 寄存器的共享 CE 链。
DDR core→phy1 setup +0.248ns，phy1→core setup +2.034ns；前者 fast hold
仅剩一端点 -0.037ns，后者 fast hold +0.112ns。RGMII 五个数据/控制端点
hold 全部失败，slow/fast 最差 -0.089/-0.030ns，setup +0.335/+0.296ns。
这些数值取自 04:40:13 独立 STA，而不是 PNR 中间摘要。

第六轮 `native_20261007_045840_329` 于 04:58 启动，冻结如下最小修正：

- 元数据地址 /5、范围和回复路由选择提前一拍译码；实际板级 UART 载荷早于
  CRC 到达，回复数据、generation 和实际版本仍在接收边沿读取当前值，不预取旧数据。
  默认零延迟组合接口保留，只有板级明确启用预译码。
- 除法器 bits 仅为内部暂存，空闲时允许移位，消除 96 位共享 CE；非零除法仍
  96 拍、零除仍当拍完成，忙时 start 与复位行为逐周期不变。
- 五个 RGMII 数据/控制 PAD 改为 12mA，TXC 保持 16mA，FAST、位置、时钟、
  延迟预算和 PHY 相位不变。继续 seed=2/decongestion=3 和原有合并 RCF；
  没有直接移植旧 DDR 布局，也没有豁免唯一 fast hold 违例。

| 第六轮冻结源码验证 | 证据目录 | 结果 |
| --- | --- | --- |
| 1080p 默认鱼眼 | `fpga/build/geometry_board_20261007_045436_252` | PASS，3,292,831 周期 / 26.342648ms |
| 1080p 原图 | `fpga/build/geometry_board_20261007_045432_947` | PASS，3,281,185 周期 / 26.249480ms |
| 几何/参数/UART 链 | `fpga/build/geometry_chain_20261007_045432_983` | PASS |
| 标记/帧边界/元数据 | `fpga/build/geometry_markers_20261007_045433_346` | PASS，242 叠加帧 |
| 元数据预译码专项 | `fpga/build/view_predecode_20261007_044922_455` | PASS，9249 对比、41 次动态更新读取 |
| 除法器逐周期 miter | `fpga/build/marker_divider_20261007_044905_041` | PASS，3 种子 / 746685 周期 |
| 除法器 ADS 结构探针 | `fpga/build/marker_divider_probe_20261007_045001_799` | 96 个 bits FF 的 CE 全部消除，426 LUT/426 FF 未增加 |

两种整板回归仍各核对 2 个输入/结果帧、2073600 HDMI 像素、4147200 RAW
字节与 4147200 增强网口字节。首结果周期包含配置控制启动时序；只是行为 DDR
仿真耗时，不是实板持续 FPS。此节记录构建输入及回归，**尚不代表第六轮 STA 通过**。

第六轮完整综合于 05:11 结束，41,528 LUT、51,909 FF、72.5 DRM、103 APM，
无 latch。新鲜综合网表显示地址预译码的 preserve/no-retiming 属性有效；
`geometry_marker_divide.bits[95]` 为无 CE 的 GTP_DFF_C。器件映射于 05:15 结束，
映射 ADF、PCF、综合报告及输入清单已复制到本轮 checkpoint 并逐文件核对哈希。

附加控制验证 `fpga/build/geometry_core_read_uart_20261007_051236_911`：
真实 MCU UART → 生产 core PREDECODE_VIEW_READ=1，在 125MHz 下验证全部 107 个
bank-2 有效字、bank-1 的 21..33、0x35 和高位别名拒绝。加速串口 141 条回复、
标准 115200 波特率 9 条回复均通过，148 次读取核对 CRC 接收边沿更新后的当前值。
静态状态/快照存储采用 force 夹具，明确只验证控制路径，不代替图像或 CDC 验证。
`geometry_config_predecode_20261007_050130_280` 也已用当前完整输入重跑通过。

第六轮于 05:21 在布局合法化阶段失败：Place-0114，无法在现有局部区域放置
`u_hdmi_tx/u_clock_lane/lane_reset/opit_0_inv`。没有执行详细布线或最终 STA，
更没有生成位流。保留映射检查点后，第七轮 `resumed_20261007_052301_750`
于 05:23 使用相同 map/PCF 和 304 项输入重新布局，seed=1/decongestion=3。
这一轮没有改动 RTL、区域、引脚或时序预算；6+2 条合并路由优先级审计通过。

第七轮于 05:30 同样在合法化失败，这次目标是数据通道 1 的 lane_reset。
只读审计确认区域声明与四个实例绑定正确，第三轮原生网表有四个合法 gopQ /
V_FFASYN / FF0 位置。局部放置/控制组竞争是合理推断，具体冲突单元尚未证明，
不能将此写成已确认的 PDS 缺陷或容量耗尽。

第八轮 `native_20261007_053604_399` 于 05:36 启动完整构建。新增 geometry
专用 `geometry_reset_sites.fdc`，保留 shared placement.fdc 四个区域，显式指定
D0/D1/D2/CK 到 `CLMA_21_378/402/426/450:FF0`。位置来自第三轮原生导出，
不是按 site 后缀推算 floorplan 坐标。所有 recovery/removal、setup/hold 检查
和其余源码保持。必须核对新 map PCF 的四条 def_inst_site，旧位置可用不等于
当前映射必然合法。完整审计见
`fpga/build/geometry_physical_audit_20261007/hdmi_reset_4lane_20261007/findings.json`。

第八轮 map PCF 已核对四条 `def_inst_site ... CLMA_21_* FF0`；放置器日志
也确认四个固定位置实际生效。完整综合资源与第六轮一致。当前约束清单绑定的
真实 UART 控制回归已重跑通过：`geometry_core_read_uart_20261007_053646_927`。
本轮 map/PCF/综合报告/源清单已保存到 checkpoint；布局 ADF 也另存并核对哈希。

第九轮 `resumed_20261007_055359_275` 于 05:54 从第八轮相同 map/PCF，以
seed=1/decongestion=3 在独立目录并行；第八轮继续 seed=2。两个候选都已通过
此前失败的合法化阶段。第八轮布局估计最差 +0.152ns/TNS=0，仅为阶段诊断，
不能代替最终布线双角检查。未修改算法、频率、时序预算或官方文件。

只读官方依据：PDS 2022.2-SP6.4 `ADS_Synthesis_User_Guide.pdf` 5.1/5.15
（物理页 53–54、92–94），`Pango_Design_Suite_User_Guide.pdf` 物理页 112/252，
`Route_Constraint_Editor_User_Guide.pdf` 5.2。上述 PDF 均从官方 doc 原目录只读，
没有修改、提取文件或索引写入该目录。

`export_geometry_candidate.ps1` 在原有门禁基础上新增：两种全尺寸模式、标记、
1024 字窗口、三模型 map stream 和正常/异常 fence writer 回归证据。输入哈希
改变或任何时序失败都拒绝发布。

## 2026-10-07 06:45 后续收敛记录

第八轮详细布线成功，但 PNR 报告仍有核心 setup -0.594ns、DDR 写 setup
-1.411ns、写 hold -0.716/-0.703ns、读 hold -0.706/-0.746ns。独立报告阶段
另报 Timing-0017（打开报告失败）；磁盘空间充足，具体文件访问原因未证实。
已保存 routed_snapshot 及哈希，不把该轮视为完整 STA 或合格位流。

第九轮独立 min/max STA 完成，源输入未变：核心 setup +0.004ns，但 DDR 写
setup -1.370ns、hold -0.684/-0.698ns，RGMII fast setup -0.090ns，不能发布。
两轮均未生成新合格镜像。精确 HDMI reset 子位置解决了先前合法化失败。

第八轮核心最差路径是标记除法器 result[95] 的 24-CLM CE 级联，不是数值
映射算法。依据官方 ADS Synthesis User Guide 5.17（物理页96–100），在
geometry_marker_divide 局部应用 syn_reduce_controlset_size=1024、syn_useioff=0，
保持输出语义，转为 D 端反馈保持。隔离综合确认96个 result 寄存器无 CE，
426 FF不变，LUT由426增至493，无锁存器；不是时序通过的替代证据。
三种随机种子逐周期等价回归通过：marker_divider_20261007_064242_073，
746685周期，非零除法96周期、零除立即完成，所有对外输出和复位语义保持。

DDR 局部候选的依据、原生位置及真实长/短路径记录于
geometry_physical_audit_20261007/ddr_run9_write_20261007_0631；须在新 map
核验后合入完整 PCF，不能把旧 GOP 名直接当作 RTL 名，也不能使用 -no_check。
增加 build_mini_raw8_geometry.ps1 的 dev_map 阶段，仅用于这种检查点流程，
不跳过最终 min/max STA 或位流门禁。RGMII电气参数仍在单独核对。

## 2026-10-07 07:16 新映射及局部位置候选

第十轮 native_20261007_064945_949 完成 compile/synthesize/dev_map，所有输入
哈希未变；综合41684 LUT、51909 FF、无锁存器。独立当前RTL结构探针
marker_divider_probe_20261007_070633_324通过。新的全尺寸原图/鱼眼回归分别为
geometry_board_20261007_064347_832 / _817，均2帧、2073600有效HDMI像素、
4147200原始/网络字节一致；首个结果周期保持3281185/3292831。
这些是仿真，不是实板1080p30证明。

新回归：chain_20261007_064347_797、markers_20261007_064347_721、
config_predecode_20261007_064347_449、core_read_uart_20261007_065036_562
均通过（完整路径以release_request.json为准）。全部新/复用回归436项输入哈希
核对无过期项。Core UART回归只证明控制路径，不能替代像素集成或物理时序。

RGMII按第九轮逐引脚时钟分支/最小最大PAD延迟分析，TXD3保持12mA，
TXD0..2/CTL采用16mA，TXC仍16mA；FAST、3.3V、引脚、PHY 2ns TXID、
1.450ns外部预算和不确定度不变。官方PG2L100H LVCMOS33仅支持4/8/12/16mA，
未采用不支持的20/24mA。分析和预测不是STA，见rgmii_physical_audit_20261007。

第十一轮 resumed_20261007_070906_735 在17秒时被原生PCE拒绝：6个LUT的
旧位置导出名带有后布线`_perm`，在新map中不存在。未进入布局，未产生位流。
原始失败PCF/审计保留；没有使用-no_check。新checkpoint_preperm只将6个输入
名改为LUT6_inst，位置不变，并在布线后允许唯一的末尾_perm别名。
第十二轮 resumed_20261007_071534_861 已通过原生PCE检查，进入布局。

局部PCF文本合入门禁27项、布线后位置/类型门禁19项正负测试通过。
原生只读导出真实通过于merge_pcf_probe/export_20261007_070728_226。
PDS会解析/执行Tcl两次，因此哈希/新鲜度清单由调用PowerShell在导出成功后
生成；Tcl不写独占manifest，也不把gen_netlist的仿真Verilog当GOP类型证据。
实际类型使用本轮PNR伴生.netlist，位置来自本轮数据库generate_constraint。
每次候选的最终min/max及全部10叶实际位置/类型仍必须通过才能发布。

## 2026-10-07 08:12 双种子布线与发布证据冻结

第十二轮 seed=1 与第十三轮 seed=2（`resumed_20261007_072248_858`）均使用
第十轮 map、`checkpoint_preperm/mini_raw8_geometry.pcf` 和相同源码；后者已通过
原生 PCE 与布局合法化。两者仍在详细布线，未完成最终 STA，不能发布或烧录。
输入 PCF 的六个 LUT 名不带 `_perm`；实际布线后的唯一别名由物理核对脚本检查。
正式目录中的 `geometry_ddr_sites.pcf` 仍是未直接加载的诊断候选，不得用其旧后缀
替换本次经过原生 PCE 接受的 merged PCF。

全板综合网表独立核对标记除法器96个 result 寄存器均不带 CE，证据为
`native_20261007_064945_949/divider_structure.json`；这仅证明优化确实进入整板，
不是物理时序通过。每轮 `release_request.json` 保存当前回归目录，最终以其与
发布 manifest 为准，前文旧轮次的表格和周期数仅保留为演进记录。

发布顺序是保存本轮 PNR 数据库、独立原生导出实际十叶位置/类型、完整 min/max
STA、当前源码及回归哈希复核、由同一 PNR 数据库生成 SBIT，最后离线转换
XT25F128/SPI x1/opcode 0x0B/address 0 的 SFC。任一失败均禁止合格发布。
Flash 校验、冷启动以及四类实测帧率保持未执行，不能由离线门禁代替。

## 2026-10-07 08:50 离线发布校验补强

新 `finalize_geometry_evidence.ps1` 在独立短路径目录冻结当前 PNR 数据库、时序
脚本和约束，重新执行原生 min/max STA 与 SBIT 导出；同时检查 Slow/Fast 的
setup、hold、recovery、removal、minimum pulse width 完整表、准确输入数据库、
报告结束标志和全部生成前后哈希。此时两组 PNR 尚在运行，原生签核暂未执行。
PowerShell 7 / Windows PowerShell 5.1 各51项离线结构、哈希、失败留证测试通过，
证据为 `finalization_tests_20261007_084216_434_02b1049c62054ebe921d7b9f8fd19a4f`
及 `finalization_tests_20261007_084217_325_79f0743f8e08483ca701cb3adbaca495`。
它们含合成负例与历史完整报告解析样本，不是新设计时序通过证明。

导出器新增非空哈希门禁及全部15种窗口场景日志检查，要求生成证据的数据库
冻结副本与原 PNR SHA256 相同。SFC 由同一绑定 SBIT 独立原生转换两次，比对
完整长度和 SHA256，并绑定转换脚本、运行时和 Flash 参数；不假设所有 SBIT/SFC
格式都逐字节相同，不用未公开格式的解析推断代替原生转换。
旧镜像离线转换机制试验通过于 `geometry_sfc_repeat_probe_20261007_082307_644`，
两次均3791112字节；不代表新候选已经生成或硬件回读验证完成。

本轮综合资源41684 LUT（62.59%）、51909寄存器（38.97%）、72.5 DRM（46.77%）、
103 APM（42.92%），无锁存器。所有306项构建源输入哈希仍匹配。

## 2026-10-07 09:30 第十三轮最终失败路径

第十三轮 seed=2 于09:21完成原生 PNR：741次详细布线迭代，全部网络布通；
PNR总耗时1h58m58s。保存的PNR数据库48439906字节。十叶原生位置/类型核验
全部通过，但独立 min/max STA失败；result.json记录源码未变、位流未生成。
不能把“布线成功”作为可烧录签核。

最终摘要：core setup -1.345ns（211个失败端点），DDR写 setup -2.630ns，
DDR写 hold slow/fast -0.612/-0.627ns，DDR读 hold -0.613/-0.679ns；
RGMII TXD3 setup slow/fast -0.009/-0.101ns。独立报告为本轮 stage_report.rtr。
核心最差从 MCU parser error_code[2] 到 pending_payload[191]，通过 snapshot_ok
及多层回复数据选择，路径约87.3%为路由延迟。标记除法器 CE优化并未消除
其它控制回复关键路径，不能把本轮失败归咎于标记数值算法。

DDR新失败点转移到未锁定相邻mask及读对齐路径；例如adj_wrdata_mask_3[39]
到TX_DATA[3]存在CLKROUTE缓冲与5.228ns长网。该证据来自hold修复后的报告，
尚不能单独证明缓冲究竟在哪一个原生阶段插入。零散十叶固定不足以稳定整个
读写片区，下一步对照第三轮DDR合格布局核对更完整范围，不放宽时钟/时序预算。

RGMII实际逐引脚抽取保存到 `rgmii_physical_audit_20261007/run13_actual_paths.json`。
TXD3采用12mA时fast hold +0.261ns，另外四路16mA的setup/hold均为正。
当前路径下加强TXD3驱动是有依据的后续候选，不是已验证结论；重新布局后必须
重新检查时钟分支和全部快慢角。本轮不做未经官方确认的post-route IO修改。

第十二轮仍在同一冻结映射下布线。MCU回复结构和DDR更完整位置候选均只在
独立副本审计/验证，尚未修改其绑定的正式RTL和约束。

## 2026-10-07 10:00 第十四轮重新映射与回归

第十二轮 seed=1 的306项源、映射数据库、板级PCF和已生成布局已冻结到
`resumed_20261007_071534_861/preserved_094157_732`，副本逐项哈希相符。
09:54由主代理精确核对PID、父进程及项目路径后主动停止该旧PNR子进程；
最终result记录未完成、源码未漂移、无位流。其Flow-0189是主动中止后的日志，
不得当作自然算法崩溃或时序失败结论。此前第十三轮的最终时序失败仍有效。

合入 `mcu_reply_timing_20261007_093600/candidate/mcu_reply_parallel.patch`，
正式MCU协议源码SHA256为A0110F5AD0795FC29AF2A492087A0C8C458C27E77A253860576CE8B975EB8104。
它将96位回复尾部的优先选择改为互斥译码/掩码OR，不增流水级、不改协议周期。
39项隔离回归通过：4194304组decoder向量、100000周期snapshot，以及6项
真实UART逐周期新旧比较；累计241条回复、78683633周期。旧golden仅改模块名。
发布时另由 `check_mcu_reply_evidence.ps1` 检查全部用例、日志/源哈希和正式
源码相同；此证据不替代受影响的全板回归或新STA，后者正在重跑。

RGMII TXD3由12mA改16mA，与其余TX端口一致。固定引脚、LVCMOS33、FAST、
PHY延迟、时钟、外部时序预算保持不变。旧路径PAD延迟估算不是新时序结果。
PDS原生dev_map启动于 `native_20261007_095622_133`，尚无最终PNR结果。

DDR采用 `ddr_slice_audit_20261007_093224/critical37_experimental_NOT_APPLIED.pcf`
作为下一轮物理候选：原十叶加失败路径相关读SRL/写数据/位滑移及3个DFI源。
旧位置和当前GOP名称唯一对应；旧GOP类型是否相同未核实，不作相同断言。
37叶的27处移动、17处候选外槽占用和9个共享CLM均有记录。名称接受性、
共享资源合法性、实际位置和快慢角时序必须由新映射后的原生PCE/PNR/STA核验。
不使用输入no_check，不固定自动CLKROUTE，不增加false/multicycle例外。

## 2026-10-07 11:00 新映射、布局候选与发布回归

第十四轮 `native_20261007_095622_133` 原生compile/synthesize/dev_map于10:14通过，
306个源输入无漂移。综合41643 LUT、51918寄存器、72.5 DRM、103 APM，无锁存器。
相对前轮少41 LUT、多9寄存器；此资源变化不能单独证明时序改善。

严格合并的37叶候选位于该轮 `checkpoint_critical37/`，保留113个板级端口、
四个HDMI reset位置及完整PCF前缀。`geometry_ddr_scope.ps1` 固定批准名称、类型、
site/subsite，`critical37` 才允许同CLM不同锚点实验；最终仍要求原生导出的实际
类型和位置逐项匹配。PowerShell7/5.1均通过默认27+19及新42项门禁测试，见
`ddr_profile_tests_20261007_100724_186/test_results.json`，不是新PNR通过证明。

第十五轮 `resumed_20261007_101547_898`（seed2，decongestion3）正在详细布线；
详细布局估算slack +0.173ns/TNS0，不是最终STA。第十六轮seed3原生约束检查及
详细布局同样通过，但总线长1651976，相对第十五轮1344003更大，详细布线到第7
次迭代单次CPU378.063秒、仍54443条未布通网络。主代理保留其布局/日志快照后
主动停止，result记录未完成、输入未变；不将主动终止后的Flow-0189解释成自然崩溃。
第十七轮 `resumed_20261007_105238_297` 从同一map、同一37叶及同一seed2启动，
仅将官方支持的plc_decongestion由3改6，时钟、接口预算和RTL未改变。尚无最终结果。

正式MCU变更影响的8组回归全部重跑通过：chain、markers、config predecode、
CoreRead UART、MCU完整/125MHz、decoder、snapshot、queue。完整路径与日志见
`mcu_formal_regression_20261007_100500/REPORT.md` 和 `verified_results.json`。
原图/鱼眼全板测试均不含MCU模块，62+62个输入哈希未变，合法复用原PASS；
view predecode的6个输入亦未变。全部18组发布回归输入再次逐项核对通过，保存于
第十四轮 `regression_inputs_verified.json`。每个新PNR目录有 `release_request.json`。

独立发布审查发现缓存生成证据、时序行解析和MCU矩阵证明的边界漏洞；不代表当前
真实测试或报告已经错误。MCU校验现强制布尔类型、18个必要编译输入、17个基线输入、
39个准确用例及实际geom/features/display/clock/周期PASS字段。新版19项正反例
在PowerShell7/5.1均通过：`reply_gate_20261007_104644_088`、`reply_gate_20261007_104646_138`。
新发布校验不在冻结PNR源码输入内，修改未改变正在实现的电路。

## 2026-10-07 11:40 布局对照与发布校验收尾

第十七轮去拥塞6在详细布局迭代中曾达到+0.310ns，但最终布局估算为-1.294ns、
TNS -1.294ns，不能引用迭代正值声称布局或时序通过。独立布局副本诊断保存在
`placed_diag_20261007_110443_817`，原生report_timing正常完成；观察到其网络延迟
计为0，不能复现内部布局估算，也不能预测最终路由。此诊断不作为位流签核。

为检验额外固定位置对拥堵的影响，新增第十八轮 `resumed_20261007_112440_859`：
同一新map、seed4、decongestion6，不加载37叶额外DDR delta，保留原生完整板级PCF、
113端口、四HDMI reset site及所有FDC/RCF预算。输入为 `checkpoint_native_free`。
其result字段ddr_profile默认ten仅反映脚本参数默认值；没有ddr_placement_audit时
不表示加载过十叶delta，实际物理输入以checkpoint PCF和comparison.json为准。
最终布局线长1184630，估算slack -0.172ns/TNS -0.490ns；正在原生路由，尚无位流。

发布审查第1/2项已完成：exporter移除外部FinalizationEvidence缓存入口，每次发布
强制从本轮PNR副本重新执行原生min/max STA与SBIT；finalizer逐行解析十张角表，
拒绝损坏/重复行、缺少本板必要clock-pair覆盖、错误数据库/架构、缺角及不完整footer。
不硬编码旧slack、端点总数或报告hash。原51加新增207，PS5.1/PS7各258项通过：
`finalization_tests_20261007_105001_618_dd5ea03b223343f2ae15db1ac0a909e5/test_result.json`，
`finalization_tests_20261007_105004_661_20521685d6ee490496f3408132f0b89a/test_result.json`。
首次测试误拒真实CRLF行尾，修复后双版本复测通过；历史失败保留。测试使用历史完整
报告及合成负例，不代表当前候选原生STA或位流生成已经通过。

## 2026-10-07 12:05 第十八轮完成与剩余路径

第十八轮原生PNR于12:00:19完成，耗时35分38秒；独立min/max STA于12:01:51完成。
最终仍为 Some Constraints Violated，未生成SBIT，306项源输入未改变。
core setup -0.080ns（3端点，TNS -0.201ns），DDR写至phy_dq_sysclk_1
setup -1.201ns（4端点，TNS -2.610ns）；其它setup域均正裕量。
所有hold表均无失败端点：DDR写fast最差+0.100ns、读fast最差+0.114ns；
RGMII setup slow/fast +0.126/+0.143ns，hold +0.103/+0.115ns。
recovery/removal/min-pulse-width无违例。外部DVP预算未实测的边界仍然保留。

本轮布线资源41127 LUT、50903 FF、72.5 DRM、103 APM；CLMA/CLMS占用各约91%，
不能仅用LUT百分比代表放置余量。核心路径为session/geometry状态返回至MCU
错误计数，以及cache fault/replay至1024位valid索引。协议尾部优化已移除旧的
最差回复优先级路径，但不能把当前三个残余违例忽略为四舍五入误差。

第十九轮 `resumed_20261007_120259_080` 从同一native-free checkpoint启动，
仅seed4改5，decongestion6保持不变；仍保留全部接口、时钟和预算。
DDR失败路径审查与MCU错误分类隔离等价候选并行进行，未修改正式冻结输入。

## 2026-10-07 13:49 等价面积优化后的新构建

第十九轮最终仍有 5 个 slow setup 失败端点，详见
`geometry_resource_optimization_20261007.md`；未生成新 SBIT。随后完成写入
校验流水、20 点叠加有界算术及 packed-tag 缓存优化，新旧对照与当前源全板
回归通过。native21 Device Map 为 39592 LUT/50894 FF/66.5 DRM/103 APM；
与同阶段 native20 相比减少 1683 LUT/6 FF/3 DRM，103 APM 不变。

新 PNR `resumed_20261007_134909_088` 使用 native21 检查点、seed5/decongestion6，
正在布局布线。PCF 除自动生成时间戳外逐行一致；原时钟、外部 IO 预算、
DDR 不确定性与 min/max 检查全部保留。没有把低 LUT 用量视为时序通过。
完整记录与证明入口见 `geometry_resource_optimization_20261007.md`。

资源发布门禁已绑定三份当前正式 RTL、原始候选/黄金源、完整测试矩阵与
日志；PS5.1/7 各通过 30 个 checker 测试和 10 个发布集成测试。发布时需要
必填 `-ResourceEquivalence fpga/build/resource_merge_20261007_1325`，并在原生
最终 STA/SBIT、离线 SFC 转换前后重新验证，禁止沿用旧证据或忽略失败。

## 2026-10-07 14:28 本轮最终结果

上述新轮 PNR 14:26:56 完成，耗时37分46秒，全部网络布通；独立 min/max
多角 STA 14:28:27 完成，仍有 slow core setup WNS=-0.361 ns、
TNS=-19.665 ns、142失败端点。DDR跨时钟及其它setup、全部hold/recovery/
removal/min-pulse-width没有失败端点。详细数值与前10条路径见
`geometry_resource_optimization_20261007.md`；不是可烧录时序合格版本。

PNR资源39444 LUT/50897 FF/66.5 DRM/103 APM，CLMA/CLMS仍约91%。
当前最差路径为boot epoch 64-bit变化判断→MCU pop/space_available→参数
shadow_storage写CE，路径12级、连线占74%。降低LUT已经得到原生证明，
但没有保证控制路径闭合；失败端点/TNS反而增加，不能宣称整体时序改善。
306项输入未改变，未生成或发布新SBIT/SFC，没有烧录或硬件测试。

## 未执行

新候选 Flash 写入、回读、冷启动、真实图像、四类帧率、功耗、外部 DVP 实测时序、
Linux/Jetson 实机及 HDMI/UVC 同帧身份验证均未执行。本记录不能替代这些验收。

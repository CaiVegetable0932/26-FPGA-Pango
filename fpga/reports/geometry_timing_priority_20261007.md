# FPGA 时序优先修订记录（2026-10-07）

本轮遵循用户“首先满足时序，LUT 消耗可以暂时不考虑太多”的新优先级。
保留全部视频、矫正、标记、UART 和 RAW8 功能，不降低时钟、放宽接口预算、
增加时序例外或修改官方参考文件。此前 cache valid-mux 的隔离面积候选不合入。

## 修改依据

上一轮 `resumed_20261007_134909_088` 已完成布线与独立多角 STA，仍失败：
slow 核心 setup WNS=-0.361 ns、TNS=-19.665 ns、142 个失败端点。
最差 10 条已报告路径经过 boot epoch 的 64-bit 变化检测、UART pop/队列
空间判定，到几何参数影子存储的写 CE；最差路径布线占比 74.016%。
这些是前 10 条的共同结构，不是全部 142 条端点的枚举。

只读检查 `comms_boot_config.v` 与 `mini_raw8_geometry.v` 确认：
epoch 仅在成功接收 boot 配置时更新；此时 commissioned=0，UART endpoint
保持复位。完整 ACK、DRAIN 和 GUARD 结束后才进入 RUN、释放 endpoint；
RUN 中 epoch 与 commissioned 不变，直到共同的 mem_reset_n 再次复位。

## RTL 修改

- `fpga/rtl/control/mcu_protocol.v` 增加默认关闭的 `STABLE_LINK_EPOCH`。
  通用实例继续检测 64-bit epoch 和 valid 的实时变化，保持旧行为。
  只有满足“epoch 已稳定且 valid 已有效才释放复位、运行中变更必须先复位”
  契约的实例可启用：省去不可能发生的运行中 epoch 总线比较，但仍保留
  first-valid 同拍清空和禁止请求接收。不是将 flush 延迟一拍。
- `fpga/rtl/board/mini_raw8_geometry.v` 根据上面的实际启动连线启用该参数。
  其他板级入口和通用顶层不启用，控制报文格式与参数帧边界不变。

实现及受影响代码块均已同步用途、前提与时序意图注释。

## 当前验证进度

`native_20261007_144243_970` 已于 15:01:23 完成 PDS compile/synthesize/device-map，
固定输入 MCU SHA-256 `47FB9B886CA67790124F96E4BDEFA1EA08C29B6509A2C6001611BBCBA8ED057D`，
板级 top SHA-256 `46E573B81894CDDA7CC3CFFFE4CD9B4B3DC60C5FA6EBDD54BAE00307B64993B4`。
306 项输入前后未变，此阶段不证明最终时序闭合。
映射为 39489 LUT/50802 FF/66.5 DRM/103 APM；面积是记录项，不是本轮验收依据。
原生综合网表中 `u_mcu/observed_epoch[` 历史寄存器匹配为 0，
observed_epoch_valid 保留（48 个文本匹配，不是 48 个寄存器）。
新映射 PCF 与 native21 仅第一行自动时间戳不同，剩余所有行严格一致；
未新增 DDR 叶节点锁，未改原时序条件。检查点在
`native_20261007_144243_970/checkpoint_native_free/comparison.json`。

新轮 `resumed_20261007_150431_504` 15:04:33 开始原生 PNR，仍为 seed=5、
decongestion=6、performance、多角优化和原有 hold 修复策略。

`mcu_protocol_20261007_144258_521` 已通过默认模式串口回归：
1843200 Hz 全项 6538 checks/68 responses；125 MHz、115200 baud
3201 checks/33 responses。

真实 boot/reset 契约的逐拍证据见
`mcu_stable_epoch_proof_20261007_144143_995/REPORT.md`。主代理完整审读 bench、
runner 和报告后，再独立执行 `attempt_20261007_145640_309_b567e5df`，两项 PASS：
FULL=2073674 cycles/6237515 checks/68 次释放（含全部 64 单bit epoch），
queue 最大 8；125 MHz=13410978 cycles/40234162 checks/2 次释放。
实际 UART RX/TX、CRC、非法 boot、GUARD 噪声、pending/TX/GUARD 复位均覆盖。
旧 golden 是精确 A0110，并非当前候选；共享 queue helper 经全文核对一致。
结论仅覆盖 immutable boot/reset 合同，配置保持复位期间的内部组合
epoch_change 可以不同；活动期不掩掉比较字段或周期。这不是无界 formal。
此前两次 harness 等待不足的失败日志保留，未覆盖或重新标成 PASS。

受 MCU 源码变化影响的新回归已通过：
chain=`geometry_chain_20261007_144447_431`，
markers=`geometry_markers_20261007_144502_552`，
predecode=`geometry_config_predecode_20261007_144516_835`，
core UART=`geometry_core_read_uart_20261007_144549_764`。
这些分别验证原算法/采样、20 点与模式、参数预译码和实际 UART 到 core 控制；
没有实板帧率或同帧 HDMI 身份验证。其余默认协议独立证明与发布门禁继续汇总。

默认模式另有 39 项独立回复/快照/UART 证明通过，保存于
`mcu_current_sidecar_20261007_145100/reply39`；主代理独立核对既有发布 gate
与私有复检器，保留历史 golden，未将当前候选自身当作基线。

物理 top 的 STABLE_LINK_EPOCH 前提另设强制发布 gate：
`check_geometry_boot_epoch_evidence.ps1`，绑定 30 个精确源/冻结副本/日志/
元数据，审读全部实际 UART 日志而非仅匹配 PASS 行。
`export_geometry_candidate.ps1` 新增必填 `BootEpochEquivalence`，原生
finalizer 前检查，转换后复检全部原始记录与 checker，并逐字节归档 20 个
证明文件；没有该证据不能发布这个板级专用修订。

主代理审读测试后独立在 PS5.1/7 重跑，每个版本均为：证据 gate 51 项
（46 负例）、boot exporter 集成 24 项（16 负例）、已有资源 exporter
10 项全部 PASS。目录分别为 `main_gate_replay_20261007_152850_449_ps51_*`
和 `main_gate_replay_20261007_152912_104_ps7_*`。新旧源码、checker 和原始
证明前后哈希一致；全部负测只改私有夹具，不执行 PDS、转换器或硬件。

只读查阅安装版 `Pango_Design_Suite_User_Guide.pdf` 纸面252页/PDF253页
及 `pnr_options_20261005/console.log` 的当前原生命令帮助：多角优化、hold
修复阈值/迭代和布线中修复均为优化力度选项，不改变最终时序验收预算。
官方页面渲染只写入 `fpga/build/timing_doc_read_20261007_1533/`，未向官方
目录写入内容。未安装依赖或改系统设置。

## 第一轮修订的最终 STA 与后续 hold 优化

`resumed_20261007_150431_504` 于15:35:45完成 PNR，31分13秒；
独立 min/max 多角 STA 于15:37:04完成，仍为 Some Constraints Violated。
已保存 routed_snapshot、数据库哈希、完整报告、十张汇总解析
`final_timing_diagnostic.json` 与失败路径清单。306项源输入无漂移，
bitstream_generated=false，未输出/固化烧录镜像。

核心 ddrphy_sysclk slow setup 从上一轮 -0.361ns 改善为 +0.014ns，
TNS=0、失败端点=0；fast同域为 +2.922ns。本轮所有定义的 setup 域，
recovery/removal/minimum-pulse-width 在 slow/fast 均无失败端点。
核心setup余量仍小，不把这一步改善等同于整个设计时序闭合。

剩余失败均为 hold：

| 角别 | 时钟对 | WHS ns | THS ns | 失败端点 |
| --- | --- | ---: | ---: | ---: |
| slow | ETH125 → PHY_SAMPLE | -0.083 | -0.295 | 4 |
| fast | ETH125 → PHY_SAMPLE | -0.022 | -0.053 | 4 |
| fast | ddrphy_sysclk → phy_dq_sysclk_1 | -0.122 | -0.122 | 1 |

RGMII 对应 tx_ctl、txd[1/2/3] 的 ODDR-to-pad 检查；DDR对应
phy_wrdata_en_r[0] → group1 TS_CTRL[5]。这是精确最终失败路径，
不是继续将旧64-bit epoch路径当作现有瓶颈。资源39340 LUT、50802 FF、
66.5 DRM、103 APM；CLMA/CLMS原生整数利用率均90%。

保留原 runner/Tcl 字节与历史证据，新增
`resume_geometry_hold_route.ps1/.tcl` 独立时序优先入口：使用官方已核对的
hold优化阈值100ps、最多20轮、布线中修复及1000路径上限，继续performance/
多角模式；这仅是优化目标，不是更改最终 hold/setup 要求。
不改RTL、PLL相位、PHY模式、IO预算、CDC例外或官方目录。

新检查点 `native_20261007_144243_970/checkpoint_hold_margin` 逐字节绑定
同一map/PCF/source_manifest与已完成的第一轮PLC，保存原始/副本SHA。
`hold_resumed_20261007_154024_331` 于15:40:26启动原生重布线，不重新
随机放置，原6条DDR/HDMI优先路由及2条既有几何附加优先均保持。
发布时仍核对本轮实际PDS项目、数据库、全部角报告与现有功能证据。
此轮于16:02:39完成PNR（22分14秒），独立STA于16:04:00完成。
主代理从完成报告独立解析十张汇总，保存本轮
`final_timing_diagnostic.json`：全部setup、recovery、removal、minimum-pulse-width
仍无失败，但三个hold汇总行与上表逐项相同，五个实际端点未修复。
不能把路由器的正hold目标当作时序结果；本轮未生成位流。
未烧录或实板测试，真实1080p30/外部DVP时序未验收。

## 结构性时钟树修订（native23，已完成但未通过最终STA）

用户进一步明确“首先满足时序，LUT消耗可以暂时不考虑太多”。
本轮不进行以面积为目标的复用或进一步压缩，而针对现有物理失败路径调整：

- 板级top新增独立的`u_eth_tx_clock`（GTP_CLKBUFG），与原`u_eth_clock`
  使用同一PLL输出、相同频率及相位，仅驱动RGMII六个pad串行器。
  目的为将输出支路与约919个负载的报文逻辑时钟树分开；实际保留情况
  必须由本轮原生映射网表确认，`syn_keep`本身不构成保留证明。
  PHY_TXID、报文、FIFO、复位及协议逻辑不变；同根支路之间的
  setup/hold/recovery/removal仍接受原生多角STA，不设置新例外。
- `geometry_priority.rcf`移除此前额外添加的两条DDR写控制优先级，
  保留全部六条继承的DDR/HDMI原生优先级，让多角路由器重新选择控制
  路径。并不宣称原优先级已被证明是hold失败原因。
- 不修改引脚、IO drive/slew、PHY延时、PLL相位、时钟周期或IO预算。
  `OUT_DELAY=0`不是已证实的旁路，不以未核对的delay tap修补违例。

旧物理输入逐字节保存在`fpga/build/timing_io_baseline_20261007_1609/`。
新top SHA-256为`39EAC934A1718849B0A37CE2D5D3D42E040736A4EE1A830045A5743C99D19A53`；
新RCF为`6230DBAAE4BBB7DBDAFBE60D1154EDC992A756EE6825E7A97D91600DFB4E0A7B`。
原MCU源码仍为47FB9B…ED057D，启动合同未改动。

`native_20261007_160934_732`于16:09:34开始全新compile/synthesize/device-map。
在输出完成前不读活动数据库，不复用旧映射或路由结果生成新镜像。
对新top绑定的启动证明须实际重跑；另外用安装版GTP原语模拟新旧RGMII
时钟分支的逐边沿数据、控制、错误及复位行为。两项均不能代替物理STA。
本节当前仅记录实施输入和待验证范围，不是时序闭合、板测或30FPS验收。

### native23映射及独立功能复核

原生compile到dev_map于16:26:40完成，16分57秒，306项输入无漂移；
当前映射39502 LUT、50802 FF、66.5 DRM、103 APM、113 IO。保留资源
开销，不以LUT数量较上一轮增加13为失败。该阶段没有位流和最终时序结论。

综合网表分别保留`u_eth_clock`及`u_eth_tx_clock`；DMR的Clock Signal表
明确记录同一CLKOUT0的两条逻辑支路（eth_clk=919，eth_tx_clk=6负载）。
USCM仍为6，单凭数量不能证明实际时钟树分离；还须查阅新routed DB及
最终STA中的launch/capture路径，不能把逻辑实例数量冒充物理修复效果。
`checkpoint_native_free/comparison.json`逐字节绑定本轮map、PCF、source
manifest、DMR及综合网表。PCF除第一行PDS时间戳外与native22完全一致。

新PNR `hold_resumed_20261007_163041_434`于16:30:43启动，使用当前map
全新placement（seed5/decongestion6），performance、多角、100ps优化目标/
20轮hold修复；不加载旧PLC或旧routed DB，不修改任何验收预算。
最终结果仍待独立min/max STA，不预先标为通过。

主代理完整审读新RGMII bench/runner后独立执行
`rgmii_dedicated_clock_20261007_162546_337_3bf23db8`：3072字节（含1024随机）、
62188 checks、4次异步复位、6334个半边沿、0错误；复位期间TXC连续。
当前安装版GTP_GRS/GTP_ODDR_E1/GTP_CLKBUFG实际编译到私有usim，
所有7项输入前后SHA相同，本地4项冻结副本相同。测得功能模型相位差0ps；
这不是物理插入延迟或时钟偏斜验证，未编译PLL及整个板级top。
两次scoreboard宽度/复位历史处理失误的失败尝试原样保留。

主代理只读完整核对安装版`Simulation_User_Guide.pdf`相关前仿/usim说明
（PDF6/7/8/12/13页），并只读核对100K MINI配套DS04001 v1.5的时钟
说明及AC表（PDF13/26页，包含PG2L100H全局/区域资源定义）。页面渲染仅在
`fpga/build/timing_clock_doc_read_20261007_1620/`。此主代理实际查阅补齐了
并行任务当时报告的PDF读取限制，没有向官方目录提取或写入文件。

主代理重新核对18组旧回归：17组实际源绑定无漂移；CoreReadSimulation
仅因RCF清单变化失效，未重写旧证据，实际重跑
`geometry_core_read_uart_20261007_161844_495`。125MHz快串口为14377checks/
141responses/136reads；115200baud为913checks/9responses/7reads，均PASS。
控制测试使用静态强制状态夹具，不将其视为图像或实板证据。

Top39绑定的真实boot/UART等价新证明为
`attempt_20261007_161933_853_98ae2b14`。主代理完整审读五份实际compile/
simulation/transcript日志，独立执行production checker，11角色/8个编译
输入/30项文件全部通过；Top只是启动合同绑定，不在编译列表中。
MCU及bench逻辑未改；FULL和125MHz实际逐拍覆盖与前文数值完全一致。
四项验证脚本的旧字节及旧证明保留，新checker仅批准本次新尝试，并收紧
root为自身项目，不自动批准任意自报PASS的新日志。

主代理在PS5.1/7分别实际重跑`main_top39_gate_replay_20261007_1632_*`：
每个版本52项证据gate（48项负例）及24项真实exporter AST测试均PASS，
原始记录、checker、脚本和源码前后哈希相同。包含真实旧尝试拒绝测试；
这些测试不运行EDA/finalizer/转换器/硬件。新请求保存在native23目录，
独立时钟仿真和启动证明不能代替本轮尚待完成的物理时序。

主代理另行独立重跑启动等价
`attempt_20261007_163958_215_7843bec5`：FULL为2073674cycles/
6237515checks，125MHz为13410978cycles/40234162checks，均PASS且源码
前后无漂移。该重放只是独立复核，不自动替换production checker明确批准的
161933尝试，也未重写旧证据或放宽发布门禁。

主代理在PS5.1/7各重跑最终STA门禁的255项离线测试：
`finalization_tests_20261007_163951_935_63a448b5f4be4362bb127621193c9ac2`及
`finalization_tests_20261007_163949_936_5f0c85d2b78941409ca2635ce9651c97`，
均PASS。它们使用明确标注的合成测试夹具，不执行原生EDA、不生成发布位流；
仅证明门禁拒绝缺角、缺检查、非有限数、负余量和不完整报告等情况。
当前资源严格校验及39项MCU回复等价也重新核对PASS，结果分别保存为
native23目录的`resource_current_gate.json`和`reply_current_gate.json`。

当前PNR于16:38:31完成详细放置，原生报告placement worst slack=173ps、
TNS=0；16:41左右完成global routing并开始详细布线。放置估计不等于
最终WNS，尚不据此验收时序或生成合格位流。

### native23最终结果及native24有效位并行读改造

PNR于17:00:21完成（29分39秒），独立min/max STA于17:01:41完成。
主代理独立解析本轮完成的十张汇总（setup各21行，hold各12行，recovery/
removal各7行，minimum-pulse-width各11行），保存
`hold_resumed_20261007_163041_434/final_timing_diagnostic.json`。
全部hold、recovery、removal、minimum-pulse-width及fast setup通过；
仅slow的ddrphy_sysclk→ddrphy_sysclk setup失败：WNS=-0.504ns，
TNS=-0.938ns，4个失败端点。输入清单无漂移，本轮未生成位流、未烧录。

| 当前实际路径组 | Slow余量ns | Fast余量ns | 结果 |
| --- | ---: | ---: | --- |
| RGMII ETH125→PHY_SAMPLE setup | +0.144 | +0.148 | 通过 |
| RGMII ETH125→PHY_SAMPLE hold | +0.142 | +0.138 | 通过 |
| DDR core→phy_dq_sysclk_1 hold | +0.443 | +0.113 | 通过 |
| core→core hold | +0.137 | +0.100 | 通过 |
| core→core setup | -0.504 | +2.829 | 未通过 |

剩余四条负路径均从`u_core/geo_start`进入cache的`replay`，再通过
`rows[2].right_address`及1024位有效数组选择，到同一个right_valid
寄存器的不同数据输入；不是四个独立缓存故障，也不是旧UART回读路径。
最差路径5层逻辑，logic=1.474ns、route=6.610ns（81.766%）；
另三条分别-0.240/-0.170/-0.024ns。新路由USCM=7；物理时钟支路
细节另由实际最终报告审计，不能仅以资源数量证明支路隔离。

旧cache SHA0F3CB3…C385原样保存为
`fpga/build/cache_valid_parallel_baseline_20261007_1712/geometry_window_cache.golden.v`。
native24只修改`geometry_window_cache.v`的valid查询：请求与重放的左/右
有效位同拍并行读取，五个局部保留寄存器（原来两个）后选择一位结果，
而非让replay先选择地址再穿过宽valid mux。保持RAM地址/内容、lookup enable、
状态机、队列、invalidate/reset、响应故障检查和所有对外周期不变；
不对未初始化valid快照新增reset，不增加有效窗口处理延迟。
syn_preserve/syn_allow_retiming保持此边界；具体物理效果仍须下一轮STA。
新RTL SHA=`69422BF532261480BEB3EC2B1687D8D50BCB1BC14D54C3461C59A63441405635`，
15736字节。允许为时序增加FF/LUT，未降频或放宽任何约束。

新原生映射`native_20261007_170907_279`于17:09:07启动，17:26:31完成，
compile到dev_map原生计时17分14秒。全部306输入无漂移；40078 LUT/
50810 FF/66.5 DRM/103 APM/113 IO，相比native23映射增加576 LUT、8 FF，
仍在器件容量内。此时只是映射通过，尚无最终时序结论。
18组前版源绑定重查：7组仅cache字节漂移，另11组无漂移；这7组
均实际重跑，不重写历史结果。已完成15项标量窗口回归
`geometry_window_20261007_170905_170`，64/256/1024及多stride全PASS；
链路回归`geometry_chain_20261007_171013_414`全PASS（含125MHz UART）。
其余5组实际新回归也均PASS：原图/鱼眼完整栅格
`geometry_board_20261007_171012_726`/`geometry_board_20261007_171013_140`，
20点`geometry_markers_20261007_171213_449`，预译码
`geometry_config_predecode_20261007_171213_527`，core读回
`geometry_core_read_uart_20261007_171213_614`。完整栅格均检查2073600
HDMI像素和4147200网络字节；鱼眼/原图首结果3292832/3281186cycles及
miss/hit计数均与旧版一致，未因valid拆分新增延迟。core读回仍是静态
强制状态的控制测试，不冒充像素集成证据。专用逐周期cache证明及
新资源发布门禁仍在执行/审查，必须绑定本次真实证明，旧资源日志不能
冒充新cache的证明。当前仍无时序合格镜像或实板1080p30结论。

新map、PCF、source manifest、DMR及综合网表逐字节冻结在
native24的`checkpoint_native_free/comparison.json`。map SHA
3AB4B0012005011D1E051EB4C2B4B96EDA54A700F588F833A9A4D3BF676E2CB1；
PCF除PDS时间戳外与native23相同。独立PNR
`hold_resumed_20261007_172834_261`于17:28:36开始，仍seed5/decongestion6/
performance多角/100ps优化目标/20轮hold修复；不重用旧PLC/路由DB。
17:35详细放置的173ps/TNS0及17:38全局布线完成只作为阶段进度，
不能替代最终独立min/max STA。

native23时钟物理审计保存在
`fpga/build/clock_branch_physical_native23_20261007/`。实际PRR将fabric
映射到USCM_215_582（915负载），TX到USCM_215_585（6负载），同一
GPLL_7_463/CLKOUT0/125MHz；区别于DMR逻辑统计919和STA端点统计903。
五个data/ctl pad的两角hold明细及20条复位recovery/removal均正余量；
TXC独立hold及GMII→IOL TX_DATA输入的指定端点明细未导出，明确未覆盖，
不能用pad hold冒充内部过渡证明。全ETH汇总零失败只是在既有约束下
的全局检查，不替代外部PHY/PCB测量。

主代理完整审读286行只读解析器及HANDOFF，并独立重跑/核对37项文件
SHA与全部诊断字段。首轮默认Python管道编码损坏两条中文引用，保留其
`main_replay.json`；使用子进程`-X utf8 -B`重跑生成
`main_replay_utf8.json`，`main_semantic_review.json`确认除引用空白、JSON
键顺序和4/4.0等相同ns数值表示外无语义差异。未改系统编码、原始报告
或发布门禁。此审计仅针对已完成native23，不自动认证仍在布线的native24。

### native24缓存并行有效位的独立审查（最终STA前）

主代理核对冻结综合网表，三个row的15个有效位/选择寄存器均实际存在，
均为GTP_DFF_E，并保留PAP_PRESERVE/PAP_ALLOW_RETIMING属性；记录在
`native_20261007_170907_279/checkpoint_native_free/parallel_register_inventory.json`。
映射FF总数只增加8不能用于推断其中某个局部寄存器被删除；该15项实物
清单才是边界保留的直接证据。

新逐周期证明目录为
`fpga/build/cache_valid_parallel_20261007_171322_219/attempt_20261007_172113_476`。
40项为4种stride×5种cache容量×2种seed，在125MHz共3357067cycles、
10071201行valid比较、70159次replay和294700次标签发布，全部PASS。
比较包含原未初始化X、原始输出和公共状态，新增五个FF另按前沿旧值
独立计算期望；覆盖背压、fill、invalidate、非法响应及复位，不新增
快照清零，不mask原valid。仅合法二值活动事务，非无界formal证明。

主代理完整审读bench/runner/新checker及发布修改，独立运行55项固定
文件的strict proof和旧116项+新proof的资源v2门禁，均PASS。
历史0F/旧窗口bench/runner分别解析至明确冻结副本，不把旧证明重标为
69422B。新发布必须同时提供ResourceEquivalence和CacheTimingEquivalence。
主代理在PS7.6.5和PS5.1.26100.9444分别独立重跑资源45项及发布10项
正负例，均PASS；证据分别在该目录的`main_resource_ps7_1752`、
`main_resource_ps5_1752`、`main_exporter_ps7_1752`、`main_exporter_ps5_1752`。
来源436项的18组回归再次无漂移，记录在native24的
`regression_current_main_review.json`。这些只读/离线门禁不替代物理STA。

native24详细布线及hold修复已完成，route阶段报告worst slack=22ps，
hold优化最后slow/fast=140/103ps；仍在保存DB。阶段数字尚不是最终
独立min/max结果，此处不据此标记镜像合格或宣称硬件稳定。

### native24最终时序闭合

本轮PNR于17:57:42完成，独立min/max STA于17:59:20完成，原生SBIT于
18:01:19完成。主代理对闭合后的306来源及全部十张STA表独立核对，
保存`hold_resumed_20261007_172834_261/final_timing_diagnostic.json`。
目标仍PG2L100H-6FBG676、PDS2022.2-SP6.4 build146967，原有时钟/IO/
CDC预算未放宽。阶段综合worst slack=22ps不应叫做最终setup WNS；
最终setup最差87ps，22ps属于slow recovery，分类以实际STA表为准。

| 检查 | Slow最差余量ns | Fast最差余量ns | TNS/失败端点 |
| --- | ---: | ---: | --- |
| Setup | +0.087 | +0.148 | 0/0 |
| Hold | +0.140 | +0.103 | 0/0 |
| Recovery | +0.022 | +0.490 | 0/0 |
| Removal | +0.174 | +0.108 | 0/0 |
| Minimum pulse width | +0.035 | +0.035 | 0/0 |

此前core→core slow setup=-0.504ns已转为+0.087ns，fast=+2.942ns。
RGMII ETH125→PHY_SAMPLE setup=+0.144/+0.148ns，hold=+0.142/+0.138ns；
DDR core→phy_dq_sysclk_1 hold=+0.464/+0.114ns，全部通过。
最终PNR39906 LUT、50816 FF、66.5 DRM、103 APM、113 IO、7 USCM；
区别于映射阶段40078/50810，不混用两阶段资源数。

本轮路由DB SHA为8993304BECF0FA3703CB7D7174757651A4905CEC7ECD235B96310DF8A59EBBAA。
独立report SHA为D628DF337A67A44B9E6BD45563D6705E3B0A410DDF57031D5EB7927E5ACCE9A1。
原生SBIT3791112 B，SHA为4E5481DCAC3E2A98803E97895DB67A5A1DDB6A8210862AB9FFCA2B8720C6A753。
发布流程必须另在新目录从同一冻结DB重新做STA/生成并完成两次离线SFC
转换及所有门禁，不能直接把此阶段SBIT视为已发布包。

主代理另以新的native24解析器读取本轮实际PRR/RTR/netlist及完成日志，
保存`fpga/build/clock_branch_physical_native24_20261007/main_audit.json`，
37输入哈希和4个当前物理链路来源均匹配。实际USCM_215_582/585分别为
915/6负载，同一GPLL_7_463/CLKOUT0。五个pad两角hold均通过，20条
data/ctl用户复位recovery/removal明细均正余量。GMII→IOL指定40组合仅
导出了TXD0/TX_DATA[1] fast hold（+0.103ns），另39组合无逐条明细；
全ETH汇总无违例不能冒充全部指定路径逐条审计。TXC独立hold、GRS/
异步复位释放、外部PHY/PCB及DVP pad预算仍未实测，局限显式保留。

旧资源Exporter测试已对接mandatory新证明而保留原10个正负例。
主代理完整审读最小diff，并在PS5.1/7分别独立重跑该10项及未改动boot
Exporter24项，均PASS。证据为缓存证明目录的
`main_legacy_resource_ps5_1805`、`main_legacy_resource_ps7_1805`、
`main_boot_exporter_ps5_1805`、`main_boot_exporter_ps7_1805`。
新发布子目录`final_180333_820_778fb75a`正在执行；无Flash访问、烧录、
冷启动或实板FPS测试，不宣称外部链路/真实1080p30已经验收。

### 已完成的离线发布包

`final_180333_820_778fb75a`独立STA于18:05:08完成、原生SBIT于18:06:57
完成，全部十表再次通过。随后PDS原生cfg_gen_sfc两次转换并交叉核对，
全部源/脚本/证明/副本及最终位流无漂移，Exporter正常结束。
发布目录为`fpga/release/geometry_20261007_e4dd5bbb06e6/`，
`offline_package_ready=true`。主代理再次独立核对532条输入/输出来源、
同一DB、57项cache证明归档、最终STA拓扑和两次转换哈希，保存
`main_release_review.json`，PASS。未经实板验证的各标志仍typed false。

发布SBIT及SFC均为3791112B，SHA256均为
`E4DD5BBB06E659C55ECB87B7A4F66385D0680A2D1C4DE46F838830B7AFA180A2`。
新生成的report SHA为
`2C287EB3680A1C2656B7D8DD0F4ECDF29D570EFAB559A45A55464AE6A2F0791D`。
发布生成物与上面阶段SBIT哈希不同，分别记录、不声称重复生成SBIT
必然逐字节相同；其与最终STA均明确绑定同一8993304B…EBBAA路由DB。
SFC验证使用同一发布SBIT两次原生转换，完整长度和哈希均一致。
STA工具曾提示`W: open run.log failed.`；实际绑定的完整stdout timing
日志、Report Timing完成标记、全十表及输出哈希均存在并通过门禁，
该辅助日志警告不隐瞒，也不当作时序违例或省略原生完成证据的理由。

本轮在`codex/fpga-geometry-correction`完成；无commit/push/merge，
不修改其他分支、primary checkout、参考源、官方文档或系统设置。
旧10/24项发布门禁兼容修复及新40项cache证明均保留独立来源和历史副本。
当前功能仍是增强Bayer RAW8网口、FPGA灰度原图/矫正和末端彩色编号
20点叠加；增强RAW8不冒充未经处理的S0。HDMI源帧身份仍null/unverified。

# 时钟、复位与板级 I/O 优化验证记录

日期：2026-10-12。依据：`output/FPGA分区优化交接/01_时钟复位与板级IO优化方案.md`。
目标：PG2L100H / FBG676 / -6；PDS 2022.2-SP6.4 build146967。

本轮落实了复位恢复、原生 HDMI 时钟拓扑、约束语义和工程入口修改。两套顶层分别完成隔离 Compile → Synthesize → Device Map → PnR → Report Timing，均为 **All Constraints Met**。这是已约束内部路径的结论；DVP、RGMII、HDMI 外部时序和完整帧恢复尚未签核，未下载或操作硬件，也未产生本轮发布位流。

## 1. 改动与实际收益

| 项目 | 接手时的问题 | 本轮实现及验证范围 |
| --- | --- | --- |
| 诊断像素复位 | `pixel_reset_stages` 只在 pclk 上升沿复位；pclk 停止后失锁仍保留释放状态 | 新增共享 `rtl/board/video_clock_start.v`：参考域三拍同步释放，失锁异步清除像素复位；ready 只进入一个首级，随后两级同域传播 |
| 原生启动 | 两套顶层不同；主顶层使用 CLKBUFR 和普通同步释放作为分频器/串行器启动 | 主顶层改用 IOCLKBUF，和诊断顶层共享原生启动控制；IOCLKDIV 与八个 HDMI OSERDES 共用专用启动脉冲 |
| RGMII 复位 | 原语直接接外部 reset；TX 未随系统 PLL 失锁复位；同步复位的 IDDR 在停 RXC 时可能保留 RX_VALID | I/O 包装内 TX/RX 各有三拍复位链，主顶层将 sys_lock 纳入复位请求；复位期间屏蔽 RX_VALID/RX_ER，原语模式与字节映射不变 |
| DDR 诊断域 | 用户侧复位只等待 init_done，心跳仅同步清零 | 用户复位同时检查控制器 PLL/PHY lock 与 init_done；心跳共享该域异步置复位/同步释放 |
| 像素约束 | 诊断 FDC 显式 `/5` 保留了 PLL 的 50% 占空比 | 两工程都用安装版 PLL/CLKDIV rename/infer 功能；PnR 报告确认为 13.468 ns、波形 `{0 5.387}`，约 40% 高电平 |
| 陈旧物理约束 | 主工程仍引用已不存在的各通道 `local_reset` 寄存器 | 删除对应 PAP_REGION 和 priority-net 指令，保留原生 DDR 约束；旧引用在本轮隔离构建中确实导致错误，修复后通过 |
| 工程入口 | 增加模块后已有 `.pds` 不会自动更新 | 两份 Tcl 加入模块；用原生工具重新生成两份共享 `.pds` 并再次 Compile，实施目录归 `fpga/build/` |

复位/RGMII 稳态数据路径没有增加字节流水级；新增延迟在启动/恢复阶段。启动等待没有缩短，也没有变更 125 MHz RGMII 或 74.25 MHz 视频节拍。150 MHz 处理域是已有集成目标，本轮通过其内部时序，不代表已实现真实图像流水的吞吐提升。

对照仿真保留原诊断复位逻辑模型：在两时钟均停止后拉低 lock，日志为 `baseline_reset_n=1 candidate_reset_n=0`。这是复位控制的 RTL 仿真对比，不是板上恢复时间或整帧发布证明。

## 2. 逐域清单

### pango_video_top

| 域 | 来源/频率/关系 | 消费者与启动条件 |
| --- | --- | --- |
| 参考 125 MHz | N3/N2 差分参考；8 ns、50% | 系统 PLL 与 DDR 原生控制器；管脚依据 MINI V1.3，实物仍待确认 |
| sys_clk | sys_pll OUT0，100 MHz | APB 占位、状态同步；外部 reset 与 sys_lock 后三拍释放 |
| proc_clk | sys_pll OUT1，150 MHz；与系统/发送域同源 | 候选 FIFO/RAM/APM 集成库；外部 reset 与 sys_lock 后三拍释放 |
| tx_clk | sys_pll OUT2，125 MHz | RGMII ODDR、发送候选 FIFO；各本地域三拍释放 |
| rx_clk | PHY RXC → CLKBUFG；约束预算 125 MHz | IDDR、RAW 候选 FIFO；包装层三拍释放并屏蔽复位期间有效位；尚未验证协商速率和 PHY delay |
| clk_27m | D18 板载 27 MHz；37.037 ns | 视频 PLL、启动计数；视频 lock 同步到参考域 |
| serial_clk | video_pll OUT1，27 × 55/4 = 371.25 MHz | IOCLKBUF → OSERDES；唯一 PLL 源，使用原生 I/O 时钟网络 |
| pixel_clk | 同一 PLL 源 → IOCLKDIV `/5`；74.25 MHz、40% | OSERDES 并行端、候选显示 FIFO；完整启动结束后经三拍同步链释放 |
| ddr_clk | 原生 DDR PHY user clock，125 MHz | 候选 DDR FIFO；外部 reset、组合 pll_lock 与 init_done 后三拍释放 |

原生 DDR 的 rst_clk、phy_dq_clk_0/1、phy_dq_sysclk_0/1 保留安装版 IP 的时钟/相位/多周期/不确定度约束。`ddr3_controller_ddrphy_top.v` 中 `pll_lock = phy_pll_lock & gpll_lock`；未凭其他平台更改其内部关系。

### mini_camera_diag/Top

| 域 | 来源/频率/关系 | 消费者与启动条件 |
| --- | --- | --- |
| sys_clk | D18 27 MHz 参考 | SCCB、摄像头配置、共享启动计数；外部 rst_in 与 video lock 后三拍释放 |
| camera_clk_0 | 摄像头 PCLK；100 MHz **分析预算** | RGB565 采集、写请求和写 FIFO；外部 reset/video lock 本地域同步释放，配置/DDR 就绪另由摄像头模块同步门控 |
| serial_clk | 同上 371.25 MHz，IOCLKBUF | HDMI 原生串行器，专用启动脉冲 |
| pixel_clk | 同上原生 `/5`，74.25 MHz、40% | 扫描、读 FIFO、编码、显示有效位；共享启动结束后同步释放 |
| core_clk | 原生 DDR user clock，125 MHz | 帧池、DDR 适配和心跳；外部 reset、PLL/PHY lock、init_done 后同步释放 |

摄像头配置就绪、完整帧、显示来源身份、DDR 在途事务并不是 PLL lock 的同义信号。两套工程均没有以此时钟审计替代这些业务契约。

## 3. 启动与 CDC 约束依据

共享控制器在参考复位释放后递增 8-bit 饱和计数器，保留 `0x4f..0x8f` 的低有效启动脉冲，共 **65 个参考周期**；到 `0xff` 才开放 ready。脉冲解除后仍有 110 个参考周期的稳定等待，再经三个像素边沿释放用户逻辑。相对原诊断控制器新增参考同步屏障，不能将其宣称为更快启动。

`audit_clock_reset.py` 检查了源码快照 SHA256、原生综合连接和布线实例清单：

- 两工程的专用脉冲寄存器最终只驱动 **1 个 IOCLKDIV RST_N 和 8 个 HDMI OSERDES RST**，没有像素数据或编码器负载。窄源例外没有掩盖新增业务路径。
- 参考复位到像素复位链的连接只落异步清零端；首级 ready 到后两级的数据连接实际存在，未使用整域 false path。
- ready 到单个 `pixel_ready_meta` 保留 6 ns datapath-only 上界和该跨域首级的 hold 例外；后续级正常计时。
- Gray 指针保留既有 6 ns datapath-only 上界和首级 hold 例外。主工程最快相关周期为 6.667 ns，诊断指针相关周期为 8/10 ns；未扩大既有边界。
- 每个存活 Gray 首级均与源指针 Q、同目标域的后一级 D 相连。源/目标端点计数来自综合，存活数量独立对照布线；位宽转换剪除的低位必须有 Device Map 明确的 dangling 清除日志。

| 工程/FIFO | 源→首级方向 | 综合源/首级数量 | 布线首级数量 |
| --- | --- | --- | --- |
| 诊断 write_buf | wptr→rwptr1 | 13 / 13 | 9 |
| 诊断 write_buf | rptr→wrptr1 | 9 / 9 | 9 |
| 诊断 read_buf | wptr→rwptr1 | 9 / 9 | 9 |
| 诊断 read_buf | rptr→wrptr1 | 13 / 13 | 9 |
| 主工程 raw_fifo | wptr→rwptr1、rptr→wrptr1 | 12 / 12；12 / 12 | 12；12 |
| 主工程 packet_fifo | 同上 | 13 / 13；13 / 13 | 13；13 |
| 主工程 read_fifo | 同上 | 10 / 10；13 / 13 | 10；10 |
| 主工程 write_fifo | 同上 | 13 / 13；10 / 10 | 10；10 |
| 主工程 display_fifo | 同上 | 12 / 12；12 / 12 | 12；12 |

这证明约束与被实现连接一致，不证明亚稳态 MTBF，也不是板级总线 skew 实测。两套候选日志无 Timing-4005/STA-3015 未命中警告；外部未约束警告仍保留。

## 4. 本轮仿真、时序及资源

### 功能回归

最新 Icarus 证据：`build/clock_reset_20261012/icarus_20261012_214723_970035/`。

| 测试 | 实际结果 | 边界 |
| --- | --- | --- |
| tb_video_clock_start | PASS，2,606 检查，5 次完整启动；包含原复位逻辑对照 | 控制逻辑模型；参考/像素停钟、lock 抖动和重启脉冲 |
| tb_board_io | PASS，6,372 检查，512 TX、1,026 RX 场景，0 错误 | 安装版未加密 GRS/CLKBUF/IDDR/ODDR 原样副本；2/3/4 级复位、双沿字节/控制、停 RXC 的复位与恢复 |
| tb_tmds_serializer | **未运行完成** | ModelSim 编译成功；仿真加载因缺少 qhsimvl/msimhdlsim 许可证失败；不能记为通过 |

ModelSim 失败证据：`build/clock_reset_20261012/sim_20261012_201900_468/`。Icarus 没有使用伪造 OSERDES 模型替代加密原语。更新后的串行器 TB 使用真实生产启动控制，待可用许可证下运行。

### 隔离 post-PnR

证据目录：

- 诊断：`build/clock_reset_20261012/mini_camera_diag_20261012_202337_439673/`。
- 主工程：`build/clock_reset_20261012/pango_video_top_20261012_202854_849495/`。

每个目录保留 `source/`、`source_hashes.json`、`flow.tcl`、`console.log`、`result.json`、原生 `.snr/.prr/.rtr`、`clock_reset_audit.json`。PnR 参数相同：`-congest_overlap_limit 20 -action_timeout 15`；min/max、Slow/Fast corner，30 条详细路径，无逻辑层数筛选。以下 WNS 为对应类型的所有时钟对汇总最小值；所有 TNS 与失败端点数均为 0。

| 类型 | 诊断 Slow / Fast WNS ns | 主工程 Slow / Fast WNS ns |
| --- | --- | --- |
| Setup | 1.155 / 2.085 | 1.463 / 2.085 |
| Hold | 0.137 / 0.101 | 0.138 / 0.102 |
| Recovery | 3.307 / 4.572 | 1.527 / 2.398 |
| Removal | 0.336 / 0.231 | 0.324 / 0.219 |

主工程 proc_clk 的同域 setup slack 为 1.463 ns；诊断像素域为 9.498 ns，主工程像素域为 10.266 ns。Fmax 估计没有作为新运行频率或完整有效帧率。

| 资源口径 | 诊断候选 | 主工程候选 |
| --- | --- | --- |
| 综合 LUT / FF | 6,196 / 6,119 | 3,666 / 3,561 |
| DRM36K / APM | 8 / 0 | 47 / 4 |
| GPLL / PPLL | 3 / 2 | 4 / 2 |
| IOCLKBUF / IOCLKDIV_E2 | 1 / 1 | 1 / 1 |
| 全工程 OSERDES_E2（含 DDR） | 87；HDMI 占 8 | 87；HDMI 占 8 |
| 布线 IO / IOLHR | 100 / 99 | 99 / 98 |
| 布线 IOCKB / RCKB / HCKB | 1 / 3 / 14 | 1 / 3 / 22 |

没有进行实测拥塞、功耗、温度或接口频率测量；PnR 完成表明本候选可布线，不等同热/电气签核。

### 基线比较的可信范围

| 指标 | 接手基线 | 本轮候选 | 可作的判断 |
| --- | --- | --- | --- |
| 停钟后失锁的诊断像素复位 | 对照模型仍为 1 | 同场景为 0 | 修复控制逻辑缺陷 |
| RGMII 停 RXC 后的复位有效位 | 原 IDDR 同步复位需 RXC；包装没有有效位屏蔽 | 明确为 0；恢复需本地域三拍 | 复位请求期间不能泄漏旧 RX_VALID/RX_ER |
| 完整有效帧吞吐、stall、服务时间 | 两顶层没有同口径真实业务测量 | 本轮也没有 | 不计算性能提升百分比 |
| 历史诊断综合 LUT/FF | 既有 2026-09-16 文件为 5,940 / 6,070 | 6,196 / 6,119 | 历史源码与当前摄像头配置实现不同，不能归因于本专项 |
| 历史主工程综合 LUT/FF | 2026-09-10 保存副本为 3,658 / 3,550 | 3,666 / 3,561 | 同样不是本轮开始时源码的冻结对照 |
| 同口径前后 PnR 时序改善量 | 未保留本轮修改前的完整冻结重跑 | 两候选各自通过内部 STA | 不将历史 WNS 差值宣称为优化收益 |

本轮没有补造“优化前”快照或把历史通过结果外推到当前代码。资源增长的局部设计理由：RGMII 新增两条三拍链；主工程新增文档要求的启动计数/脉冲；没有缩短同步链或用逻辑时钟节省资源。

## 5. 工程更新与复现

两套共享工程已原生重生成并 Compile 通过：

- 主工程：`build/pango_video_top/compile_result.json`，native_exit=0、error_count=0、audit_exit=0。
- 诊断：`build/mini_camera_diag/native_20261012_214503_355/result.json`，native_exit=0、error_count=0、新鲜 .cmr=1。
- 重生成前 `.pds` 副本：`build/clock_reset_20261012/project_before_refresh/`。未手工构造 `.pds` 分组，也没有编辑生成 IP HDL。

在仓库根目录运行，全部输出直接归 FPGA 开发区：

```powershell
python fpga/scripts/sim_clock_reset.py
./fpga/scripts/sim_clock_reset.ps1  # 需要可用的 ModelSim Verilog 仿真许可证
python fpga/scripts/build_clock_reset.py --project mini_camera_diag
python fpga/scripts/build_clock_reset.py --project pango_video_top
python fpga/scripts/audit_clock_reset.py fpga/build/clock_reset_20261012/实际候选目录
```

默认 Icarus 路径复用已有 `build/ov5640_pwm_20261012/tools/iverilog/app/bin`，可用 `--icarus-home` 指定；PDS/ModelSim 路径可通过参数修改。受限进程环境曾产生 WinError 623 或工具异常退出，保留失败目录；获自动审批后在本机同一 FPGA 隔离路径执行离线工具。本轮没有自动审批拒绝或未批准的硬件操作。

## 6. 官方来源与未覆盖项

只读查阅了 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/` 下的 Timing Analyzer、User Constraint Editor、Physical Constraint Editor、Route Constraint Editor 手册；提取文本在 `build/clock_reset_20261012/reference/`。关键依据为 Timing Analyzer §4.1 的 min/max 与筛选限制，UCE §2.2.1.2 的非 2 次幂分频占空比及原语 rename/infer。没有向官方文档目录写文件。

安装目录 `example/PG2L100H_lvds4to1/rtl/pgd_clk_rst_gen.v` 提供 IOCLKBUF/IOCLKDIV 和 `0x4f..0x8f` 启动结构。该例程自身是 `/2` LVDS，不能当作本项目 `/5` TMDS 的频率/电气验证；`/5` 依据本项目参数、MINI HDMI 主从级联参考及本轮 PDS 推导。MINI V1.3 硬件手册和 Logos2 DS04001 用于核对目标板/器件；模型副本记录了原始安装路径与版本且未改动。

剩余边界：

1. DVP 模式的 setup/hold、排线/PCB 偏差与 PCLK 实测；RGMII 两沿时序、PHY 内部 delay/strap、协商速率及避免重复加延时；TMDS 物理电气和输出时序，均未签核。Timing-4086 仍包含摄像头/RGMII、SCCB、复位和部分原生 DDR 双向端口；不能把内部 All Constraints Met 写为“无未约束 I/O”。
2. 未完成 C4 实板接口/恢复验证。摄像头输入停顿而 PLL lock 未掉时，本模块不推断帧失败；需要输入分区的异常检测和帧池生命周期处理。
3. 未完成完整帧/DMA 恢复：已有诊断帧池和 DDR 在途事务仍需协调丢弃、排空、取消确认及 FIFO 两端就绪。单域复位链和 RX_VALID 屏蔽不能证明“无非法帧发布”。主工程仍是请求空闲、PHY 保持复位、固定 HDMI 符号的集成骨架。
4. 未验证真实1080p30、ISP/矫正、RAW 千兆网完整帧率、同帧 S1/S2/S3 来源配对或功耗。来源身份继续保持 null/unverified。
5. 加密 OSERDES 动态行为回归等待可用许可证；本轮只有编译及物理实现证据。
6. 既有 over_temp=1 和下载放行条件未解除；没有生成新的可发布位流，也没有下载、压力测试、Flash/eFuse 或 JTAG 操作。

因此本次交付是 **01 分区的局部实现、控制/I/O 仿真及两工程内部时序验证**，尚不满足外部签核、完整业务性能与实板恢复的整体验收。

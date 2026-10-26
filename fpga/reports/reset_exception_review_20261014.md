# memory_armed 到 DDR PHY RS 的独立只读复核

2026-10-14 16:59；PDS 2022.2-SP6.4 Build146967，PG2L100H / FBG676 / -6。只读查阅 RTL、旧综合网表、历史 PLC min/max 文本报告及官方资料；没有执行 PDS/仿真，没有修改约束，没有停止任务，也没有读取正在写入的 PNR/fail DB。

## 判定

**正常时钟触发的 Q 下降边沿不可达证明成立；将其扩大成“板级复位断言期间物理 RS 一定连续保持高电平”的证明不完整。** 当前尚无 routed STA，应继续保持原约束。本审查没有认定已经存在实板短脉冲，也不建议现在实施 exception。

正式 `fpga/rtl/board/pango_video_system.sv:43,51–56` 用 `reset_sync` 生成 ctrl_reset_n；ctrl_reset_n=1 时，memory_armed 只在 memory_ready_sync=1 时写1，其余保持。旧综合网表 `board_20261014_112317_150547/synthesize/pango_video_system_syn.vm:1437775–1437787` 明确 D = memory_armed OR memory_ready_sync，1437842–1437849 明确独立异步 C 及 clk_27m。因此合法复位后的正常运行中，不存在由 clk_27m 上升沿使逻辑 memory_armed 从1变0的事件。当前 `delay_20261014_153410/source/rtl/board/pango_video_system.sv` 与正式源 SHA256 均为 `a71057761dd6ca887d79933971b73702e9c1fa13bb11a88f9a68fc6beb771a7b`，保留该逻辑。

原生 RS 组合方程（旧 vm第19–30行）是：

    R = !video_lock OR !reset_n OR fault_latched
        OR (memory_armed AND !ddr_ready)
        OR (memory_armed AND !ddr_lock)

对其他输入保持的单一 memory_armed 0→1 边沿，R只能保持或0→1，即断言复位，不能产生 active-high RS 的解除边沿1→0。memory_armed 1→0只能来自其异步清零；RTL中该清零由 reset_n=0经 rs_ctrl 断言触发。reset_n保持0且信号传播稳定后，独立 !reset_n 项确实使 R=1。reset_n重新释放本身是真实解除来源，应继续分析。

## 具体缺口与边界

旧 `reset_removal_audit_20261014_123500.md` 的“independent ~reset_n term already retains RS high”属于稳态布尔推理，不能单独证明引脚波形。两条重汇合路径为：reset_n→R LUT，以及 reset_n→rs_ctrl异步清stages→ctrl_reset_n→memory_armed异步清零→R LUT。后一条的memory_armed下降若先到，而前一条!reset_n尚未到，且原先由 memory_armed AND !ready/!lock 使R=1，则中间输入组合允许R短暂变0。是否实际发生、是否产生有效解除脉冲、DDR时钟是否仍活动均未知；PLC数据路线延迟为0不足以建立两条路径的最坏传播先后关系。直接路径较短也不能代替实际 min/max 到达界限。

该缺口不否定“clk_27m触发的Q下降不可达”，因为异步清零并非该CLK→Q启动弧。未来最窄约束只能表达这一时钟启动边界，不能用它宣称异步复位波形已验证。保留 reset_n、ctrl_reset_n、fault_latched、video_lock、ddr_ready、ddr_lock 等其他启动源的现有分析；本证明不推广到fault_latched或所有IP/复位路径。运行时全局复位等不属于本次已审查的板级复位契约，不能靠此证明一并豁免。

## 历史报告与端点职责

`placement_timing_diag_20261014_115943_459599/report_timing/pango_video_system.rtr:59005–59070` 是 clk_27m rising→`memory_armed/opit_0_inv/CLK`→Q falling→RS falling 的 min(slow) removal路径，slack -2.642ns、route delay0。这正是时钟触发单调性证明排除的事件，不是已发生的异步Q下降。该历史报告为PLC估计：2324条解析路径中2322条数据路线延迟为0；不能作为routed签核。

旧报告对调相模块列出memory_armed启动的38条路径（19个独立RS端点，各slow/fast min一条），另有fault_latched启动的38条同类路径。后者必须保留；报告有路径条数上限，未列出的来源不等于不存在。

代表端点 `.../cnt[2]/opit_0_L6Q/RS` 对应旧vm97074–97081的GTP_DFF_C异步C，D=N137[2]、CLK=dps_clk；`cpd_offset_cnt[0]`在97084–97092也有独立C、D、CE。模块内32个逻辑FF均以N0接C或P（cpd_state_reg[0]是GTP_DFF_P预置）；99265–99271、139310–139413将N0追溯到上述R方程。因而这些**具体复位pin**承担清零/预置，不能把相同cell的D、CE、CLK或数据路径一起切除。未来布局映射、打包或复制可能改变名字及对应关系，必须在新的routed DB中重新枚举并确认，不能沿用旧19个名字或套用全IP通配符。

## 若实际 routed STA 再报同类路径

安装版《Pango Design Suite User Guide》印刷p208明确：false-path的-from可选时序单元（表示其所有clock pin）或时序单元clock pin；p209允许精确终点pin。UCE手册p86–87支持get_pins/get_cells；p106–107支持完整层次与regexp查询。故最窄候选是**单个 memory_armed CLK pin→单个已证明的直接 RS pin**，对当前仅报出的min/removal类最多限定 `-hold`。不使用-from Q；Q可作为through辅助核对。若只有一个memory_armed cell及一个CLK，-from该cell与-from该CLK等价，pin枚举更明确。不能用-fall_from选Q下降：官方明确它只接受clock并选择启动时钟下降沿，此处报告启动clock反而为上升沿。

下列仅说明历史PLC对象范围，未执行、未验证匹配，不是可直接投入FDC的约束：

    from: memory_armed/opit_0_inv/CLK
    to:   I_ips_ddr_top/u_ddrphy_top/u_ips2l_ddrphy_rst_clk_phase_adj/cnt[2]/opit_0_L6Q/RS
    class: hold/min removal only

未来应先在确切routed DB中输出查询得到的全部对象及数量，核实启动对象恰为一个CLK，终点恰为一个真实复位pin；必要时用锚定regexp并正确转义位下标。PDS报告中的物理名字能否由该查询命名空间解析，本次未原生执行，仍不确定。空集合、意外多命中、无法确认RS为合法异步endpoint，均不得接受。

命中验证应以同DB约束前后的定向 `report_timing -delay_type min_max` 和 `-report_exception TRUE` 独立例外报告为证据：实际被豁免路径只允许指定memory_armed CLK→该RS的min类；其余同RS来源、memory_armed到D/CE等路径、max/recovery以及全设计时序仍应保留。补充逐端点报告，避免全局-max_path30隐藏额外命中；不可仅看“最差路径消失”或“All Constraints Met”。TA手册p14–16说明min/max/min_max、nworst/max_path、Exception独立报告及From/Through/To过滤；PDS指南p210–211定义对应报告查询。异步重汇合缺口需独立保留，false-path不会验证或修复它。

## 官方原件与出处

- 官方目录及全部参考原件仅阅读。`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Timing_Analyzer_User_Guide.pdf` 本次SHA256 `0714bec1196c68b6cc49771c1415bfc1d36062349b8ae52fa5e1d6767c03c53a`，与 `fpga/build/camera_input_20261012/reference/sources.json` 相符；抽取文本同目录，引用印刷p14–16。
- 官方 `User_Constraint_Editor_User_Guide.pdf` 本次SHA256 `23628d10ad9ac1d1f3817a560be8b7ddffea71e397833a2e7559f1e8c26252f2`；抽取文本在 `fpga/build/full_integration_20261013/reference/`，引用p86–87、p106–107。
- 官方 `Pango_Design_Suite_User_Guide.pdf` 与上一项router审查核实同源SHA一致，引用p208–211；抽取文本同上。
- 正式RTL：`fpga/rtl/board/pango_video_system.sv`、`fpga/rtl/board/reset_sync.v`；旧vm及PLC报告的实际路径/行号已在正文列出。

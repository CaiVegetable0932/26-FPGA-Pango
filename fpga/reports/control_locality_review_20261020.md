# 控制热点后续设计审查

2026-10-20，基于当前 12 项变更主设计。02:10 更新：帧池 slot-local token 标志候选已通过 10 组差分/参数测试和 20 项集成回归；snapshot-copy 六组局部 IDLE 标志候选已通过 12 组差分及 20 项集成回归。两者均保存在实验目录，尚未综合或合入，也没有区域布线结论。下文保留设计约束与准入要求，不能把提案中的估算当作综合结果。

## 已有证据与边界

历史完整工程第 14 轮拥塞快照及网表绑定见 `fpga/build/route_optimization/session_20261019/round14_hotspot_diagnosis.json`。原整机任务已停止，本审查没有重新运行整机布线。

| 对象 | 记录中的证据 | 当前处置 |
| --- | --- | --- |
| snapshot reader unpack N249 | 拥塞原始值 125，网表 CE 275 个寄存器负载 | 局部捕获已按三 seed 与完整功能证明合入；不是整机 30% 收益证明 |
| snapshot copy N112 | 原始值 84，网表 CE 132 个寄存器负载 | 六个同边沿局部 IDLE 标志实验已通过 12 组差分，未综合、未合入 |
| boot N2726 | 原始值 76，整机网表 CE 1168 个负载 | 局部 CE 副本功能证明通过，但物理初筛引脚不同；主设计已回退 |
| RAW pool token_busy[0] | 原始值 55，来自 bank 2 | 审查 slot-local 有效标志，未实施 |
| DDR PHY calib_done_11 | 原始值 53 | 不修改官方 PHY 或复制复位同步链 |

拥塞原始值不是百分比，也不能将不同消费者范围的网表负载混在一起比较。独立核布局和整机布局不同；任何新结构都需要同边界/同约束 A/B。

## 帧池 token 的局部化提案

生产 `frame_manager` 保留五个 bank、76 MiB 外部布局。slot 数为 3/3/3/1/1，事务容量为 3/3/2/1/1。外部存储容量不是片上 RAM 预算。现有逻辑以 pre-state 的 `token_busy && token_slot==slot` 推导 inflight、writer 数量和 drain_error，保持 ISSUE/COMPLETE 并发时计数不丢失。

可考虑为每个 slot/token 保存局部 active 标志；另一变体同时保存 writer-active 标志。五个 bank 共 26 个 slot/token 配对，因此分别约增加 26 或 52 个控制 FF，尚未综合，不能当作实际资源增量。控制集增加可能抵消扇出收益，不能只按 FF 数量批准。

必要不变量与更新顺序：

1. 局部 active 必须在每个检查周期等于原 `token_busy && token_slot==slot`；writer-active 再要求原 owner 为 producer。空闲 token 的未初始化 slot/owner 必须仍被无效标志屏蔽。
2. 仅在 `fabric_ready` 且原响应确认 ISSUE/COMPLETE 时更新。合法 COMPLETE 清除对应 token 的局部标志；合法 ISSUE 在同一边沿设置对应 slot，并清除该 token 的其他 slot 标志。保持原 RTL 的同周期赋值优先级。
3. ISSUE 只能使用 pre-state 已空闲且 ticket 未耗尽的 token。不能提前复用本边沿才 COMPLETE 的 token；inflight 仍在本周期计算中计入最终 COMPLETE，保持既有重用边界。
4. 全局 token_busy、完整 64 位 ticket、generation 与全部公共权限/ABA 检查继续保留。局部标志不能替代 COMPLETE 的 ticket 校验，也不能使 quarantine 下的命令获得 ACK。
5. 局部控制标志随原冷复位清除。token slot/owner payload 保持现有非复位策略；不能用局部清空假定 DDR 已经排空。不得改变 CDC、公共响应无效字段或同帧身份。

验证要求：独立原版/候选状态逐周期比较所有响应位，包括 inactive payload；覆盖 slots/transactions 参数、全部 owner、并发 ISSUE/COMPLETE、取消排空、错误 completion ticket、ticket/generation 饱和、quarantine、忙时复位，以及已有 idle payload X 注入场景。保留真实帧池压力/元数据/ticket 回卷和集成用例，不以只比较最终帧数替代协议证明。

每轮最多比较两个结构变体，未通过功能证明不得进入 native。综合后检查副本是否保留、token_busy 实际负载、局部标志负载、控制集及 LUT；再决定是否做局部物理比较。若面积下降但互连或控制集恶化，不自动推广。

## snapshot copy 元数据捕获提案

`snapshot_copy_dma` 的 N112 对应 start/ready 边沿捕获的 ss、rs、sg、rg、dsg、drg 等元数据；132 位负载不同于读取数据 buffer 的 256 位捕获。不要误将两种使能一起改写。

可研究按 32 位左右的消费者组保留 ready 的本地寄存器副本，必须与原 `state==IDLE` 在同一个边沿保持等价。副本需接收准确 next-state 的 ready 值，不能简单延迟当前 ready，否则会错过紧邻完成的 start。若重构 next-state，应该只有一个权威状态转移表达式，避免复制一份易漂移的错误/取消条件。

保留全部 payload 复位、元数据同一边沿捕获、r_valid/r_ready 数据捕获、读写不重叠、padding strobe 和 verified-write 完成条件。尤其覆盖 start 与 cancel 同时出现、最后一拍读写和 dma_done 同周期、错误 done_tag、取消发生在地址接受之前/之后。新增局部 ready 必须有逐周期不变量，并比较所有公共输出的无效周期行为。

该提案尚未说明能改善物理结果。先用真实 snapshot pair/ownership 夹具做差分，再综合查看 CE 是否真正分散；仅对最有希望的版本做相同固定引脚局部 A/B。若推广，必须与当前新 unpack 组合后重新跑全帧控制/快照/显示模型及原始字节核验。

## 时钟、资源与停止条件

### DMA 浅缓存的后备测量方向

若当前第三轮仍无法在限时内得到合格局部结果，可单独审查 DMA payload 存储组织，而不是重跑相同 seed。现有七客户端、16 拍、256 位 payload 只有 28,672 位（3.5 KiB），但独立综合实际占用 28 个 DRM36K；masks 已是本地 LUTRAM，报告 LUTRAM 112。宽端口和物理硬块分布可能影响互连，这是待验证原因，不是已证明的拥塞归因。

后续可先比较 payload 的 block_ram 与 lut_ram 属性，保持同一个同步预读模板、原 RAM 读写边界、MAX_BEATS、读回验证和未复位 payload。不能把属性在 RTL 仿真中被忽略后的“输出相同”当作 RAM 原语语义证明；必须检查实际映射、read-during-write 行为、同地址冲突、输出寄存周期及掩码。不得增加 no_rw_check。新增 LUTRAM/输出 FF 数量必须由实际综合确认，不能直接按位数宣称资源可用。

若需要原语仿真，安装版模型位于 `E:/PDS_Pangu/PDS_2022.2-SP6.4/arch/vendor/pango/verilog/simulation/`。仅只读引用匹配版本并记录路径/哈希；模型含专有版权声明，不把厂商模型或工具密钥复制到公开 Git。存在 GTP_RAM16X*、GTP_DRM36K_E1 和 GTP_GRS 模型；还需正确处理全局初始化与已有运行时 reset 的区别。

属性变体若表现出新的宽 WE 热点，再以单独第二变体比较局部 WE；不要同时改变 RAM 类型、仲裁编码、额外延迟和工具策略。保持 writer BRAM 与 tag LUTRAM 当前独立处置，不能把本提案扩展成全工程统一 RAM 类型。该后备方向尚未启动任何新候选或 native 作业。

实际生产 `pango_video_system` 从 DDR controller core_clk 驱动 `video_memory_core`，为 125 MHz。仓库其他历史 FDC 中存在 proc_clk 150 MHz，不代表当前生产连接已经使用它。当前选定 6 份约束未更改，DDR PHY 保持原字节；新 150 MHz 处理域需要独立 CDC/服务期限设计，仍待范围明确。

旧 11 项基线 MAP：LUT 41,341、FF 40,430、APM 117、DRM 98。与启动预算 50,000/95,000/180/120 的差额不是可任意花费的余额，还需承诺功能与调试预留；当前新 12 项设计尚待最终整机 SYN/MAP 复核。不可将本报告的 FF 理论数量或独立夹具资源简单加到旧 MAP 后声称通过资源验收。

整个设计完成前禁止整体 PnR/bitstream。新原生实验仍只有一个重型槽、每侧限时、停滞停止和 10% Codex 账户额度停止。没有定量依据不增加 effort 或扫 seed。本文不自动排队任何任务。


## 2026-10-20 03:35 当前状态

整个方案尚未完成；主设计仍为已经过完整功能验证的 12 项修改，没有合入以下实验。账户额度最近读数剩余 37%，10% 停止机制继续运行。整体 PnR / 位流门槛保持关闭。区域时钟统一 8 ns，不能据此宣称 150 MHz 或板级签核。

| 区域方案 | 最新证据与决策 |
| --- | --- |
| 帧池 slot-local flags | seed11 两侧完成；setup −0.450→−0.687 ns，候选时序失败，不合入，终止该候选 |
| snapshot-copy local capture | 两侧时序通过；PnR 37→38 秒、线长 10539→11165，无布线收益，保留原设计 |
| writer 完整 signed 乘积 A | 413798 次算术检查、31 组差分、20 项回归通过；APM 6→3，setup −7.796→−1.649 ns，仍失败，不单独合入 |
| 帧池 16 位分块完整 64 位计数器 | 11 组差分含 16/32/48 位进位与 64 位耗尽、20 项回归通过；256 个计数 FF 从 CE 改为连续更新，控制集 25→21。区域 slow setup +0.166 ns，但 fast hold −0.001 ns；不合入、不忽略违例。正在仅改变 decongestion 1→2 复核，RTL/引脚/seed11/8ns不变 |
| writer 两拍入口流水 B | 50 组独立字节记分板/范围/取消/延迟测试及20项集成回归通过。每帧入口多2拍，分段多0拍；不是逐周期等价。seed11 区域全角时序通过，slow setup +2.726 / slow hold +0.163 / fast hold +0.116 ns，线长22112。完整1080p控制/快照/显示模型正在运行，未合入；尚需有限seed7/13稳定性验证 |
| 独立150 MHz处理域 write CDC 原型 | 位于 `fpga/experiments/proc150/`，未实例化到生产工程。四组异步时钟/相位测试全部通过，每组32场景，覆盖数据/掩码、背压、取消、错误、复位。未做原生映射、CDC静态检查或整机吞吐验收，不能当作150MHz目标已实现 |

主要路径均相对于项目根目录：

- `fpga/build/route_optimization/session_20261019/control_writer_terminal_review_0323.json`：前三项物理终结结果。
- `fpga/build/route_optimization/pool_chunk16_20261020_025740_906990`：计数器候选及证明；screen `pool_unit_screen_20261020_030600_250387`。
- `fpga/build/route_optimization/writer_span_pipeline_20261020_031048_641108`：两拍 writer 候选290项输入、原始备份及语义证明。
- `fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_032713_550985`：writer B seed11物理结果。A参考输入、wrapper、引脚/时钟一致性见 screen 的 `physical_reference_reuse_20261020.json`；参考时序失败，不计算加速比。
- `fpga/build/full_integration_20261013/verilator_20261020_033308_185785`：writer B完整帧模型，03:35仍在运行，不计PASS。
- `fpga/build/route_optimization/proc150_write_cdc_20261020_031859_818696`：CDC原型独立测试。

续接先核对 quota / native_phase.lock / 活动进程，严格单个 PDS。当前唯一PDS是帧池 decongestion=2区域候选，writer完整帧模型可并行。计数器若通过，才做有限稳定性复验；writer也须完整帧和主机原始字节验证后才可单文件合入。已冻结ZIP/manifest不能覆盖；新检查点 `checkpoint_0335_manifest.json` 只归档已终结运行，活动任务排除。

处理域150MHz尚缺job CDC、联合复位/PLL接入、约束、全帧服务期限和资源验收，按原方案继续设计；生产DDR PHY和125MHz真实时钟保持原配置。不能以孤立桥接器通过代替整机设计完成。完成设计/仿真后通知用户，由用户安排其他智能体监控整体布线。


## 2026-10-20 03:48 小时进度

本小时主设计仍是通过完整功能验证的12项选择，整个方案尚未完成；整体PnR/位流继续停止。03:47账户额度剩余36%，到10%停止优化并交接。当前已推送检查点 `0586a64ff`；本小时证据将另行精确暂存提交，不能把未提交产物称为已上云。

- writer两拍入口流水：50组语义/范围/取消/延迟测试、20项集成回归通过，seed11/7区域时序均通过，slow setup分别+2.726/+2.419 ns。seed13正在运行。每帧启动多2拍，分段延迟多0拍。完整1080p控制/快照/显示模型仍在运行，未合入主设计；参考A时序失败，不计算加速比。
- 帧池16位计数分块：decongestion1有fast hold−0.001ns；仅改decongestion2后hold改善，但setup−0.333ns/14端点，仍失败。该结构不合入、不再扫seed。开始本轮最后一个结构候选8位分块，保留64位计数、原耗尽/代次规则；补测全部8位边界。20项回归通过，严格差分尚在运行，物理未启动。
- 帧池slot-local flags和writer仅算术A因时序失败拒绝，snapshot local capture无布线收益保留原版；原始结果与数据库已归档。
- 150MHz接口实验：写CDC四组异步时钟测试每组32场景通过；作业邮箱四组每组82作业通过。真实几何+读写CDC+native DDR模型三组测试通过，每组608256结果/保护区字节、三种增强模式。
- 双时钟整机小模型控制/快照通过：`verilator_20261020_034331_201913`。初次模型 `verilator_20261020_034204_198227` 失败已保留；测试从处理时钟返回后，控制提交未对齐DDR采样边沿。只修正激励时钟对齐、保留原身份/系数断言，新建快照重跑通过。
- 双时钟完整1080p控制/快照/实际显示模型 `verilator_20261020_034441_923014` 正在运行。生产PLL/125MHz/DDR PHY未改；150MHz目标尚缺原生映射、实际PLL/联合冷复位、CDC约束及完整服务期限验收，不能称为已实现。

当前唯一PDS为writer seed13；两个完整帧软件模型并行，不启动第二个PDS。实验目录 `fpga/experiments/proc150/` 不在生产RTL收集路径内。新模型闭包 `proc150_video_model_20261020_034322_763921` 位于 `fpga/build/route_optimization/`；所有未完成结果保持pending。

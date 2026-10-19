# FPGA 布线专项优化交接

更新时间：2026-10-20 00:40，北京时间。当前主设计的完整功能仿真已通过；整个优化方案尚未完成，禁止整体布线和位流生成。

## 项目和授权

- 本地项目：`D:\XDU\concept\26-FPGA-Pango`
- 分支：`codex/fpga-pds-project`
- 云端：<https://github.com/CaiVegetable0932/26-FPGA-Pango>
- 原方案：`output/FPGA布线效率与拥塞专项优化方案.md`
- 连续进度：`fpga/reports/route_optimization_progress_20261019.md`
- 区域矩阵：`fpga/reports/regional_verification_plan_20261019.md`
- 会话账本：`fpga/build/route_optimization/session_20261019/session.json`

用户允许模块/子系统隔离综合、局部布线 A/B；整个设计方案完成之前不得整体布线、生成完整位流。设计仿真通过后通知用户，由用户安排其他智能体监控整体布线。00:35 已通知当前 12 项变更版本通过完整功能验证；这不等于整个方案已完成。没有启动其他智能体，没有下载硬件。

`fpga/config/implementation_readiness.json` 的整体设计完成、最终源选择、资源约束审查和整体放行门槛仍关闭。常用整机恢复、实现及直接 bitgen 入口检查该门槛。不得为运行而直接改为 true。区域入口只接受已审查的 DMA、boot、unpack、raw reader、writer 顶层，不生成位流。

原整机 seed 11 在 10 月 19 日 21:46 按用户要求停止；整体停止文件保留，旧自动队列已停止。旧结果的 `stage=gen_bit_stream` 是历史脚本固定标签，真实 `native_runs` 为 PnR/PAUSED，没有执行 bitgen。后续脚本已修正阶段标签。

00:56 入口补查：当前便携构建脚本的 full/route-map/route-placement 也在创建目录或 native 启动前检查门槛，三项真实 CLI 拒绝检查通过。未来打包会携带门槛记录和依赖助手。历史便携包未改写、不作为本轮实现入口；不要用旧 runner 绕开当前监督、限时和设计完成门槛。

## 当前主设计与验证

主设计共 12 项选定修改：writer BRAM 等已验证基线 11 项，加 `rtl/memory/dma_byte_unpack.v` 的局部捕获控制。第一轮 grouped DMA、boot 局部捕获均已回退。任何实验 source 目录都不能整体覆盖主工程。

| 证据 | 结果与位置 |
| --- | --- |
| 完整 20 项回归 | PASS，`fpga/build/full_integration_20261013/sim_20261020_001153_047628` |
| 1080p 控制、同帧快照、实际显示 RTL 模型 | PASS，`fpga/build/full_integration_20261013/verilator_20261020_001232_095496` |
| 显示逐像素检查 | 22,809,600 像素，失败 0、下溢 0；3 新帧、8 重复帧 |
| 几何作业周期 | 4,073,517 / 3,796,435 / 4,114,261，与原基线一致 |
| 真实主机解码器离线校验 | PASS，`host/reports/fpga_rgb_vectors_20261020_003432_815058.json`；8,888 报文、12,441,600 图像字节 |
| 原始快照对照 | datagrams 13,028,208 字节、descriptors 288 字节，SHA-256 与原基线完全一致 |
| 输入绑定 | 290 个主设计源码与已验证快照全部一致；全帧模型 72 个输入已核对 |
| 合入与回退备份 | `session_20261019/unpack_promotion_20261020/promotion.json`、`before_dma_byte_unpack.v` |

上述 `session_20261019` 均位于 `fpga/build/route_optimization/`。原快照 SHA-256：datagrams `f42a234194de8b85d182f6e4d1ae089d3f02266d8e1918fb0a027853e5c01669`；descriptors `1f7791da07114603493586ee16181dae243ab13a38b9085d15da53d887666366`。接受记录单列为 `unpack_finalist/selection_promoted_20261020.json`，历史 pending selection 保持原字节。

这些是合成夹具/模型证据，没有实板验收。现有真实处理/DDR 时钟为 125 MHz，6 份生产约束与原已验证基线哈希一致，见 `constraints_clock_review_20261020.json`。方案的 150 MHz 目标未验收；是否本轮建立独立处理域与 CDC 的范围问题尚待用户答复，不假定已同意延期或已经实现。

历史 Icarus 全帧补充场景 `sim_20261019_214646_986066` 为 TIMEOUT（1,200 秒），不能改称 PASS；之后上述独立 Verilator 完整场景已通过。

## 区域测量与当前任务

所有实验根目录为 `fpga/build/route_optimization/`。诊断扫描边界的资源不计入生产模块增量；内部 STA 通过不等于板级 IO/CDC 签核。新物理试验固定相同诊断引脚并核对最终实际映射。

| 项目 | 当前结论 |
| --- | --- |
| unpack 真实 RGB reader | seed 11/7/13 原版 PnR 44/45/44 秒，候选 36/38/39 秒，两侧全过内部 STA；中位降低 13.64%，最大值 45→39 秒。已按 modest improvement 合入，30% 建议目标未达到，不能推断整机加速 |
| writer 通用动态参数 | 两侧布通但 STA 失败，最差路径经过动态 span_end 乘加/合法性检查；不是已证明的缓存关键路径 |
| writer 实际 ISP 常量连接 | `writer_bram_screen_20261020_001911_724767/unit_screen` 两侧布通、STA 通过；PnR 49→48 秒，无显著时间收益；线长 16,853→18,376，slow setup 2.964→3.090 ns。LUT 1183→1034、FF 535→531、DRM 0→4、控制集 12 不变。只代表 ISP，不代替动态几何 writer 验证 |
| 第一轮 grouped DMA | 局部候选 STALLED，已从主设计回退；自动引脚试验只能初筛 |
| 第一轮 boot 局部捕获 | 功能证明通过，两侧布通且 STA 通过，但 PnR 109→121 秒；实际引脚不同，不能将差异全部归因于 RTL。已回退，尚未固定同引脚复核 |
| 第二轮 DMA 等待统计 | 固定引脚候选 STALLED，1,050.547 秒，最优剩余 1,430；参考布通但 STA 未过。未推广 |
| 第三轮 DMA A：局部游标 | 10 项差分、12 组参数、逐周期游标一致性通过。综合 LUT 3950→4004、FF 1508→1535、控制集 51 和 DRM 28 不变；35 个局部 FF 保留，中央低四位负载 56～59→4～7。局部物理比较正在运行 |
| 第三轮 DMA B：A 加局部统计 | 同样功能证明通过；综合相对 A LUT 4004→3599，FF 1535、DRM 28 不变，控制集 51→57；slow 综合 slack 0.203→0.427 ns。尚未物理验收，未推广 |

当前唯一 PDS 任务：A 的固定引脚新鲜 A/B，入口 `probe_regional_route.py --screen .../dma_local_cursor_20261019_234450_385383/owner_unit_probe_20261019_235108_893996`。B 综合终态在 `dma_cursor_stats_20261019_234450_843063/owner_unit_probe_20261020_002531_993874`。不要另开并发重型 PDS。

第一份 writer 固定参数夹具 `writer_bram_screen_20261020_001808_201768` 因生成常量位选语法失败，未进入综合/布线。修正为具名 localparam 后，两侧独立编译和上述物理验证通过；失败记录保留，不归咎生产 RTL。

## 继续顺序和未完成项

1. 完成第三轮 DMA 的固定引脚局部物理筛选，保持同一 seed/时钟/工具策略。停滞、超时和时序失败如实保留，不自动扫 seed 或延长预算。若考虑复用 A 作为 B 参考，必须核对源字节、wrapper、实际引脚、时钟和策略完整相同；不能把单侧结果改称已完成 A/B。
2. 仅合入通过评审的单个 RTL 文件。DMA 实验 source 不含当前新 unpack，不得覆盖整目录。合入后重新冻结选定源码，重跑必要回归、全帧模型和输入绑定；不能复用含旧 DMA 的模型冒充新源码通过。
3. 复核 token_busy、pool 控制和 snapshot-copy 使能热点；目前只是静态审查，没有启动第四轮候选。保留 ticket/ABA、frame identity、取消排空、复位和 CDC 语义。无测量依据不改算法。
4. 最终选定源码后可做整机 SYN/MAP 资源复核（`build_video_system.py --stage dev_map`），不执行整体 PnR。旧 11 项基线 MAP 为 LUT 41,341、FF 40,430、APM 117、DRM 98；它不是新 12 项设计的实测资源，也不是时序签核。
5. 明确 150 MHz 范围，完成所有区域处置、资源/时钟/约束复核及最终源码功能证明，再通知用户设计阶段完成并交接。整体三 seed、完整 routed setup/hold、外部时序和硬件 1080p30 均未完成。

保持真实 1080p30、位精度、同帧身份、原图和生产功能。不修改官方 DDR PHY，不扩大 false path，不以降频、删掩码或关闭功能换取成绩。官方 `E:\PDS_Pangu\PDS_2022.2-SP6.4\doc` 及原始 reference 保持只读。

## 停止、额度与 Git

- 00:38 最近 Codex 账户额度剩余 40%，以带时间戳的 `quota_observations.jsonl` 为准。不是上下文 token 百分比。到 10% 时，活动监控写整体和区域停止文件并收尾，不再优化。
- 整体停止：`session_20261019/stop_requested.json`；区域停止：`regional_stop_requested.json`。原整体停止标记不得删除。监督器每 30 秒检查；已有停止标记会阻止进程创建。
- 区域物理每侧总上限 20 分钟，包含新鲜 compile/SYN/MAP/PnR/STA。有合格成功基线时执行原方案自适应上限；停滞门槛不因 CPU 忙而取消。
- 互斥锁：`fpga/build/route_optimization/native_phase.lock`。只停止自己的 PID 树，不按进程名杀 PDS；正常结束必须检查残留。`Saving design to DB` 可能耗时数分钟，应结合 CPU/内存与硬上限调查。
- 00:48 已按小时汇报，下一次约 01:48。可运行 `python fpga/scripts/optimization_status.py --session fpga/build/route_optimization/session_20261019` 查看状态；原 watcher 在后台运行。
- 最新源码/完整功能证据检查点：`20f5269f66d33b647cdd64dd10a720bb19e76cfe`，已核对远端。之前为 `29265c6f`、`482ac2f7`、`cd78b6a2`、`0b45b46a` 等。后续文档以 `git log` 为准。
- 初始工作区有 212 项 tracked 修改及大量构建文件，清单在 `initial_git_status.txt`。只能按本轮 scope 暂存；禁止全量 add 或新增忽略项。
- 原生数据库/拥塞文本压缩归档带逐成员哈希；冻结证据 manifest 按对应检查点 commit 校验。已验证的历史输入不覆盖。`fpga/.gitattributes` 和选定 host 报告规则仅关闭换行转换，不忽略文件。
- 推送采用单次代理参数 `-c http.proxy=http://127.0.0.1:7897 -c http.sslBackend=openssl -c http.version=HTTP/1.1`，没有关闭证书检查或更改全局配置。
- GUI 只读 diff 曾留下空索引锁。只有确认原持有进程已退出、锁已老化且当前 Git 均为更晚启动的只读进程后才能清理；不得删除活动锁。核查记录已归档。

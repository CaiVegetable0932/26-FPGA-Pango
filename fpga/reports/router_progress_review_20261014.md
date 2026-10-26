# 原生路由进度与参数解释复核

2026-10-14 16:33–16:36，PDS 2022.2-SP6.4 Build 146967，PG2L100H / FBG676 / -6。本次只读审查文本日志、已完成的 MAP、PCF、约束及既有官方文本抽取；没有编辑 RTL/约束/工程，没有启动 PDS/仿真，没有停止进程，没有读取正在写入的 PNR/fail DB 或锁文件。

## 当前可核实状态

| 实现 | 实际参数 | 已读取的最新阶段 | 结论 |
|---|---|---|---|
| `hybr_b_20261014_143515/resume_20261014_151539_697611` | decon1 / seed11 / normal / control-chain500 / congest200 / native timeout0 | 详细路由 iteration11：56316 未布通 / 111464 subnets；该轮 CPU459.703125s | 尚无成功或失败结论 |
| `delay_20261014_153410/resume_20261014_160518_945164` | 同上 | placement1252.55s，结束估计 worst slack -1560；global routing95.86s；详细 iteration0：86182 / 110713，CPU37.75s | 尚无成功或失败结论 |
| `phys_20261014_161729_818241/resume_20261014_161747_780579` | 同上，仅 decon2 | Swap/DP 详细布局；DP10 wslk -900，Swap12 wslk仍-900 | 尚无成功或失败结论 |

动态日志会继续追加，上表是审查时点的记录。日志未发现这三次运行已出现 Route-4022 / Route-0008。布局 slack 仍为中间估计，不能作为 routed min/max STA 验收。

`delay` 与 `phys` 的已完成 MAP SHA256 完全一致：`28bf22ff10a8ff38c56f3147a7e70c98f711adf90000ad29fd82840095c648af`；PCF 均为 `8232194b097eba4d9cdda670d606a4ff319ae46fec1ce171cd5be8b51e003585`；`clocks_cdc.fdc` 均为 `ecce7782818ac02c24a39bb539c12654227f4f61e0494a9d9c27aeeb81f078b6`。其 Tcl 第90行仅 decon 值不同，构成同 MAP、同 seed 的独立比较。三份脚本第3行均明确目标 Logos2 PG2L100H -6 FBG676；MINI V1.3 硬件手册也将对应器件归为 Logos2。

## 官方选项与日志的正确含义

安装版《Pango Design Suite User Guide》印刷 p117–119 的特别说明仅把 PG2L100H 的 General、Router 归入 Logos 列，未把 Placement 切换过去。Placement 应使用 Logos2 列的 Swap、默认 decon1、cluster/duplication/logic optimization 开启、LUT6D策略3。实际日志中的 Swap/DP 符合此解释；不能据 Router 特例改成 Logos 的 Bump。

印刷 p111–112：decon 是面积扩展系数。一般较大值扩大布局范围，但时序可能变差；主要 LUT/FF/APM/DRM 资源最大使用率超过70%时，布线速度变化不确定，建议0–4。此70%不是 CLMA/CLMS site 占用率。此前跨 RTL、seed 的失败不能归因于 decon 一项，也不能预先认定本轮2优于1。

印刷 p113、p119、p252：`-congest_overlap_limit 200` 是拥塞模式最大迭代次数，是上限而非保证执行200轮；它也不是全局路由每个分组的统一停止轮数。官方材料未公开 Route-4022 的内部提前判停公式。已结束旧 decon3 实现日志在详细 iteration5 后真实报告 `W: Route-4022: Routing failed as its congestion.` 和 `E: Route-0008: Design cannot be routed.`，不能把未跑满200轮写成超时；官方错误附录 p267 将 Route0008 列为布线失败。

印刷 p111：`-action_timeout 0` 仅关闭 PDS 单种子原生超时。外围 Python 的240分钟超时是另一层限制，不应混称为 PDS 自身拥塞失败。已经由操作者终止的 `phys_20261014_151852_531451/resume_20261014_151907_767406` 保留 `termination_note.json`，不列为自然路由失败。

全局路由分组反复出现的 `Unrouted nets 0` 只属于对应阶段。hybr 在 global step4归零后，明确重新开始111464 subnets详细路由并打印85808→56316。因此0不能作为整板 route success。详细未布通计数也不等于完成比例或预计剩余时间；下一轮允许拆线重布，单轮变慢不等于冻结。该轮 `CPU time elapsed` 与对应 `CongestionPlot` 的 `iter_time_consume` 一致，是该轮用时，不是累计总CPU。

## 已完成轮次的拥塞证据

按官方 p113 定义，`CongestionNetInfo` 记录详细路由各轮冲突 net 信息。本次统计已稳定的 hybr iteration10 文件，没有读取最新轮正在生成的数据库。它有57349条记录、47641个独立 net name，与日志 iteration10的58129未布通计数不相等，不能逐一映射或将同名条目假定为独立设计 net。

| 层级 | 记录条数 | 文件内 congestion value 总和 |
|---|---:|---:|
| core/processor/geometry | 9261 | 18405 |
| core/fabric/frames | 6822 | 20989 |
| DDR PHY | 3739 | 10191 |
| core/fabric/dma | 3218 | 11659 |
| core/network | 2508 | 4706 |
| snapshot service | 2286 | 5872 |
| core/processor/refill | 2150 | 5286 |

最大的6个记录来自帧池，其值为101、77、71、69、68、66；随后可见 DMA read_index、geometry refill、snapshot chunk_bytes 等。上述 value 总和仅用于同文件内观察分布，不是官方定义的归一化拥塞率，也不等于面积、关键路径或唯一原因。可证实的是多模块路由压力仍存在；现有记录不足以证明只修改某一层即可收敛。

## 后续最多两项建议

1. 优先让已运行的 `delay` decon1 与 `phys` decon2 同 MAP 对照完成，保留 seed11 和全部默认 packing/router 设置。比较真实 route结果、完整用时、实际 CLMA/CLMS sites、LUT–FF pairs、复制记录及每轮拥塞分布；获胜候选还必须通过同 DB 的完整 routed min/max STA，再生成位流。hybr 属于另一 MAP，应单独报告，不能参与 decon 单因素归因。
2. 如果上述对照均自然报告拥塞失败，下一项独立试验可复用完全相同 MAP、PCF、FDC，保持选定 decon，只将官方 `-gplace_seed` 改为7，形成与 seed11 的单因素比较。官方 p252 将该项定义为随机种子；现有证据不保证7更优。保持原时钟、8ns约束和异常路径边界，不同时改 duplication、packing、router权重，也不因为此前 decon0被主动结束就认定0不可布通。

## 资料与实际文本来源

- 官方原件只读：`E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf`，本次实读SHA256 `e2ac3f2ac7bb539cc51fe85cc239ea2249f4ee6790912b67c86cae23a3898ba2`，与既有抽取source.json匹配。引用印刷p111–113、p117–119、p252、p267；已提取文本位于 `fpga/build/full_integration_20261013/reference/Pango_Design_Suite_User_Guide.txt`。
- MINI V1.3 既有只读抽取：同目录 `教程1_盘古MINI系列开发板硬件指导手册_V1.3.txt`，器件说明行214、347。
- 各次实际日志：上述build目录的 `place_route/run.log`；实际命令：对应resume目录的 `place_route.tcl` 第90行。
- hybr迭代10：`hybr_b_20261014_143515/place_route/CongestionNetInfo/CongestionNetInfo_10.txt` 和 `CongestionPlot/CongestionPlot_10.txt`。
- 旧自然拥塞失败：`board_20261014_112317_150547/resume_20261014_114346_235148/place_route.log`，详细路由1364–1383行，Route0008第1462行。

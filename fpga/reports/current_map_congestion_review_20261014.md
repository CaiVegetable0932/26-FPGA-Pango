# 当前同一 MAP 的拥塞与 token 代际冗余审查

2026-10-14 21:18–21:26，PDS2022.2-SP6.4 Build146967，PG2L100H-6FBG676。只读检查 D=`delay_20261014_171555`、E=`phys_20261014_191736_199955`、G=`phys_20261014_204447_217557`；不修改冻结源码、RTL、约束或工程，不运行 PDS/仿真，不读正在写入的 PNR 数据库。没有新增路由成功、时序或位流证明。

三份实际 `sources.json` 各290项逐项重算 SHA256，均完整；实际 MAP=`device_map/pango_video_system_map.adf` SHA256 均为 `d77373411015c61d83b0d5216df68d169e5303fe6f4c466dec40ae4d15d2d993`，PCF 均为 `e4fbc6cfc3166dd9a57787de7a2105d86553f0459859d57f48e9964919912df8`。D/E 是 seed11/7；G 是 D 其余参数保持并关闭布局复制。不同物理位置不代表不同 RTL。此前 B 的生成网名和物理位置未用于本审查。

## 报告实际提供的信息

官方指南印刷p113–114定义 CongestionPlot 为每轮 SRB 拥塞，CongestionNetInfo 为冲突 net 信息。原官方 PDF 本次只读重算 SHA256=`e2ac3f2ac7bb539cc51fe85cc239ea2249f4ee6790912b67c86cae23a3898ba2`；结合 `fpga/build/full_integration_20261013/reference/Pango_Design_Suite_User_Guide.txt` 第2788–2799行核对。官方目录没有写入提取物。

实际 CNI 每条只有 `congestion value`、`drive info` 物理站点/端口、`design net name`。没有 load 列表、实际 fanout、RTL 表达式、net bbox 或最终 slack。生成 N 编号不能单独对应源码运算。SNR 提供层级综合资源和部分预布局时序路径，其中路径 net 的 fanout 只覆盖该报告所列路径；controlsets 提供 clock/reset/CE 组合及相关 DFF 数量/驱动类型，不能视为所有路由 net 的通用扇出表。CCR 是约束适用性报告，D 原检查0错误/61 critical warnings/957约束；PCF 是已生成物理约束，两者均不能解释拥塞根因。冻结 MAP 是工具二进制容器，本次没有自行反解。

## 同轮与最新完整轮观察

统计采用完整第6轮；SRB sum/阈值数量为本审查统计，官方未定义为归一化拥塞率。CNI记录数、独立名字数和日志未布通子网数不相等，不换算完成百分比或 ETA。

| 第6轮 | D | E | G |
|---|---:|---:|---:|
| 未布通子网 / 总子网 | 69560 / 109660 | 64810 / 108895 | 68527 / 109815 |
| SRB最大值 / sum / ≥40格 | 60 / 175659 / 533 | 62 / 160469 / 458 | 60 / 164435 / 380 |
| CNI记录 / 独立名字 / value sum | 68504 / 55807 / 177712 | 63864 / 52161 / 165167 | 67518 / 54814 / 173971 |
| geometry / cache / step value | 26405 / 11139 / 7940 | 22079 / 7910 / 7145 | 26113 / 10880 / 7897 |
| frames / DMA / refill value | 20714 / 13196 / 5768 | 20733 / 12894 / 5183 | 20469 / 12747 / 5429 |

21:23读取的最新完整轮为 D20=51630/109660（CPU971.5s），E14=49984/108895（CPU617.53125s），G7=65750/109815（CPU157.046875s）。不同轮次只作状态记录，不排序为最终优劣。D20/E14/G7的 SRB最大值分别38/35/55，CNI value sum119708/118566/164438；没有由下降趋势推断最终收敛。

同 MAP 多轮可追踪到持续层级压力：D20 geometry/cache/step=16881/7018/4719，frames15698、DMA10137、refill3061；E14为14285/4439/4494、16641、10527、3249。refill/N23350 在第6轮 D/E/G 为221/193/516，位置分别 CLMA_243_1122:Y1、CLMA_249_1020:Y3、CLMA_231_1135:Y1；最新 D20/E14/G7 为73/89/284。D20最高是 bank3/N553=91，E14第二是 bank2/N3362=83，G7仍是 refill/N23350=284。多模块压力存在，但这些材料不足以给 N23350 或 N553 指定对应 RTL 运算/唯一根因，不能据此添加优先网约束或改算法。

上述 CNI 完整文件散列：D6 `4cb4dcc53f7413bc7fb8f7fed8717e711be69cb9e0ae70e821d28f27aed9ff16`；E6 `82326ce8c6e0e7ba33ba8003503373e34ded87b38c6a05949d4199b5f3053ad3`；G6 `a95e334e45cb440f00ee4d201eae974b45831f8c1325c1e4c24d880f916c4179`；D20 `057773a8cd1dbf6da3f33e526484f57c1da0759d357347bc16cc4fa24b2de524`；E14 `208b5f63c9035ac0416dbe78362e6a26c2be38046d565fb58d8471255ac8d957`；G7 `d25343cc31665138a8fdfb1f12f4e7d03a6eb79b6e99432dda4e2494c61c94c8`。来源为各自 `place_route/CongestionNetInfo`、`CongestionPlot`、`run.log`。

## 可审查的最小源码候选：只删除内部 token_gen

冻结 `source/rtl/memory/frame_pool_bank.sv` 中 `token_gen` 只在第153行的 inflight/writes/drain_error共同 guard 比较、第114行声明和第441行 ISSUE 写入出现。主板 `video_memory_core.sv:338` 实际 BANK_TXNS=4；因此五个 bank 声明合计640位 token_gen，不能按模块默认8算1280位，更不能把声明位数当作实际综合收益。当前 CNI 中 token_gen 自身记录最高值仅3：D20有473条/value764，E14有441条/value812，G7有553条/value1013。此候选来自生命周期冗余，未证明它是拥塞主因。

可达状态归纳不变量：任一 `token_busy[t]` 为1，必有合法槽 `s=token_slot[t]`、`busy[s]=1`，且 `token_gen[t]==generation[s]`。

1. **复位基例**：同一 reset_n 清 slot busy/generation（349–352行）及所有 token_busy（410–414行），不变量为空真。token payload 为时钟写入，即使复位期间存在无效旧载荷，token_busy=0排除观察，下一次 ISSUE原子覆盖。
2. **新 ISSUE**：227–234行要求目标预状态 busy 且公开 ISSUE_GEN 等于 generation。producer 要求未 sealed；consumer 要求 refs 对应位为1，并排除同拍该位 RELEASE。释放条件359–360行要求 sealed且所有 refs=0，故新 ISSUE 当拍不能释放目标槽。ALLOC只选预状态 !busy，不能同拍改写该目标 generation。ISSUE 写 token_gen 与 token_slot，并置 token_busy，因此建立不变量。
3. **已有忙 token 保持**：按归纳假设，第153行使所属槽 inflight至少1；COUNT_BITS=$clog2(TXNS+1)足够容纳全容量。释放要求 inflight=0，故不能清 busy；generation只在预空槽 ALLOC 时改变，故无法改变该槽 generation。
4. **COMPLETE 与 ISSUE 同拍**：COMPLETE只匹配预忙 token+完整64位 ticket，free_token只选预空 token，因此二者不选同一 token。最后一个 token 完成的当拍仍计入预状态 inflight，槽最早下一拍释放。过期/错误 ticket 不清 token。retire后不变量对该 token 不再要求。
5. **CANCEL/错误/故障**：CANCEL与completion_error修改 sealed/legal/pending而不清忙 token；CANCEL及对应drain_error还阻止新 ISSUE。没有本地 flush 清槽而保留 token 的分支。父层 frame_manager 25–27行同一 reset_n 传给所有 bank，fabric 263行同一 rst_n、controller_ready&&!fault；fabric_ready=0时槽与 token 控制全部保持。冷复位对所有控制同时清除，适配器旧响应 flush仍是既有系统合同，不能因本候选省略。

因此，在现有复位/同步时钟语义、无测试层 force破坏内部状态的可达执行中，可将第153行缩为 `token_busy[t] && token_slot[t]==a`，删除 token_gen 声明/写入；其余 generation32、ticket64、公开 ISSUE/SEAL/CANCEL/acquire/release generation校验、next_order64及全部耗尽拒绝逻辑原样保留。保留这些公开检查是证明成立的条件。

本报告21:18–21:26阶段仅代码归纳审查，未实现/推广候选，未执行formal工具、仿真或native综合。建议隔离副本执行old/new全部rsp位逐拍差分，并对旧实现断言该不变量；覆盖最后token完成与release/cancel/新ISSUE同拍、完整错误/stale ticket、消费者旧generation、fault hold/resume、任意相位reset及generation/ticket/order耗尽边界，再跑既有frame manager/pressure/snapshot/fabric/network恢复测试。最后以同版native综合/MAP实际资源决定是否值得整板试验。当前 D/E/G保持原冻结来源继续路由；没有安全依据直接修改正在运行的三份工程。

21:28之后追加授权的独立候选、实际Icarus差分/回归及四项单位ADS结果另见 `fpga/reports/token_generation_probe_20261014.md` 与 probe 的 `evidence.json`；两阶段范围和证据不混用。候选仍未推广，单位收益不是整板路由证明。

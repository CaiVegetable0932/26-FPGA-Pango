# 2026-10-15 布线效率检查与定向修复

本次目标是完整位流，保留既定功能与时序要求，不执行烧录。检查对象为主任务 J `phys_20261015_060945_294286` 和备用 E `phys_20261014_191736_199955`。本报告初始记录于 11:04，后续结论只能依据实际产生的结果补充。

## 已查明的耗时来源

- 进程持续计算：15 秒复采中，E 消耗 14.953125 秒 CPU，J 消耗 15.015625 秒 CPU；未发现等待调度造成的主要停顿。两个 native child 均为 Normal 优先级，CPU affinity 覆盖全部 16 个逻辑处理器。主机为 Ryzen 9 8945HS，首次采样可用内存约 5.25 GiB。这些数据不证明缓存或内存带宽完全无影响。
- 官方安装版《Pango Design Suite User Guide》印刷 p117 明确 PG2L100H 为单线程布线器件，General/Router 按 Logos 列。不能使用其他 Logos2 器件的多线程设置来加速本器件。
- 主要耗时是详细路由反复消除拥塞。11:02 已完成 J25：46,862/108,267 条未布通；E71：35,309/108,895 条未布通。J15→25 净减少 5,817 条、消耗 9,687.40625 秒 CPU；E61→71 净减少 690 条、消耗 10,084.84375 秒 CPU。未布通数会反弹，不线性推算 ETA，不把这些数值换算为完成比例。
- 当前已完成 CNI 中，几何、帧池、DMA 均有持续冲突。J25 对这些三级层级聚合的 congestion value 分别为 14,393、13,519、9,453；E71 分别为 8,379、12,246、7,545。聚合值是本次诊断统计，既不是 net 数量，也不是官方归一化拥塞率。CNI 不能独自证明某个 RTL 表达式是唯一根因。
- 同一 H 源码已自然失败的物理报告记录 CLMA 86%、CLMS 88%，而 DRM 仅 58/155。其 DMA 层级为 2,995 LUT、678 FF、689 distributed RAM、0 DRM。此资源分布支持把 DMA 宽数据缓冲移入专用 RAM 的定向验证；不能当作 J 的最终物理利用率。
- `owner_20`、`beat_index_20` 等生成网名不能按后缀解释为 RTL 位宽：实际冻结源码 owner 为 3 位、beat_index 为 5 位。未进行错误的截位优化。

详细数据和 CNI 文件 SHA 见 `fpga/build/full_integration_20261013/route_efficiency_diagnosis_20261015.json`。原生源、约束、MAP、在途数据库均未改写。

## 单个定向修复

独立副本 `dma_bram_repair_20261015_110034_546007` 基于 H 的完整 290 文件冻结集，仅改 `rtl/memory/ddr_native_dma.v`。七客户端、每客户端 MAX_BEATS 容量、写前全量预留、完整掩码回读验证、所有权、取消排空及故障语义均保留。

256-bit payload 使用同步读块 RAM；使用下拍游标预取保持 native W/readback 连续 beat 的吞吐。小规模 strobe RAM 仍使用分布式实现。每个客户端读突发在 `returned` 后增加一个读端口稳定周期，避免依赖混合端口同地址读写的器件行为。该延迟必须通过整帧性能验证，尚不能凭局部 PASS 声称满足 1080p30。

准备脚本为 `fpga/scripts/prepare_dma_bram_repair.py`。依据安装版 ADS 指南 5.16 的 `block_ram` 和同步读推断模板；未使用 `no_rw_check` 放弃一致性。原始官方 PDF SHA 为 `9930e586e71fed2faedf239b6af965eda69845f494fd506d2e708cf9f6fed9f0`；PDS 用户指南 SHA 为 `e2ac3f2ac7bb539cc51fe85cc239ea2249f4ee6790912b67c86cae23a3898ba2`，均实际只读复核。目标板仍按 reference 中 MINI V1.3 的 PG2L100H/FBG676 资料核对，官方目录没有写入。

六项初步回归位于 `sim_20261015_110110_252183`：DMA、frame fabric、ticket rollover、pixel writer、geometry processor、NETWORK_TEST=1 视频核心全部通过。DMA 检查 396 项事务场景、389 次 native transaction、4,072 beats；几何三帧校验 608,256 字节；网络恢复核心 3 good/2 processed。后续需完整 1080p/control/snapshot 模型、实际综合/MAP、路由后 min/max 时序及位流生成，当前没有新位流。

## 11:20 验证进展

- 原版和候选各自完成 MAX_BEATS=4/5/16 × seed=42/1907/20261015，共 18 个用例，全部通过。最初 cap4/seed20261015 在原版、候选均超时；诊断发现测试台退出 mixed 压力与随机 ready 驱动同在负沿执行，末次随机值可能覆盖 `r_ready='1`。将退出动作移至正沿后 1ns，保留全部断言，18 项重跑通过。原失败日志、诊断副本、实际重跑 fixture SHA 均保存在 probe。随后 live fixture 仅将注释措辞修正，逻辑与通过版本一致。
- 同一目标器件、8ns 时钟、完整 DMA ABI、VERIFY_WRITES=1 下，原版/候选原生 compile+synthesize 均 exit0。LUT 4,848→3,966（−882），FF 1,510→1,504（−6），distributed RAM 1,008→112（−896），DRM 0→28，controlsets 均 51。ABI 的 5,929 个抽象端口用于综合对照，不是板级 I/O 或时序签核。
- `verilator_20261015_110249_115579` full-frame/control/snapshot PASS，实际 71 个模型输入 SHA 完整，和新整板 `delay_20261015_111425_510321` 的 70 个共同 RTL 输入完全一致；整板与修复副本的全部 290 项 SHA 一致。
- 模型 3 good/3 processed，6,220,800 字节像素检查通过，最后一帧几何耗时 4,072,757 周期，125MHz 下为 32.582056ms，小于 30fps 的 33.333333ms 周期。原模型最后帧为 4,014,191 周期；修复增加 58,566 周期。该数值只描述模型最后帧，不是所有场景的最坏期限或实板实测帧率。
- 模型实际 wall 821.283s / CPU 811.375s，仿真终止于 366ms；未触及 1200s 超时。`host/reports/fpga_rgb_vectors_20261015_111930_213424.json` PASS：8,888 包/12,441,600 字节，两个描述符来源相同，冻结 companion 及实际导入文件散列完整。两份输出 bin 的 SHA 与 H 原模型一致。
- 新整板综合/MAP 在运行；现有 J/E 尚未终止。尚无新的 routed DB、时序通过或位流。


## 2026-10-15 DMA BRAM route repair / bitstream-only scope

Completed candidate `delay_20261015_111425_510321` compile/SYN/MAP with native exit 0, no E errors and all 290 source hashes intact (1330.769 seconds). MAP: 43,867 LUT / 42,536 FF / 1,809 distributed RAM / 125 APM / 86 DRM / 115 IO. Compared with H MAP: -937 LUT, -42 FF, -896 distributed RAM, +28 DRM. SYN: 43,874 LUT / 42,547 FF; controlsets remain 735.

The exact DMA source was promoted after checking the original live SHA and tested candidate SHA. Full 1080p/control/snapshot model `verilator_20261015_110249_115579`, six recovery regressions, 18 original/candidate burst regressions and frozen host decode `host/reports/fpga_rgb_vectors_20261015_111930_213424.json` passed. Last modeled geometry frame: 4,072,757 cycles at 125MHz = 32.582056ms; this is not measured hardware throughput.

Primary native PnR started at 11:36 in `resume_20261015_113643_076635`, Normal / seed11 / decon1 / control-chain500 / congest200, preserving every clock and I/O constraint. `complete_video_after_map.py` then requires actual routed min/max success before bitgen and strict source-bound packaging. J `phys_20261015_060945_294286` remains the sole backup. E was deliberately stopped at 11:30 with exact process-identity and before/after source guards; its Flow-0189 is a consequence of that stop, not a natural route failure.

No new routed timing pass or bitstream yet. No programming or programming preparation. Detailed evidence: `fpga/reports/route_efficiency_diagnosis_20261015.md`.


## 2026-10-15 12:17 route-only congestion-cost repair

K completed placement in 1160.92s; final detailed-placement wirelength 2,128,716, checksum 461BCEA49DA7CD60. Global routing took 100.52s; detailed routing contains 106,286 subnets. K0/1/2/3 left 81,540 / 78,172 / 74,883 / 72,185 subnets, with CPU 34.59375 / 39.125 / 66.5 / 356.03125s. J at the same first four rounds left 83,430 / 80,563 / 77,405 / 74,672, CPU 34.5625 / 35.171875 / 37.640625 / 42.984375s. Thus the BRAM change reduced resources but did not demonstrate early route acceleration. No eventual convergence or failure is inferred.

K was deliberately stopped at 12:15:54 after exact executable/parent/command/creation and all 290 before/after SHA guards. Its Flow-0189 and driver exit1 result from this stop. All evidence and the completed PLC remain preserved.

L `phys_20261015_121417_911429` copies the exact K290/MAP/PCF and completed PLC, SHA `ceeac3f728848fb736296eb221d848236792a7e22d6afce4232e2674179cc5d8`. Resume `resume_20261015_121627_645743` explicitly passes `-input_place_db_file` and `-pin_cost_increasing_speed 600`. The official installed guide p113/p252 and native help document this integer congestion-pin cost (default300); 600 is a task-selected repair value, not a vendor-recommended optimum. PDS accepted the native command and directly started routing, with exactly K's 89,621 nets, initial slack -2581 and TNS -50574. No new global placement occurred. The command's default seed7 does not describe the reused seed11 placement; source placement provenance is recorded separately.

Timing weight, clocks, constraints, functional RTL, model and host evidence are unchanged. `resume_video_system.py` now accepts an optional explicit pin cost; omission preserves existing behavior. `route_and_package.py` in L continues through strict routed min/max, bitgen and packaging only after success. J remains the only backup. This is not a new RTL optimization sweep. No new bitstream or hardware action.

## 12:43 实际收敛复核

L 已完成详细布线第 3 轮，未布通子网为 68,911/106,286，本轮 CPU 757.515625s。相同布局、默认代价的 K 第 3 轮为 72,185，本轮 CPU 356.03125s。提高代价后该轮剩余数较少，但单轮耗时增加，不能宣称已经加速。继续保留 L 与备用 J；不从这些早期点外推完成时间。

12:42:56 采样中，L native child CPU 累计 1539.71875s、J 为 23725.109375s，均仍在计算且原生日志无 E 错误。J 最后完成第 29 轮，未布通 45,292/108,267。两者均无完整 routed database、路由后时序通过或新位流。记录源为 `route_observations.jsonl`，不是硬件验证。

## 13:04 起：先筛布局，再投入完整布线

用户要求持续改进流程直到得到可烧录位流。L 第 4 轮剩余 66,987/106,286，本轮 CPU 1847.375s，增加拥塞代价未证明有效加速。继续保留 L/J，使用当前额外可用内存启动一个仅布局对照 M `phys_20261015_130413_702013`（session95598），不重新综合、不改 RTL 或约束。M 的 290 项源、MAP/PCF 与 K 完全相同，和已通过完整帧模型的 70 项共同 RTL 实际 SHA 匹配。

依据同版本官方指南 p111–112 的宏单元策略定义及已安装 pnr help，只将 `early_block_placement` 从默认 Greedy 改为 Global，保持 normal、seed11、decon1、默认 packing/duplication 和所有时钟。`probe_video_placement.py` 使用 `-place_only`，单独保存结果，绝不将 PLC 或 placement PASS 当作 routed STA/位流。原生子进程 PID89468/parent93680 实际接受 `-early_block_placement Global -place_only`，日志明确 `Process macros using "Global"`。

当前 M 合法化线长 1,261,729，K 同阶段为 1,311,252；进入详细布局前估计 slack 为 −3758ps，K 为 −4781ps。这些只是中间阶段指标，仍须等待最终布局。只有完整比较后才决定是否投入完整 route；不将这些差异宣称为最终时序或加速结果。`observe_video_routes.py` 已增加独立 placement_probe 观察，防止自动跟进重复启动或误分类。

## 13:22–13:28 布局筛选结果与后续

M 的仅布局 native exit0/E[]，290源与 MAP/PCF 完整，耗时17m48s。最终线长1,950,816（K为2,128,716），checksum BB773E6299C19C0D；最终估计 WNS −3681ps、TNS −51983ps（K为−2581/−50574ps）。CLMA9657/11675、CLMS4097/4975，均约83%。PLC SHA `9ec90f36cba6ce0a7e16dd5555454e9b5dd6931ee17d04f77c6cf9eafd399850`。线长较短但最终估计时序较差，因此先保留作后备，未启动 M 的完整 route。

`diagnose_placement_timing.py` 在隔离目录 `placement_timing_20261015_132407_840278` 对 K/M 已完成 PLC 副本各做一次原生 min/max 诊断，均 exit0/E[]，源及原/副本 PLC SHA 完整。该报告内部数据路径的 Route 为0ns，业务时钟两者均报告相同的逻辑路径裕量2.422ns；它不能重现 placement 的估计线延时，也不能消除最终 WNS 的担忧。报告中的 hold 违例和 setup 裕量均不能当作实际 routed 结果。后续不重复用 PLC 的这种报告判断物理时序优劣，位流签核仍必须来自真实 routed DB。

第二个单变量仅布局对照 N `phys_20261015_132726_317635`（session34389）在13:27启动，同一 K290/MAP/PCF、模型70共同 RTL 实际 SHA 一致；只将宏策略改为官方 Grouped（按设计特征优先放置），其余仍 normal/seed11/decon1/默认 packing。原生 child95240/parent95916 已接受该参数。L/J仍运行；所有现有候选尚无新的完整位流。


## 13:50–13:55：Grouped 布局进入完整布线

N `phys_20261015_132726_317635` 仅布局 native exit0/E[]，290源和 MAP/PCF 实际哈希完整。22m53s 完成，最终线长2,110,037，checksum1B483BC9DD94B02C，最终估计 WNS −683ps/TNS −3544ps（K为−2581/−50574ps）；这不是实际 routed 时序通过。完成 PLC SHA `58b6c2624afa3c50dbd96af0c1a089b379fb67ef6f1e4dee74ddd2b32ba30895`。13:51 从该检查点恢复 route，原生确实直接进入 Routing、初始 slack −683/TNS −3544；共89,394 nets。session97717，resume_20261015_135149_170395，native child92124/parent12440。自动驱动保留实际 routed min/max、bitgen、严格来源打包的顺序和门禁。

L 增大 pin-cost600 后，第4轮消耗1847.375秒CPU，之后超过40分钟仍未输出下一完整轮，未证明加速。13:52经精确PID/parent/command/creation和290源前后SHA检查主动停止L，结果exit1/Flow0189由主动停止引起，不是自然路由失败。所有日志、检查点与termination_note.json保留。N使用默认代价300，J继续作为备选。时钟、约束、功能与仿真来源均不变。

统计亮度候选 `statistics_logic_20261015_134936_111978` 使用官方ADS5.7 `syn_dspstyle="logic"` 把3个常数乘积映射到LUT，不改变公式、位宽、舍入或时序周期。原版与候选全部16,777,216种RGB的luma_sum/luma算术比对PASS，单元原生综合均exit0/E[]。LUT336→423，APM3→0；相同8ns约束下估计周期7.121→6.225ns，估计slack0.879→1.775ns。综合估计包含估算线延时，不能当作整板routed结果。最初探针因ADS拒绝测试封装的通配端口`.*`失败，改显式连接后重跑通过，原失败证据保留。该候选尚未改live RTL、尚未整板模型或MAP，暂保留为潜在时序修复；不为了局部估计收益打断正在进行的N布线。


## 14:14：统计映射候选完整模型通过，整板综合继续

隔离整板 `delay_20261015_135803_804440` 只替换 `rgb_frame_statistics.sv`，源290份；完整模型 `verilator_20261015_135828_904297` 的71份实际源完整，与整板共同70份RTL全部一致。full-frame/control/snapshot通过，3 good/3 processed、6,220,800像素字节、最后帧geometry_cycles=4,072,757，与K模型相同。实际模型wall814.637s/CPU803.844s。`host/reports/fpga_rgb_vectors_20261015_141351_843344.json`通过8888包/12441600字节，两个bin的SHA与K/H基线相同，冻结companion和真实导入文件完整。尚未推广live RTL或进入候选PnR，整板SYN/MAP仍在运行。

N详细第4轮71817/106276，本轮CPU636.03125s；此前第3轮74015/177.046875s。仍无完整PNR、routed时序或位流，不从单轮结果推断最终收敛。14:10前进程审计显示两条路由CPU约99%在用户态计算；14:04采样可用内存5673MB，pages input/output均0。该采样支持计算搜索是当前主要瓶颈，不是硬盘等待或暂停；不把单次采样推广为整个运行期。


## 14:21–14:22：统计映射整板 MAP 完成，进入物理筛选

`delay_20261015_135803_804440` compile/SYN/MAP自然exit0/E[]，1398.795s，原/候选全部290源SHA完整。SYN 44,112 LUT；MAP 44,103 LUT、42,543 FF、1,809 distributed RAM、86 DRM、122 APM、115 IO。相对K MAP增加236 LUT/7 FF、减少3 APM，其余相同，不能称面积节省。业务时钟SYN估计period9.141→8.732ns、slack−1.141→−0.732ns；最差路径从refill start_x→burst_beats变为isp_writer APM→address，仍只是综合估算。

新MAP SHA `c476d7a14d3d04a839b0f8897cbdf4a966db022a5c55d44a91502d57c7944998`，PCF SHA `61a0d6a06a59f2eeb82de15406be23e854ce145d22f5cd5b40cf995d3a3dc09d`。`source_identity.json`绑定新完整模型及14:13主机报告，host SHA `2bc7005fc663a17bf6d0747f2cfabffd6635006e189aeea8c495214db770b049`。live统计RTL未更改。

同目录开始一次Grouped/seed11/decon1/normal仅布局（session49320），和N选项相同，比较的是已验证统计映射改动后的物理结果。该流程不会自动生成位流，不把placement pass当作route或timing pass。N主布线、J备选继续，N最新详细4、J最新详细34均未完成整板route。


## 14:45：统计候选布局完成，按最终时序不投入布线

`delay_20261015_135803_804440` 的Grouped仅布局在14:42:51自然完成，native exit0/E[]，20m29s；最终线长1,928,300，checksum67F60AC8C9683C4F，最终估计WNS−1350ps/TNS−17901ps。PLC SHA `ded072b2ccff9cc8ef2c7de40bf8d6da526737a03886db0f439a73f5ea943996`。本轮重新核验290源、71模型源及70共同RTL、MAP/PCF/PLC和host报告实际SHA，均完整。

虽然线长比N的2,110,037更短，但最终估计时序劣于N的−683ps/−3544ps；此前DP中间的正余量和单元/综合的改善没有转化为最终布局收益。按用户时序优先要求，本轮不选用该候选进入完整route，不改live统计RTL，保留全部证据供实际失败后复核。具体决定保存于placement_probe/selection.json，台账移入completed_placement_probes，避免自动跟进重复处理。

14:45一次观察：N详细5剩70422/106276，本轮CPU1282.109375s；J详细35剩43418/108267，本轮CPU1436.859375s。真实原生进程均存在且CPU递增，无E错误，均无完整PNR、routed时序通过或新位流；保留健康进程，不重复启动，不外推完成时间。本次未烧录。


## 2026-10-15T16:13:02.761658+08:00：N 自然拥塞失败，启用已验证候选 O

N 在16:04:51自然退出1，原生日志明确 Route-4022 拥塞失败及 Route-0008 无法布通。详细第8轮剩64649/106276，单轮CPU2154.25s；总routing7637.05s。CLMA9976/11675、CLMS4240/4975（报告均86%）。没有完整PNR、routed STA或位流；并非主动停止。原始日志、result与SHA保留于N/natural_failure.json。

重新核验候选O全部290源、71模型源及70共同RTL、MAP/PCF/PLC、主机报告及9份冻结源/8个导入和输入bin，全部一致。保留14:47原选择记录，在placement_probe/route_reconsideration.json记录改选理由：N已实际失败，O最终线长1928300比N2110037短约8.6%；O最终估计时序-1350/-17901ps虽弱于N，但好于保留的Global M。短线长只是选择依据，不保证收敛或时序。复用完成PLC避免重复综合/布局，严格route→min/max→bitgen→绑定该候选模型和主机报告打包。保持J继续运行，live统计RTL未改，未操作硬件。

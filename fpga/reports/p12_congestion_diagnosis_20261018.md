# P12 第51轮拥塞诊断

观察时间：2026-10-18T16:19:25.869429+08:00。原完整布线继续运行。

日志只在完整内部迭代结束时写入未布通数量；第51轮完成时间15:52:55，33,042/100,568未布通。15:55:10至16:18:03，原生路由CPU时间从42,222.25增加至43,481.0625秒，约占单个逻辑核91.7%。尚未完成的下一轮不能报告实时剩余数，也不能从CPU活跃推断收敛。

## 持续热点与驱动位置

| 信号 | 驱动位置（非冲突点坐标） | 第51轮拥塞值 | 第47–51轮该逻辑网最大值 |
|---|---|---:|---|
| `boot/N2726` | `CLMA_231_1002:Y0` | 95 | 113 / 124 / 122 / 121 / 95 |
| `core/processor/refill/N712` | `CLMA_261_756:Y3` | 90 | 106 / 100 / 109 / 103 / 90 |
| `core/fabric/dma/owner_16` | `CLMA_249_828:Q3` | 64 | 64 / 64 / 57 / 64 / 64 |
| `I_ips_ddr_top/u_ddrphy_top/ddrphy_rst_n` | `SRB_336_852:ZQNE[0]` | 64 | 54 / 37 / 61 / 60 / 64 |
| `core/raw_writer/writer/stored_0` | `CLMS_309_979:CR1` | 64 | 59 / 59 / 39 / 64 / 64 |
| `core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_3` | `CLMA_225_852:CR2` | 64 | 46 / 52 / 52 / 55 / 64 |
| `core/fabric/dma/N1130_1` | `CLMA_231_883:Y3` | 63 | 55 / 62 / 59 / 62 / 63 |
| `core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_2` | `CLMA_225_852:Q2` | 63 | 39 / 54 / 50 / 51 / 63 |
| `core/raw_writer/writer/N1262 [1]` | `CLMA_309_972:Y2` | 62 | 60 / 57 / 58 / 53 / 62 |
| `boot/geometry_guard/index [0]` | `CLMA_267_678:Q0` | 60 | 27 / 27 / 21 / 60 / 60 |

N712已由真实映射网表追溯为refill写使能译码：输入包含reset、row[0]和write_beat[1:0]，不是此前试验过的输出窗口选择器。DMA owner_16为owner[2]复制寄存器，并参与宽数据选择。boot/N2726为启动控制中的三输入与译码（N542、N1272、state_reg[2]）。这些是已确认的冲突相关信号，尚不能认定仅修改其中一处即可解决全局拥塞。

原始冲突文件含32,610条记录，同一逻辑网可在不同驱动节点重复出现。拥塞值及其累加值不等于33,042个未布通子网，不可把记录数当作子网数。

拥塞矩阵为204行×61列，最大值28；最高原始单元（从0开始）为(row57,col45)、(row51,col53)、(row43,col36)。矩阵与PDS界面的方向映射未核实，因此不把这些单元直接称为物理SRB坐标。可在PDS中加载已归档CongestionPlot_51_observed.txt并搜索上表驱动节点周边，核对真实冲突区。

## 后续处理重点

优先审查refill写使能译码的局部化和真实扇出，其次处理DMA owner与宽选择的区域耦合；RAW writer和快照解包的计数/选择控制也属持续热点。帧池和DDR PHY周边存在分布式冲突，保留官方PHY和固定引脚。先前refill输出窗口改写与DMA one-hot方案已筛掉，不重复宣称为新优化。当前按用户要求保留原P12布线，不修改正在运行的冻结源码或重启计算。任何候选均需完整功能、1080p30预算及真实布线时序验证。

证据：`D:\XDU\concept\26-FPGA-Pango\fpga\build\route_campaign_20261015\batch01\attempt02_p12_restart_20261017_135034\congestion_diagnosis_iteration51.json`。其中保存各轮SHA256、完整前20条热点、分组统计和原始矩阵单元。

## 17:07 更新：第53轮

最新完整迭代仍为53，未布通32,913/100,568；第51→52→53轮为33,042→32,995→32,913，实际仍缓慢下降。16:56:31至17:07:42原生CPU累计增加620.75秒，表明继续计算；第54轮尚无完成统计，不能把第53轮旧值当作实时剩余数。

| 网络 | 驱动节点（非冲突坐标） | 拥塞值 |
|---|---|---:|
| `boot/N2726` | `CLMA_231_1002:Y0` | 95 |
| `core/snapshot_connected.snapshots/copy/N112` | `CLMA_195_870:Y0` | 87 |
| `core/processor/refill/N712` | `CLMA_261_756:Y3` | 78 |
| `core/fabric/dma/owner_16` | `CLMA_249_828:Q3` | 64 |
| `core/fabric/dma/owner_2` | `CLMA_249_828:Q2` | 64 |
| `core/raw_writer/writer/stored_2` | `CLMS_309_979:Q0` | 64 |
| `core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_3` | `CLMA_225_852:CR2` | 64 |
| `core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_2` | `CLMA_225_852:Q2` | 63 |

热点仍集中于启动控制、快照复制/解包、refill写使能、DMA owner及RAW写入控制。第53轮证据见同批次congestion_diagnosis_iteration53.json；当前原布线继续，不修改冻结工程。

## 19:28 更新：第58轮与原生CPU进展

19:13:21完成第58轮，未布通32,740/100,568，已布通按差值为67,828。第55–58轮未布通为32,771、32,925、32,850、32,740，三轮净减少31，存在反复，收敛很慢。19:18:21至19:28:00原生路由CPU从53,794.28125增至54,367.75秒（增加573.46875秒），约占单核99.2%；最新完整迭代统计暂未刷新，不是CPU停止的证据。无新的原生错误、routed数据库或位流。

|网络|驱动位置（不等于冲突边坐标）|第58轮拥塞值|
|---|---|---:|
|`core/processor/refill/N712`|`CLMA_261_756:Y3`|102|
|`boot/N2726`|`CLMA_231_1002:Y0`|96|
|`I_ips_ddr_top/u_ddrphy_top/ddrphy_rst_n`|`SRB_336_852:ZQNE[0]`|64|
|`core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_3`|`CLMA_225_852:CR2`|64|
|`core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_11`|`CLMA_231_865:CR0`|64|
|`core/raw_writer/writer/N1262_0`|`CLMA_309_972:CR1`|63|
|`core/raw_writer/writer/N1262 [0]`|`CLMA_309_972:CR2`|62|
|`core/fabric/dma/N1130_1`|`CLMA_231_883:Y3`|62|
|`core/raw_writer/writer/stored_0`|`CLMS_309_979:CR1`|61|
|`core/snapshot_connected.snapshots/reader/unpack/core/snapshot_connected.snapshots/reader/chunk_bytes_12`|`CLMA_231_865:Q0`|59|
|`I_ips_ddr_top/u_ddrphy_top/calib_done_7`|`CLMA_291_852:CR0`|58|
|`core/fabric/dma/owner_2`|`CLMA_249_828:Q2`|58|

持续热点已定位到refill写使能译码N712、boot启动译码、快照解包计数控制、RAW writer控制、DMA宽选择以及DDR PHY复位/校准相关网络。N712值102高于第53轮78；DMA owner_2为58、owner_16为50，说明冲突在网络之间转移。拥塞值不是未布通子网数，驱动坐标不是实际争抢的路由资源坐标。当前证据支持多区域控制/数据互连拥塞，不能断言单个模块是唯一根因。继续原布线，不改冻结源码、不新增布线。证据：同批次congestion_diagnosis_iteration58.json。

## 最终第62轮与会话状态纠正

2026-10-18 21:18 原 P12 自然结束，Route-0008: Design cannot be routed，退出码1。第58至62轮未布通数为32740、32670、32509、32417、32652，总子网100568。最终剩余32652，按差值已布通67916；没有合格位流。原PDS进程已自然退出。当前活跃PDS属于delay_20261018_212631_898400的综合/MAP，并非原详细布线。active_work_state中旧current_attempt字段已纠正为终态，避免会话状态误导。

最终热点：boot/N2726（CLMA_231_1002:Y0，131）；refill/N712（CLMA_261_756:Y3，72）；RAW N1262_2（CLMA_309_972:Y0，64）；DMA owner_16/owner_2（CLMA_249_828:Q3/Q2，64）；DMA N1082_0（CLMA_261_906:Y1，64）；帧池banks[1].pool/N1216（CLMA_159_1074:CR0，63）；快照chunk_bytes_2（CLMA_225_852:Q2，62）；DDR PHY复位（SRB_336_852:ZQNE[0]，59）。这些是拥塞相关网络的驱动位置，不是实际争抢路由边的精确坐标。

计数只在完整内部迭代结束后刷新；活跃CPU只能证明计算持续，不能证明净收敛。最后数轮的回升说明消除局部冲突没有实现全局收敛。当前优先验证refill写上下文局部化候选，31项差分已通过，完整MAP仍在执行，尚未证明物理拥塞改善。证据见congestion_diagnosis_iteration62.json及原始最终日志。

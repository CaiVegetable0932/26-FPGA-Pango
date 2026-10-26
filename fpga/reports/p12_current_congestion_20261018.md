# 当前 P12 布线拥塞检查（2026-10-18 23:43）

构建：`phys_20261018_223932_310478`，P12 refill_write_context，batch02 attempt01。

原生父子进程 72284/88252 的创建时间、父进程和完整构建路径与启动记录一致。23:41:26 至 23:43:46，子进程 CPU 累计从 4067.90625 秒增加到 4206.171875 秒，约 139 秒墙钟消耗 138 秒 CPU，表明仍在计算。日志在完整迭代结束时输出子网数，不能以会话活跃或短期日志不变单独判断卡死。

最新完整详细布线为第 18 轮：44,774 / 101,351 未布通（44.18%）。第 16/17/18 轮分别为 46,315 / 45,468 / 44,774；单轮 CPU 为 278.48 / 313.39 / 363.16 秒。仍在下降，但每轮耗时增加、净减少量下降。全局布线的零剩余不代表详细布线完成。

## 当前高拥塞网络

| 拥塞值 | 驱动位置 | 网络 |
|---:|---|---|
| 86 | `CLMA_243_480:Y2` | `core/isp_writer/writer/N578` |
| 64 | `CLMS_105_175:Q1` | `core/fabric/frames/banks[2].pool/token_busy [0]` |
| 59 | `CLMA_243_480:CR1` | `core/isp_writer/writer/stored [0]` |
| 59 | `CLMA_261_642:Y3` | `core/processor/refill/write_beat_4` |
| 55 | `CLMA_315_438:Q2` | `core_reset_n` |
| 54 | `CLMA_249_505:CR0` | `core/isp_writer/writer/stored_1` |
| 52 | `CLMA_219_516:CR0` | `I_ips_ddr_top/u_ddrphy_top/calib_done_15` |
| 50 | `CLMA_249_661:CR1` | `core/processor/refill/quad_3` |
| 50 | `CLMA_303_385:Y2` | `core/isp/N902` |
| 49 | `CLMA_231_384:Q0` | `core/fabric/dma/owner_3` |
| 49 | `SRB_216_636:ZQSW[3]` | `core/processor/writer/writer/pack/N1629` |
| 48 | `CLMA_57_445:CR1` | `I_ips_ddr_top/u_ddrphy_top/calib_done_9` |
| 47 | `CLMA_51_138:Q0` | `core/snapshot_command_286` |
| 47 | `CLMA_177_421:Y2` | `core/fabric/dma/_N115591` |
| 47 | `CLMS_75_331:Q2` | `core/fabric/dma/owner_5` |
| 47 | `CLMA_351_366:Y0` | `core/network/arp/N954` |
| 46 | `SRB_186_618:ZQNW[3]` | `core_reset_n` |
| 45 | `CLMA_273_535:Y3` | `core/processor/geometry/projective_path.u_step/depth/N380` |
| 45 | `CLMA_165_384:Q0` | `core/snapshot_connected.snapshots/reader/chunk_valid` |
| 44 | `CLMA_249_708:CR1` | `core/processor/refill/_N124688` |

主要热点为 ISP 写入计数/控制、bank2 帧池 token_busy、refill write_beat/quad，以及 reset、DDR calib_done 和 DMA owner。ISP 写入驱动集中在 x243–249/y480–505；refill 热点在 x249–273/y642–708。这里是拥塞网络的驱动位置，不能当作冲突边的精确坐标；congestion value 不是未布通子网数量。

优先审查 ISP writer 的 stored 计数与写入控制扇出、refill 的 beat/quad 选择及局部写使能，其次为帧池 token_busy 与 DMA owner。复位和 DDR 校准网络应检查业务侧负载及分布，保持复位语义及官方 PHY 不变。当前布线继续，不修改其冻结源文件；后续候选必须通过差分、完整 1080p30 模型及真实 routed min/max 验收。

原始拥塞证据 SHA256：`55042707981cb77653805a880613fb884610173e29259e2d0d57715e99ffdbaa`。尚无合格位流。

## 第20轮更新（23:53）

未布通 43,652 / 101,351。相同驱动位置的 core_reset_n 拥塞值由第18轮55升至88，ISP N578由86降至74，bank2 token_busy维持64；refill quad_3维持50。拥塞热点在迭代间转移，不能用单个网络值代表全局收敛。保留当前运行，后续同时审查全局控制负载与局部选择逻辑。

第20轮原始证据 SHA256：`6964f48a71bb6c355c6a6912aac8cf7ac0c7b67e0691b163943ac811748a255e`。


## 第32轮核查（2026-10-19 01:42）

未布通 38,385 / 101,351（37.87%）；已布通 62,966。第30/31/32轮分别为39,130/38,839/38,385，仍在减少。上一轮CPU耗时589.922秒。01:40:25至01:42:36，原生子进程CPU由11145增至11275.25秒，约99%的单核占用；创建时间、父进程和完整构建路径均匹配，未发现原生错误。会话活跃与子网计数不变并不矛盾：日志在完整迭代边界输出统计，当前仍在计算下一轮。持续CPU活动不能保证最终收敛，但现有证据不支持挂死。

|拥塞值|驱动位置|网络|
|---:|---|---|
|83|`CLMA_243_480:Y2`|`core/isp_writer/writer/N578`|
|81|`SRB_216_636:ZQSW[3]`|`core/processor/writer/writer/pack/N1629`|
|75|`CLMA_315_438:Q2`|`core_reset_n`|
|64|`CLMA_273_535:Y3`|`core/processor/geometry/projective_path.u_step/depth/N380`|
|64|`SRB_234_444:ZQE[0]`|`core/processor/geometry/N323`|
|64|`CLMA_219_516:Q1`|`I_ips_ddr_top/u_ddrphy_top/calib_done_11`|
|63|`CLMS_105_175:Q1`|`core/fabric/frames/banks[2].pool/token_busy [0]`|
|54|`SRB_114_120:ZQS[3]`|`core/fabric/frames/banks[3].pool/N410`|
|52|`CLMS_75_343:Q1`|`core/snapshot_connected.snapshots/copy/image`|
|52|`CLMA_57_445:CR1`|`I_ips_ddr_top/u_ddrphy_top/calib_done_9`|
|52|`CLMS_207_379:CR0`|`core/reader/unpack/core/reader/chunk_bytes_9`|
|51|`CLMA_219_516:CR0`|`I_ips_ddr_top/u_ddrphy_top/calib_done_15`|
|49|`CLMA_249_469:Y1`|`core/isp_writer/writer/N1262 [1]`|
|48|`CLMA_249_505:CR0`|`core/isp_writer/writer/stored_1`|
|47|`CLMA_249_505:Q1`|`core/isp_writer/writer/stored [1]`|
|47|`CLMA_21_319:CR1`|`core/raw_writer/writer/pack/N1633`|
|47|`CLMA_249_661:Q1`|`core/processor/refill/quad_2`|
|46|`CLMA_249_661:CR1`|`core/processor/refill/quad_3`|
|45|`CLMA_165_384:Q0`|`core/snapshot_connected.snapshots/reader/chunk_valid`|
|45|`CLMA_261_642:Y3`|`core/processor/refill/write_beat_4`|

优先点：ISP writer控制（x243–249/y469–505）、矫正结果pack（驱动SRB_216_636）、几何depth/运算控制、bank2 token_busy。refill的quad/write_beat仍拥塞（值45–47），但本轮并非最高热点。复位及DDR calib_done负载跨区域，应检查业务侧分布，不能直接改变官方PHY或复位语义。上述坐标为驱动位置，并非已定位到具体阻塞开关/走线边；拥塞值不是未布通子网数。保留现有完整布线；无真实routed时序或合格位流。

原始拥塞文件SHA256：`921b90f82df70bdde06a3eba6242ce8da2ca5454083617893ba8065fbb26cbb8`。


## ISP热点综合网表追踪（2026-10-19）

综合网表 frame_pixel_writer 的 N578 驱动 64 个存储原语的 WE 端口，属于 words/masks 段缓存公共写使能；其LUT输入含 rst_n、stored索引及pack握手。下一候选应评估写入上下文局部化，保持现有LUTRAM和原周期行为，重点回归reset/abort及4KiB拆分。综合网表连接不等于最终物理扇出，尚未验证该改写能改善布线。证据：batch02/attempt01_refill_write_context_seed11/isp_writer_netlist_audit.json。当前完整布线不变。


## 第79轮更新（2026-10-19）

第76至79轮未布通数为33180、33213、33263、33265；最近三轮回升85个，单轮约17分钟CPU。当前执行会话12469仍活跃。ISP N578拥塞值111、core_reset_n为84、geometry N323为68、DMA owner_3为64、bank2 token_busy为62。热点仍支持优先筛查ISP写使能，但不能据此宣称候选已改善物理拥塞。

writer_write_context_20261019_015104_236235的31项差分及单元综合已通过；完整MAP delay_20261019_015555_413070也通过，源完整，LUT41664→41644、FF40456→40460、LUTRAM2097不变。布局、完整帧模型和真实routed时序待验证，不是合格位流。审批服务额度故障使原生身份/残留shell复查与后续需审批启动暂未执行。

第79轮拥塞SHA256：`a3653e04e83a9276f57475c45d3b72329dd8409d1a2ed7b448cf7f38ea554562`。

## 第90轮停滞审查（2026-10-19 16:13 上海时间）

最新完成第90轮，未布通33,101 / 101,351，已布通68,250；日志最后更新时间15:54:47。第90轮CPU耗时1166.828125秒（约19.45分钟），统计在迭代结束时输出，因此轮内计数不变不代表停止。原生观察记录16:10:17.620701至16:13:14.559590，子进程88252累计CPU从62939.25增至63114.84375秒：176.939秒墙钟增加175.594秒CPU，约99.2%单核占用。观察器按构建路径核对的父72284/子88252仍存在，未发现原生错误。现有证据支持“计算活跃但收敛停滞”，不能证明挂死，也不能保证最终成功。

第80至90轮未布通数：33065、33174、33115、33273、33163、33036、33135、33019、33027、33173、33101。十轮后反增36；近期每轮约19–20分钟，拆线重布在热点间转移冲突，不能用进程活跃判断有效进展，不能线性估算完成时间。

|拥塞值|驱动位置|网络/职责|
|---:|---|---|
|93|`CLMA_243_480:Y2`|`core/isp_writer/writer/N578`：段缓存words/masks公共写使能|
|77|`CLMA_315_438:Q2`|`core_reset_n`：全局复位网络|
|63|`CLMS_105_175:Q1`|`core/fabric/frames/banks[2].pool/token_busy [0]`：帧池token控制|
|63|`CLMA_219_516:Q1`|`I_ips_ddr_top/u_ddrphy_top/calib_done_11`：DDR校准状态|
|63|`CLMA_273_492:Q0`|`boot/index_30`：启动索引控制|
|56|`SRB_234_444:ZQE[0]`|`core/processor/geometry/N323`：几何处理控制|
|50|`CLMA_231_384:Q0`|`core/fabric/dma/owner_3`：DMA owner选择|

N578经当前综合网表追踪，连接64个GTP_RAM32X2DP的WE端，涉及48个words和16个masks存储原语，是已确认的逻辑热点。上述位置是网络驱动位置，拥塞值不是未布通子网数；现有CongestionNetInfo不能定位每条阻塞开关或证明所有冲突集中在这些坐标。

针对ISP writer的写入上下文寄存候选已实际筛选：差分31项通过，完整MAP通过，但布局线长1578059→2025095（+28.33%），最终布局预估WNS +0.534→+0.071ns，因此已拒绝，不投入完整布线。下一结构方向应评估段缓存存储组织和局部写使能，避免仅增加一个共享控制寄存器；仍需差分、完整1080p30模型、布局筛选后才可选用。复位和官方DDR PHY语义不得改变。

本次仅观察、保存诊断，保留当前完整布线，不重复启动。没有真实routed min/max通过或合格位流。第90轮原始拥塞快照：`fpga/build/route_campaign_20261015/batch02/attempt01_refill_write_context_seed11/CongestionNetInfo_90_observed.txt`，SHA256 `8bcd9df4543251c2f31db5754fec126dbf8c5c09cb7a3a50c087ce47f8b1efb8`。

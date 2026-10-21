# 布线拥塞分析结论与结构改动候选（2026-10-21）

数据来源：seed 13 无时限轮 STALLED（iter 49，未布通 28,831）后导出的 50 份 `CongestionNetInfo_*.txt` 与 `CongestionPlot_*.txt`。分析脚本 `fpga/scripts/analyze_route_congestion.py`（只读，未启动 PDS）。原始结果：`routing_congestion_analysis_20261021.json` / `.md`。

## 1. 拥塞总量趋势

| iter | 网线条目 | 最大值 | ≥30 条 | ≥50 条 | 拥塞总和 |
| --- | --- | --- | --- | --- | --- |
| 0 | 77,367 | 106 | 560 | 220 | 215,290 |
| 9 | 47,626 | 72 | 84 | 14 | 102,136 |
| 18 | 35,755 | 61 | 50 | 5 | 70,962 |
| 30 | 30,747 | 60 | 45 | 3 | 59,891 |
| 42 | 29,027 | 64 | 39 | 9 | 56,399 |
| 49 | 28,436 | 61 | 50 | 5 | 56,072 |

**结论：拥塞在 iter 18 后进入 ~56–60k 的平台期**，最大值 56–64 反复徘徊，≥30 的网线数在 35–50 间波动——布线器已无法通过继续迭代降低拥塞，与 28,831 未布通的停滞互为印证。剩余未布通集中在这批高拥塞网线上。

## 2. 热点模块（终结迭代按层级聚合，sum 为拥塞值总和）

| 层级前缀 | 条目 | 拥塞和 | 最大 |
| --- | --- | --- | --- |
| `core/processor/processor`（几何） | 4,411 | 7,476 | 51 |
| `core/fabric/frames`（帧池） | 2,489 | 5,572 | 47 |
| `core/fabric/dma` | 1,817 | 3,149 | 19 |
| `core/processor/memory_refill` | 852 | 2,577 | **61** |
| `I_ips_ddr_top/u_ddrphy_top/ddrphy_slice_top` | 1,047 | 2,050 | 40 |
| `core_reset_n`（复位网） | 121 | 940 | 38 |
| `core/network/snapshot_output.snapshot` | 491 | 898 | 33 |
| `core/reader/unpack` | 142 | 562 | 43 |
| `core/snapshot_connected.snapshots/reader` | 209 | 553 | 41 |
| `core/isp_writer/writer` | 271 | 523 | 23 |
| `ddrphy_calib_top` | 198 | 470 | 25 |
| `core/snapshot_connected.snapshots/pair` | 262 | 390 | 35 |
| `boot`（启动采样） | 42+22 | 429 | 25 |
| `camera_domain_reset_n`（复位网） | 28 | 169 | **39** |

几何与帧池是数量主力；`memory_refill` 与两条复位网的单网拥塞值最高。

## 3. 空间分布（终结迭代，坐标桶 60）

拥塞集中在 **x 180–300、y 420–780** 的中央偏左区域（几何/帧池/DMA 的布局区）。最热桶：(180,720) sum 1,709、(240,660) 1,683、(180,540) 1,646、(240,540) 1,642、(240,720) 1,619（max 61）。网格拥塞图（`CongestionPlot_49`，格点索引）热格集中在 x 29–45、y 62–120，与上述区域一致。

## 4. 最热网线与变化性质

| 拥塞值 | 网线 | iter0 值 | 性质 |
| --- | --- | --- | --- |
| 61 | `core/processor/memory_refill/write_beat_6` | 64 | 持续热点 |
| 54 | `core/geo_src_slot [1]` | 63 | 持续热点 |
| 51 | `…geometry/projective_path.u_step/xy/origin_y [31]` | 45 | 持续热点 |
| 50/47 | `memory_refill/write_beat_2`、`N1341_6` | 59/63 | 持续热点 |
| **48** | `I_ips_ddr_top/…/ddrphy_rst_n` | **2** | **新热点**（后期恶化） |
| 47 | `fabric/frames/banks[4].pool/N410_0` | 64 | 持续热点 |
| 43 | `reader/unpack/…local_capture[0].capture_enable` | 63 | 持续热点 |
| **41** | `snapshot…reader/unpack/N22` | **1** | **新热点** |
| **41** | `fabric/frames/banks[4].pool/N410` | **1** | **新热点** |
| **40** | `fabric/frames/banks[1].pool/rsp [2887]` | **1** | **新热点** |
| **39** | `camera_domain_reset_n` | **1** | **新热点** |

两类问题并存：① 几何/帧池/refill 的宽总线持续拥塞；② 高扇出控制网（复位、bank 响应）在布线后期成为新瓶颈。

## 5. 结构改动候选（需按设计阶段流程：仿真 → 重新 MAP → 新物理轮次）

按"预期收益 / 改动风险"排序；每项都应作为独立候选、单变量验证：

1. **复位网分区缓冲（高收益、低风险）**  
   `core_reset_n`（121 条、sum 940）与 `camera_domain_reset_n`（max 39）、`ddrphy_rst_n`（2→48）均为高扇出复位。建议在 RTL 中按模块区域插入复位缓冲/同步复制（保持同步释放语义与 CDC 约束不变），显著降低单网扇出与布线压力。注意：DDR PHY 复位属官方 IP 上下文，不改 PHY 内部，只在顶层分配处复制驱动。

2. **memory_refill 写通道局部化（高收益、中风险）**  
   `write_beat_*`/`N1341_*` 是最高单网拥塞（61/50/47）。建议在 refill 与帧池 bank 之间增加一级本地流水寄存（不改变位宽/时序语义，仅增加 1 拍延迟并需同步更新同帧时序预算与仿真断言），或按 bank 复制写选通。

3. **帧池 bank 响应/宽总线按 bank 本地化（中收益、中风险）**  
   `banks[*].pool/N410*`、`rsp[2887]` 后期恶化。建议把跨 bank 的共享控制（响应选择、耗尽标志）改为 bank-local 寄存后再汇总，减少跨区走线；必须保留 64 位代次/耗尽语义（设计阶段已确认该语义不可削弱）。

4. **geometry ↔ geo_src_slot 接口再定时（中收益、中风险）**  
   `geo_src_slot` 总线与 `origin_y` 持稳高拥塞。设计阶段已把逐行 CDC 收敛到 tile 边界；可进一步在 slot 读取侧增加 tile-local 捕获（与 unpack 的 local_capture 同型），但需重新跑全帧仿真与快照一致性。

5. **snapshot reader 捕获信号复制（中收益、低风险）**  
   `snapshot_connected.snapshots/reader/unpack/N22`、`capture_enable` 类高扇出使能可做局部复制（保持同帧锁存语义），与第 1 项同属"控制网扇出治理"。

**不建议**：继续用同一 seed 延长布线、放宽约束、全域 false-path 或跳过 hold——均不能解决 28.8k 未布通的物理现实，且违反项目约束。

## 6. 下一步建议

1. 先对候选 1（复位网分区缓冲）做 RTL 候选：它改动小、语义清晰、可直接量化拥塞收益；
2. 在独立工作区修改并跑设计阶段仿真（全帧 + 快照一致性 + 恢复场景）；
3. 通过后重新 SYN/MAP（不复用旧 DB），再以 seed 13、90 分钟预算做单变量物理轮次；
4. 以本轮 `resume_20261020_212308_289391` 数据为对照基线（未布通 28,831、拥塞平台 ~56k）。

任何候选在通过仿真与 MAP 前，不得声称将布通或时序通过；位流目标仍未达成。

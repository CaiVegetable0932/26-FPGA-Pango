# DDR / DMA 接入契约

## 2026-10-15 完整视频候选的块 RAM 修复

完整视频候选 `delay_20261015_111425_510321` 将七路 DMA 的 256-bit payload 缓冲迁入同步读 DRM，容量及独立预留不变。预取下拍读游标保持 native W 和内部写回读验证逐拍吞吐；客户端每个读突发在全部返回后额外等待一个读端口稳定周期，随后仍可每拍消费一个 beat。该周期用于避开混合端口同地址读写差异，未使用 `no_rw_check`，也不减弱取消、故障或所有权检查。

原版/候选 18 组随机深度回归、六项集成恢复回归、1080p/control/snapshot 模型及冻结上位机解码通过。模型最后一帧为 4,072,757 个 125MHz 周期（32.582056ms）；这不是实板最坏吞吐证明。整板 MAP 已通过，正在布线，尚无新的时序签核或位流。详见 `fpga/reports/route_efficiency_diagnosis_20261015.md`。以下带日期内容保留其历史验证范围。

2026-10-12。04专项实现及验证见 [报告](../../reports/ddr_dma_optimization_20261012.md)。
正式帧管理契约仍以本目录 [README](README.md) 为准；本文补充原生搬运边界，不改变76 MiB布局或外部协议。
新 DMA部件尚未接入完整 RAW/ISP/几何/HDMI/网络正式顶层。诊断Top已接原生桥接，仍是720p RGB565诊断范围。

## 2026-10-13 共享集成增量

`frame_memory_fabric.sv` 已连接五个帧池与七客户端 DMA，统一 issue/token/ticket/complete；`geometry_tile_refill.sv` 已接通几何 32×8 tile 请求与 DMA 读口。两者属于同钟连接层，尚未接入板级顶层和正式 CDC。验证入口为 `fpga/scripts/sim_full_integration.py`。

`ddr_native_dma` 新增参数 `VERIFY_WRITES`，默认 0，以下旧版 transport-only 说明继续适用于默认模式。参数设为 1 时，每笔写在完整预留的数据银行保留原值，完成原生 W 传输后，对**全部 beat 的所有有效 strobe 字节**逐项读回比较；内部读回不输出客户端 `r_valid`。只有全部匹配且 ID/LAST 合法才设置 `write_verified` 并返回正常 done。每笔写因此额外读取等量总线字节，统计包含读回开销；没有宣称满足混合 1080p30 带宽。

`frame_memory_fabric` 强制启用该模式，在正常写 `write_verified` 或未发出的取消事务安全排空前保留帧池 token，阻止 seal 后提前发布。读回不匹配或原生协议故障锁住 fabric，保留未退休槽至控制器与所有客户端共同 cold reset，不自动重试、不伪造取消完成。这证明的是每个被写字节在实际返回时被观察到，最终控制器/板端压力验证仍须执行；不依赖未证实的跨读写顺序，也不采用仅比较帧尾的旧方案。

共享连接层输入 `frame_command` 只接调度器的 alloc/seal/cancel/acquire/release/skip；issue/complete 必须为零。DMA 请求附 bank/slot/generation/owner，先取得 token 再提交原生 DMA，拒绝跨槽地址、错误读写 owner、无效尺寸及旧 generation。相同 bank 的准入和退休分别 round-robin；done 保持到客户端 ACK。所有端口在 DDR 用户域，不能直接接异步视频域。

回填桥一次缓存两个 96 B 行，分割 4 KiB 边界，等待真实 done ACK 后输出四个奇偶 RGB888 样本；尾列/尾行越界样本为零，DDR padding 不作为图像内容。取消不能撤回已举起的请求，要等 DMA 排空后返回 error/last。完整几何核经此桥和原生 DMA 模型的三帧 35×33 联合测试已通过，不代表全尺寸或实板验收。

## 1. 安装版原生接口

依据 PDS 2022.2-SP6.4 build146967、生成 IDF中的 Logos2 HMIC_S 1.10、PG2L100H/FBG676/-6、32-bit物理DQ/256-bit用户口、10-bit column。
手册：`E:/PDS_Pangu/PDS_2022.2-SP6.4/ip/system_ip/ips2l_hmic_s/ips2l_hmic_eval/ips2l_hmic_s/UG042003_Logos2_HMIC_S_IP.pdf` pp.31–38、58。
安装版doc目录与板卡reference均只读，本轮没有修改或输出到原目录。

- 上游地址统一为DDR相对**字节地址**。原生 Row/Bank/Column映射的x32 word地址=`byte_addr >> 2`；一个32 B beat原生地址递增8。不能直接传字节地址或UI beat地址。
- LEN=beats−1，4 bit，单请求1–16 beat；不跨1024列地址边界，即本配置4096 B。控制器有列地址回绕，不能当作自动跨行递增。
- 原生没有WVALID，WREADY有效即取数据/strobe；发AW前写数据必须备齐。写ID/LAST为控制器输出，必须核对。
- 原生没有RREADY/RRESP，发AR前预留全部返回存储。本实现仅支持有序、ID=0、有有限间隙的返回；没有原生取消。
- 原生没有B通道。写数据被取走不是写提交/读可见性证明，不能用常量BVALID建立栅栏。
- 默认CAPACITY_BYTES=1 GiB依据MINI硬件手册V1.3 p.15的两颗4 Gbit/x16**参考配置**，不是实物签核；接入时设为实际确认容量。描述符区另分配，76 MiB主布局不改。

## 2. `ddr_native_dma`

全部端口同一DDR用户时钟域。默认7客户端，每客户端1个描述符、16 beat独立RAM bank（512 B数据及64 B掩码）。跨域由各消费者自己的原生FIFO/事务握手实现。
第i客户端切片为`i*width +: width`，低字节对应低地址。
当前映射：0 RAW写、1 S1写、2几何源/内部历史读、3结果写、4 HDMI读、5 RAW网络读。全部六客户端遵守相同准入和排空规则，已删除末客户端特殊门控。非法旧bank3/4仍在地址校验拒绝。

| 事件 | 契约 |
| --- | --- |
| req_valid && req_ready | accepted；锁住write/addr/beats/tag。地址32 B对齐，1–MAX_BEATS，整段不越容量/列边界 |
| w_valid && w_ready | 按顺序装一beat及32-bit高有效strobe；全部装入后才参加原生调度 |
| r_valid && r_ready | 从已预留返回缓存交数据；r_last为该请求最后beat；消费者ready不连接不存在的原生RREADY |
| done && done_ready | 终结回应ACK后释放本条目；done/tag/error/cancelled在ACK前保持；不能提前复用 |
| 正常写done | 最后原生数据beat已接受，ID/LAST检查通过：data_complete和UI transport drain，**不是全帧可见性栅栏** |
| 正常读done | 原生所有返回已接收，消费者所有缓存数据已消费；读transport/消费者排空 |
| cancel[i] | 对已accepted、未done条目取消，一拍或维持有效均可；不支持同拍接收新条目并取消旧条目 |
| 排队取消 | 不发原生请求，不要求补齐剩余写数据，返回cancelled |
| 地址VALID后取消 | 不撤回VALID，接受后写完预缓存数据/接收并丢弃全部读响应，再返回cancelled；已写入的数据不能撤回 |
| 本地error且fault=0 | 零/非法长度、对齐/越界或快照BUSY；未发原生请求，可ACK并重试 |
| fault=1 | ID/LAST异常或带在途丢失初始化；停止新准入/调度。error终结不能证明槽可回收，须与控制器共同复位、作废旧代次 |

一次最多1条原生事务，其他客户端仍可预装数据或消费缓存。慢读消费者只占自己的条目。
正常轮询+最多2次连续紧急grant；紧急grant不能推进正常指针。连续eligible客户端最多在`CLIENTS*(EMERGENCY_QUOTA+1)`次选择内获服务，默认18。
这是grant次数界；秒/周期上界仍需控制器最坏服务、刷新、源到齐与消费上界。本轮随机有限等待模型不能证明实板最坏期限。

max_wait_cycles记录accepted到首次调度的最大等待（含写装填，不含读消费），峰值饱和；bus_bytes逐原生beat累加32；useful_write_bytes累加实际strobe popcount。
读有效像素字节由去填充/回填层另计。32-bit累计字节会回绕，正式测评按间隔取样或扩展；尚无整机deadline/FIFO峰值/完整帧率计数器。

### 帧池与复位

tag为内部不透明关联字段，TAG_BITS默认32，集成时保存完整bank/slot/generation/owner/token/ticket或映射到同代条目，不修改外部epoch/frame_id。
帧池issue必须先于允许DDR访问。新帧池**不得用写done直接产生complete/READY**：03需要允许消费者观察数据的可见性栅栏，当前手册未提供充分的跨读写ordering/提交依据；正式集成须补控制器依据及板端验证。
读done可以退休本客户端读token，但仍需其他引用/代次检查。取消的写作废该帧，不能回滚其数据。
rst_n本域同步释放，与控制器共同清除旧响应；不能只复位本模块/FIFO一侧。fault后先禁止访问，排空或共同硬复位，再回收槽。
诊断帧池仍沿用data_finish发布，不能据此声称正式全帧可见性、无撕裂或来源验证通过。

## 3. 行与字节部件

- dma_row_plan：base/row_bytes/stride/slot边界均为字节；仅规划有效行覆盖的对齐bus span，split至MAX_BEATS及4 KiB。done仅为**所有请求描述符已发出**。检查64-bit末行跨度、对齐槽边界及容量，零/非法/越界拒绝。
- dma_pixel_pack：每行段锁定首beat偏移与RAW/RGB模式，每像素1/3 B，35 B余量保留跨beat像素；pixel_last flush，strobe不写padding/邻tile。低字节先发；正式R/G/B内存次序要求R置pixel[7:0]、G[15:8]、B[23:16]，上游`{R,G,B}`需在glue交换首尾字节。ready/valid源不等于可直接背压DVP。
- dma_byte_unpack：行首offset和有效row_bytes；64 B余量支持同时收发，输出最多32 B紧凑chunk及valid_bytes/last。行尾无效字节不输出。网络层必须拼接各行chunk后分包，不能把行尾chunk的无效字节发送。
- pixel_last、行长度、所有beat与burst分配须由客户端glue绑定；这些部件不是自动集成的整帧DMA顶层。RGB tile共享beat时分别用strobe，禁止无互斥读改写。

512 B/client是**事务预留**，不是不可暂停输入FIFO容量。输入/显示CDC缓存仍需满足`峰值字节率*实证最大无服务时间 + 突发/CDC余量`，不能用186.624 MB/s平均RGB流量替代行有效区峰值。
模型16-beat最大调度等待394拍=3.152us，但它不含控制器未知最坏刷新/消费行为，不能据此签核FIFO大小。

## 4. 诊断/标准AXI/RAW客户端

mini_ddr_native_bridge在Top/u_native_dma接入：16→256/256→16原生FIFO、1拍读延迟、整段预取、正确物理地址与原生ID/LAST。诊断两读写通道分别有序在途，不支持原生取消。异常fault阻止新请求。
frame_fifo_read/write尾段采用实际剩余宽字；mem_read/write_arbi不再用8000拍定时器丢掉活事务所有权。四个2 MiB诊断槽不替代76 MiB正式布局。

aq_axi_master_256保留为**标准AXI**部件，诊断Tcl/.pds不引用。WR/RD独立字节计数、16-beat/page切分、同步FIFO预取、尾strobe、B/R握手及错误输出已修复。
WR_START/RD_START只在对应READY时发一拍。MASTER_RST在当前突发排空后取消，取消读即使FIFO_FULL也排空且不写FIFO；ARESETN必须与从设备共同复位。不要再接到缺WVALID/RREADY/B的原生口。

RAW reader复用字节地址/32 B beat接口。连接回归修复其cancel保持为高时吞掉done/ACK的问题：READ/DRAIN取消分支也必须处理完成，避免已经ACK后永久等待。
HDMI line prefetch端口的req/tag/r/done/ACK与本契约匹配，但其时钟域仍需无损事务CDC。cache fill为tile/4-pixel接口，仍需回填glue、边缘裁剪及实际bus bytes统计。

## 5. 复现

```powershell
./fpga/scripts/sim_ddr_dma.ps1
./fpga/scripts/benchmark_ddr_dma.ps1
./fpga/scripts/build_ddr_units.ps1
./fpga/scripts/build_ddr_dma.ps1
```

所有日志/副本/报告落fpga/build/ddr_dma，实际报告落fpga/reports；不运行JTAG，不生成/发布位流，不解除现有温度和下载放行条件。

## 2026-10-13 集成补充

`frame_memory_fabric` 已把 5 个帧池与 7 客户端原生适配器连接；issue 先于 DDR 提交，complete 由真实 drain/读回验证退休。正式帧写启用 `VERIFY_WRITES=1`，比较每个 beat 的每个有效 strobe 字节；读回失败隔离至控制器与全部 CDC 域共同冷复位。全部写读回增加实际总线流量，尚未证明整机实板带宽。

取消写作废部分帧；取消读只退休该消费者的事务，不作废存储帧或独立快照引用。读错误仍使该帧失效。`frame_pixel_writer` 支持光栅/图块坐标写入，`frame_writer_buffer` 以有界像素 RAM 重叠计算和写校验。`geometry_tile_refill` 排空每个真实读事务后发四邻域；`dma_read_cdc` 保留整突发响应和不可变描述符/状态直到双向 ACK。板级 CDC 约束和 min/max STA 尚在执行，不能以功能仿真替代。

### 总体队列与退休更新（2026-10-13）

帧池内部 ticket 已扩展为64位并在终值隔离，不影响UART/PRAW外层格式。fabric 本地接受地址/长度/slot/gen/owner后先进入 ADMIT，随后取得帧 token 才向 native DMA 提交；accept不是写可见性完成。退休选择和64位 ticket payload 分开注册，native done一直保持到帧池 complete ACK。live cancel 在 token 接受同拍必须先保留该 token，随后通过 native取消/排空；不能以本地回应遗失已接受的 token。

通用帧池保留8 token默认。板级SRC/DST按3、RAW按2容量限制；所有代次、读回和所有权检查保留。内部HISTORY复用几何源读客户端2且独立持有SRC引用，网络仅导出RAW。

银行 admission 的 client/slot/generation/owner 先独立寄存，再检查代次与所有权；该描述符保持至明确接受/拒绝，客户端不能重复取得 token。故障/ready 在最终响应和全部银行寄存器更新处门控，避免串过 release→issue→reject 组合链；native DMA 仍立即停止新提交。

板级 RAW 与 RGB 快照的 slot base、2048/6144 stride 都为32字节对齐，`raw_dma_reader.ALIGNED_ROWS=1` 校验这些前提后使用单拍弹性 chunk，保留行尾 valid_bytes 和零 padding。通用默认模式仍支持首拍 offset 和64字节拼接；并未放宽任意调用者的地址约束。图块补充先捕获描述符，再分别计算跨度、验证范围，合法后才发 DMA；每行地址由 stride 递推，底边虚拟零行不发请求。

### 有效数据与错误清理更新（2026-10-14）

银行接受结果的 client/token/ticket/rejected 先寄存后送客户端；有待消费结果的客户端不重新参加准入。退休银行 commit 后撤销 COMPLETE，下一拍的寄存确认才 ACK 持有的 native done，避免重复退休。native DMA 每个客户端本地计算 eligible，轮询只旋转一位可选向量，紧急配额与取消顺序不变。

帧池 busy/sealed/legal/pending/refs、generation、token_busy、ticket、next_order 仍明确复位并保护饱和隔离。宽 metadata/order 只在完整 allocation commit 后有效；token slot/generation/owner 只在完整 ISSUE commit 后有效，数据寄存器无需复位。所有有语义的读取先检查有效所有权，空闲 acquire payload仍为零；metadata 的 immutable 字段仅分配时写，capture_last在seal时写，errors保留seal/cancel/complete-error累加优先级。共同冷复位仍须清除控制器、适配器和全部CDC旧工作，不能用本地有效位清除来假定DDR已经排空。

快照 EXPORT 已经过 seal 与生产写排空。仍occupied但ready_frames为零表示目标失效，需要取消未导出的另一幅图；正常第一幅导出释放后 occupied=0、ready=0，不使第二幅失效。错误清理保留已接受NETWORK引用，导出服务继续排空ACTIVE读并显式release；尚未获取的被取消银行不再ACQUIRE，尚未启动读的WAIT直接release。完整快照描述符与旧几何记录仍保留供PC查询。

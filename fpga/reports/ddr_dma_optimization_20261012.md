# DDR 与 DMA 优化实现/验证报告

2026-10-12，专项04，性能 > 时序 > 资源。范围：原生事务适配、缓存/仲裁、行段与字节部件、诊断接入及 RAW 客户端连接回归。

结论：代码及离线回归已落地；诊断工程已做安装版 PDS 编译/综合/映射/PnR/时序报告。**不是正式1080p30双流、实物DDR带宽/容量、全帧写可见性或下载放行报告。**

## 1. 改动与正确性

| 部件 | 实际改动 |
| --- | --- |
| mini_ddr_native_bridge / 诊断Top | 替换 generic AXI/常量BVALID仿真适配；整段同步FIFO预取；32 B beat地址转原生x32 word地址；核对控制器写ID/LAST与读ID/LAST |
| frame_fifo_read/write | 以实际剩余宽字数构造尾突发、推进地址/计数和预留读FIFO容量，防止短帧尾段越界 |
| mem_read/write_arbi | 去掉8000拍后丢弃事务所有权的行为；必须等真实完成，9000拍停顿定向回归通过 |
| ddr_native_dma | 七个独立单条目队列/RAM bank；写数据备齐、读存储预留；单原生事务、有序ID=0；cancel保持地址VALID并排空；done/tag/error/cancelled保持到ACK |
| 仲裁 | 正常轮询+最多2次紧急grant；紧急grant不推进普通指针，修复可能永久跳过普通客户端的问题；连续eligible选择上界21 grant |
| dma_row_plan / dma_pixel_pack / dma_byte_unpack | 有效行段/stride/列边界切分；RAW8/RGB888跨32 B beat残留；首尾strobe；未对齐48 B tile行；读出只给有效字节 |
| aq_axi_master_256 | 保留为标准AXI部件；WR/RD独立计数、同步FIFO、16-beat/4 KiB切分、尾mask、真实B/R握手、错误及取消排空；取消读不再被FULL挡住 |
| RAW reader | 与真实适配器连接后修复cancel保持为高/与done同拍时吞掉done/ACK、永久停在DRAIN的问题；不改变PRAW外部格式 |
| 工程 | 诊断Tcl及原生生成.pds同步引用mini_ddr_native_bridge，保留I_ips_ddr_top及原生DDR/板级约束；旧.pds与约束报告已归档 |

正式契约见 [DDR_DMA_CONTRACT](../rtl/memory/DDR_DMA_CONTRACT.md)。03帧管理说明保留在memory/README，本轮不覆盖该文档。
RGB内存为R/G/B字节顺序；pack部件低字节先发，客户端glue必须规范化pixel向量顺序。没有降为RGB565、缩减76 MiB布局或改外部网络/姿态协议。

## 2. 原生依据与完成边界

- PDS 2022.2-SP6.4 build146967；生成控制器IDF为Logos2 HMIC_S 1.10，PG2L100H/FBG676/-6、32-bit DQ、256-bit UI、10-bit column、参考125 MHz UI/1000 MT/s配置。配置不证明实物支持。
- UG042003 pp.31–38：原生没有WVALID、RREADY、RRESP或B通道；写ID/LAST为控制器输出；LEN=beats−1。p.58 burst原生地址逐beat增8，column边界回绕。
- 本配置统一在适配层转换`byte_addr >> 2`；诊断输入为32 B beat地址，转换`beat_addr << 3`。旧Top直接把byte地址送入原生口导致地址跨度与声明不一致；不能用旧诊断显示工作推定单位正确。
- 仅支持1–16 beat、32 B对齐bus请求，不跨4096 B列边界；行部件生成未对齐首尾掩码。全部请求先查范围，非法请求不发原生地址。
- 写done仅证明数据传输完毕、UI无剩余beat，**不证明允许后续消费者观察整帧**。新帧池不得直接用写done产生03 complete/READY。现有原生手册没有提供足够的全帧提交/跨读写ordering依据；需另证可见性栅栏及实板读写。
- 读done等待全部返回及消费者消费；cancel的已发写仍会改变内存，必须作废该帧。fault后error响应不授权槽回收，需共同复位/作废代次。
- 32-bit统计累计可回绕；发布测评前扩展/定期采样。默认1 GiB容量来自MINI硬件手册V1.3 p.15参考配置，实物未签核。

查阅的只读资料：安装doc中的PDS User Guide工程导出说明、IP Compiler导航/生成说明、Timing Analyzer §4.1、UCE create_clock/get_ports/get_pins说明；安装IP目录UG042003；MINI硬件手册p.15；生成DDR IDF/FDC/RCF及MINI相应原生示例。原始目录、参考资料和生成IP HDL未改写。

## 3. 实际功能验证

主回归： [results.json](../build/ddr_dma/20261012_155913_978/results.json)，Icarus Verilog 12.0，seed=42/1907/20261012，**7组×3种子=21次运行全部通过**，记录源码SHA-256；报告整理时全部源码与记录一致。

| 回归 | 覆盖及本种子计数 |
| --- | --- |
| tb_ddr_native_dma | 396条测试操作；长短突发、随机AW/AR/W/R间隙、mask、慢消费者、排队/地址后/缓冲后取消、ACK保持、非法长度/地址/容量、快照BUSY、七客户端竞争、混合读写、ID故障和联合重置 |
| tb_dma_bytes | 268案例；全部32种首offset、RAW/RGB及跨beat像素、尾mask、行stride、列边界、slot末端、零/非法/越界；1080行RAW/RGB规划 |
| tb_mini_ddr_native_bridge | 17案例；1–16 beat、实际1拍同步FIFO延迟、写预取、地址单位、读返回、错误写LAST不发布完成 |
| tb_frame_dma_tail | 19宽字分成16+3，地址/计数/完成均按真实尾段 |
| tb_axi_master_dma | 8案例；WR/RD长度刻意不同、1/33/1025字节尾段、4 KiB切分、B等待/错误、R背压、零长度、写取消及读FULL状态下取消排空 |
| tb_dma_arbiter_drain | 9000拍服务停顿后仍维持原事务所有权/data路由 |
| tb_raw_ddr_adapter | 实际RAW reader→本适配器→原生模型；3行×37 B=111有效字节、非对齐起点跨4 KiB、stride=64、取消保持为高并排空 |

另外 [最终基准](../build/ddr_dma/benchmark_20261012_160148_979/benchmark.json) 重跑旧mini_frame_pool：144个ownership检查通过；同时重复9000拍仲裁排空。
DDR scoreboard依据**客户端accepted地址/数据**构造期望字节内存，再核对每个原生地址、beat、mask和消费者返回；没有用原生错误地址反过来构造黄金地址。

已验证的行规划总线量：RAW1920/stride2048/1080行=2,073,600 B；RGB5760/stride6144/1080行=6,220,800 B，均未主动搬padding。未对齐48 B tile行测试16行共1536 B总线/768 B有效数据，说明未对齐回填不能全算有效像素。
这些是行规划/事务/字节回归，**不是完整板端1080p帧采集和发送测量**。

## 4. 同字节量混合模型基准

每轮3写客户端+显示/cache/RAW网络/快照4读客户端，共88,320 B有效且总线字节相同；125 MHz模型；4/8/16-beat合法上限；每配置3种子。
模型含有限随机地址/数据间隙、每97拍中12拍地址暂停、有限随机消费者等待。它**不是真实刷新/CAS/开行/读写切换模型**，未标定真实控制器，因此MB/s只用于本RTL候选比较，不用于实板带宽预测。

| 配置 | 平均混合周期 | 模型有效MB/s（三种子平均） | observed最大accepted→调度等待 |
| --- | ---: | ---: | ---: |
| 4 beat | 6110.67 | 1806.69 | 138拍 / 1.104us |
| 8 beat | 5035.00 | 2192.84 | 225拍 / 1.800us |
| 16 beat（默认） | 4288.33 | 2574.84 | 394拍 / 3.152us |

16-beat相对4-beat，模型同字节量平均用时下降29.82%；它同时增大普通客户端最大等待。按性能优先保留默认16，客户端行规划仍可发4/8/短突发；实际deadline及峰值输入缓存需联合验收后选各通道长度，不能据模型等待认定输入/显示期限达标。
持续eligible调度grant界21不是实际秒界。缺整机最大无服务时间、队列峰值、deadline miss/过载、RAW完整帧率和几何真实回填轨迹的实测。

## 5. 资源与时序

安装版PDS独立综合：最终core/pack/planner来自 [units结果](../build/ddr_dma/units_20261012_155126_045/results.json)；unpack收窄计数后来自 [最终unpack结果](../build/ddr_dma/units_20261012_155726_939/results.json)。四个源副本均与当前RTL SHA-256一致。

| 部件 | LUT总计 | 其中LUT RAM primitive | FF | DRM36K | APM | 验证层级 |
| --- | ---: | ---: | ---: | ---: | ---: | --- |
| 初版flat共享多写口DDR缓存（已弃用） | 77566 | 0 | 33765 | 0 | 0 | 独立综合；超过器件LUT容量，不可交付 |
| 最终ddr_native_dma独立bank | 4614 | 1008 | 1452 | 0 | 0 | 独立综合，无正式集成PnR |
| dma_pixel_pack | 910 | 0 | 315 | 0 | 0 | 独立综合 |
| dma_byte_unpack | 4450 | 0 | 558 | 0 | 0 | 最终独立综合；计数收窄前4990 LUT |
| dma_row_plan | 700 | 0 | 175 | 0 | 5 | 独立综合；描述符末行跨度乘法映射APM |

core同样7×16 beat容量/并发行为，独立bank和有界索引移除共享多写口crossbar；最终混合模型周期与flat版本一致。RAM数据不复位，以合法描述符/水位控制有效性。
独立模块的数千抽象UI端口不是物理板级IO；综合报告的IO超量不代表已通过板级映射。正式模块尚无同一真实顶层的PnR/资源总量，不能把独立相加当整机报告。

诊断工程完整隔离构建： [阶段记录](../build/ddr_dma/pds_20261012_153152_912/stages.json)，[Top.rtr](../build/ddr_dma/pds_20261012_153152_912/workspace/fpga/build/mini_camera_diag/implementation/report_timing/Top.rtr)。编译/综合/映射/PnR/report_timing原生退出及报告均完成，使用slow/fast multi-corner总结，未提高DDR频率或放宽约束。

| 诊断当前配置 | 数值/状态 |
| --- | --- |
| Device map | LUT6213、FF6088、Distributed RAM168、DRM8、APM0（整个诊断Top） |
| DDR125 MHz self setup slow WNS | +2.198 ns，TNS=0 |
| DDR self hold fast WHS | +0.102 ns，THS=0 |
| 最小已报告setup跨域余量 | sys_clk→pixel_clk +0.673 ns |
| 原生Design Summary | All Constraints Met（仅已施加约束） |

仍有DVP、SCCB、DDR外部端口等Timing-4086未约束警告；原生DDR专用时序/位置及已有Gray/reset约束保留，实例I_ips_ddr_top不变，没有新增false path。当前继承例外和外部延时仍须01专项签核；上述“Constraints Met”不证明全接口物理时序收敛。
没有可同口径复现的旧诊断源码/PnR基线，因此不编造诊断时序/资源改善百分比。

广泛输入快照审计因其他分区并行修改而报变化；[实际依赖审计](../build/ddr_dma/pds_20261012_153152_912/dependency_audit.json)确认**诊断Tcl及真正设计/IP/约束闭包未变**。本轮只认该闭包，不声称当前所有FPGA源码均经这次PnR。

## 6. 交付、复现与共享差异

- 入口：sim_ddr_dma.ps1、benchmark_ddr_dma.ps1、build_ddr_units.ps1、build_ddr_dma.ps1。Windows受限环境中仿真器DLL/异常退出时，本轮在获准的正常本机离线环境运行并严格核对退出码，不忽略失败。
- 诊断工程原生更新证据：[project_update结果](../build/ddr_dma/project_update_20261012_160103_639/result.json)，同目录previous.pds/previous_constraint_check.ccr保留原版本；主GUI旧构建产物未覆盖。
- 共享Top/Tcl/.pds改为u_native_dma桥接；所有原生DDR信号、物理引脚、IP配置及层级约束保留。另同步了RAW reader的取消排空处理；其他分区源码及其README未回退。
- 正式frame_manager：issue先记token/ticket，保存完整身份映射；写complete需可见性栅栏而非本层done；读/取消等排空后退休。生产者seal/输入合法性/消费者引用仍归03。
- 显示：line-prefetch端口可对接本层，但要补真实跨时钟桥与deadline联合回归。cache：仍需tile refill glue、边缘裁剪和真实bus字节统计。RAW：已做真实reader连接局部回归，未做完整UDP/RGMII/板端帧率。
- 不可暂停输入和显示FIFO按实证峰值与最大无服务时间配置。512 B/client为原生事务预留，不是可暂停DVP的理由；不能用平均RGB率或随机模型最大等待替代实板界。

## 7. 未通过范围

1. 实物板版本、DDR颗粒/容量/速率签核；已知pattern和长期混合负载读写。
2. 原生全帧写提交/可见性栅栏，正式03/04/05/06/07集成后代次/发布/取消/释放联合证明。
3. RAW/ISP/结果完整1080p30、整机有效带宽870.912/1430.784 MB/s工况、最坏期限、快照预算及FIFO容量。
4. 正式多客户端DMA全顶层PnR、外部IO延时、CDC/复位/例外命中签核和整机资源预算。
5. 功耗、温度、来源证据及完整RAW网络帧率；HDMI来源仍null/unverified。

本轮未访问硬件、未生成/下载新位流、未解除over_temp/下载放行条件，未提交/推送工作区中其他分区的并行修改。

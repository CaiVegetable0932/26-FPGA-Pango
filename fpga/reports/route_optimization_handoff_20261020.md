# FPGA 布线优化交接

更新时间：2026-10-20 03:58，北京时间。项目尚未全部设计完成。

## 项目地址和授权

- 本地：`D:\XDU\concept\26-FPGA-Pango`
- 分支：`codex/fpga-pds-project`
- 云端：<https://github.com/CaiVegetable0932/26-FPGA-Pango>
- 原方案：`output/FPGA布线效率与拥塞专项优化方案.md`
- 连续进度：`fpga/reports/route_optimization_progress_20261019.md`
- 会话：`fpga/build/route_optimization/session_20261019`

用户允许分区域验证，要求先完成设计文件/仿真；整个方案未完成前禁止整体布线和完整位流。整体任务已于10月19日21:46停止，没有恢复；`stop_requested.json`保留。`fpga/config/implementation_readiness.json`整机门槛均关闭，不得为运行而设true。设计仿真通过后通知用户，由用户安排其他智能体监控整机布线。本轮没有子智能体或硬件下载。


## 2026-10-20 03:58 写入器单文件合入

主设计从12项增加到13项：只合入 `fpga/rtl/memory/frame_pixel_writer.sv`，哈希 `dd089551cc79309e5175536c53f8efed36bfad7dba9438104365c6a1b5425f41`。完整signed乘积与两拍入口流水共同组成此候选；完整64位范围检查、像素精度、字节掩码、取消/排空均保留。每帧入口增加2拍，分段增加0拍。主设计实际时钟仍125MHz，整体布线/位流全部门槛未放行，整个方案尚未完成。

- 功能：50组独立语义/字节/范围/取消/延迟检查、20项回归全部通过。
- 三个区域seed11/7/13全部布通且内部多角STA通过，PnR分别50/63/58秒；没有时序合格的原始参考，不计算加速比。报告 `session_20261019/writer_three_seed_0358.json`。
- 完整1080p控制/快照/实际显示 `verilator_20261020_033308_185785` PASS，22809600显示像素失败0/下溢0，3新帧8重复帧；几何周期4073517/3796435/4114261与旧主设计相同。
- 主机报告 `host/reports/fpga_rgb_vectors_20261020_035641_996920.json` PASS，8888报文、12441600图像字节。datagrams/descriptor均与旧主设计逐字节相同，比较文件在模型目录 `snapshot_baseline_comparison.json`。
- 合入前逐项核对290项当前输入、候选、回归、模型、主机伴随源码和区域输入；只原子替换writer，保留 `session_20261019/writer_pipeline_promotion_20261020/before_frame_pixel_writer.sv` 及 `promotion.json`。新主输入清单 `session_20261019/writer_pipeline_finalist/sources.json`，其源码实体仍位于writer候选的冻结 `source/`。

150MHz实验第一组合的首个几何作业4470577个DDR周期，比125MHz基线更慢，不能采用；完整模型仍在收集后续场景。第二组合只把实验读CDC改为连续预取，生产显示读桥不变。八组读桥测试、三组真实几何字节检查及整机控制/快照小模型通过；精确150MHz完整帧模型 `verilator_20261020_035853_729207` 正在运行，未合入。

第二组合闭包 `proc150_video_model_20261020_035612_841416`，模型将TB时间精度提高到1fs，避免旧3.333ns半周期实际约150.015MHz造成期限口径误差。旧模型保留其真实周期与结果，不追溯重标。原型原生affine SYN LUT8846/FF7055/APM85/物理DRM43，读/写CDC各DRM4、邮箱19FF；不是projective配置或整机预算，尚无该域物理/CDC签核。

帧池8位计数分块11组差分及20回归通过，SYN LUT4190→4434、FF831→830、控制集25→21；区域A/B正在运行。其输入仍基于旧12项，后续若合入必须重新组成13项主设计并做完整验证，不能混用当前writer模型冒充组合通过。

## 主设计旧12项基线与完整证明

下述为03:58之前的12项基线：writer BRAM等11项加unpack局部捕获；主设计合入点`20f5269f`，03:58已按上述证明再合入writer，主设计现为13项。DMA分组、boot捕获及后续所有候选未合入。当前主设计实际处理/DDR时钟125MHz，150MHz尚未实现，6份约束与186项DDR IP输入未改。

- 冻结290输入：`session_20261019/unpack_finalist/sources.json`；工作树/HEAD逐项绑定核对无不同或缺失，见`head_source_coherence_20261020.json`。
- 20项回归：`fpga/build/full_integration_20261013/sim_20261020_001153_047628`，PASS。
- 完整1080p控制/快照/实际显示：同build根下`verilator_20261020_001232_095496`，PASS；22809600像素，失败0/下溢0，3新帧8重复帧；几何周期4073517/3796435/4114261。
- 主机解码：`host/reports/fpga_rgb_vectors_20261020_003432_815058.json`，8888报文、12441600图像字节，PASS。
- unpack区域seed11/7/13两侧均时序通过，PnR44/45/44→36/38/39秒，中位改善13.64%，未达30%建议目标；不能推断整机收益。
- 第四轮DMA统计局部化：功能/全帧/主机字节通过，但seed7 STALLED、最优剩余1487，不合入、不跑seed13。终结记录在`dma_stats_only_20261020_013741_777089/terminal_review_20261020.json`。
- Icarus旧全帧`sim_20261019_214646_986066` TIMEOUT保留，不能改为PASS。旧11项MAP LUT41341/FF40430/APM117/DRM98不是当前12项或后续组合实测资源。

以下实验路径均相对于`fpga/build/route_optimization/`，仿真路径相对于`fpga/build/full_integration_20261013/`。

## 2026-10-20 03:48 小时进度

本小时主设计仍是通过完整功能验证的12项选择，整个方案尚未完成；整体PnR/位流继续停止。03:47账户额度剩余36%，到10%停止优化并交接。当前已推送检查点 `0586a64ff`；本小时证据将另行精确暂存提交，不能把未提交产物称为已上云。

- writer两拍入口流水：50组语义/范围/取消/延迟测试、20项集成回归通过，seed11/7区域时序均通过，slow setup分别+2.726/+2.419 ns。seed13正在运行。每帧启动多2拍，分段延迟多0拍。完整1080p控制/快照/显示模型仍在运行，未合入主设计；参考A时序失败，不计算加速比。
- 帧池16位计数分块：decongestion1有fast hold−0.001ns；仅改decongestion2后hold改善，但setup−0.333ns/14端点，仍失败。该结构不合入、不再扫seed。开始本轮最后一个结构候选8位分块，保留64位计数、原耗尽/代次规则；补测全部8位边界。20项回归通过，严格差分尚在运行，物理未启动。
- 帧池slot-local flags和writer仅算术A因时序失败拒绝，snapshot local capture无布线收益保留原版；原始结果与数据库已归档。
- 150MHz接口实验：写CDC四组异步时钟测试每组32场景通过；作业邮箱四组每组82作业通过。真实几何+读写CDC+native DDR模型三组测试通过，每组608256结果/保护区字节、三种增强模式。
- 双时钟整机小模型控制/快照通过：`verilator_20261020_034331_201913`。初次模型 `verilator_20261020_034204_198227` 失败已保留；测试从处理时钟返回后，控制提交未对齐DDR采样边沿。只修正激励时钟对齐、保留原身份/系数断言，新建快照重跑通过。
- 双时钟完整1080p控制/快照/实际显示模型 `verilator_20261020_034441_923014` 正在运行。生产PLL/125MHz/DDR PHY未改；150MHz目标尚缺原生映射、实际PLL/联合冷复位、CDC约束及完整服务期限验收，不能称为已实现。

当前唯一PDS为writer seed13；两个完整帧软件模型并行，不启动第二个PDS。实验目录 `fpga/experiments/proc150/` 不在生产RTL收集路径内。新模型闭包 `proc150_video_model_20261020_034322_763921` 位于 `fpga/build/route_optimization/`；所有未完成结果保持pending。

## 续接顺序

1. 先查真实账户额度、`native_phase.lock`和各运行的result/monitor，保持单PDS。writer三个seed已全部通过并合入；当前PDS为帧池8位计数候选的区域A/B，见其screen下最新regional_route。
2. 已合入的writer候选：`writer_span_pipeline_20261020_031048_641108`；完整模型`verilator_20261020_033308_185785`。三seed、全帧及主机原始字节/身份验证已全部通过并单文件合入，保留原始备份；不能整目录覆盖。两拍延迟须继续列入预算。
3. 帧池8位候选：`pool_chunk8_20261020_034402_468921`，20回归`sim_20261020_034431_720936`。严格差分终结后才可原生SYN/区域物理；这是本轮第二结构候选，不再加第三种。
4. 150MHz实验继续核对：`proc150_job_cdc_20261020_033751_467884`、`proc150_geometry_20261020_034010_472654`及上述模型。`probe_processing_domain_mapping.py`为SYN-only入口，尚未运行。不得把实验模型复制进主设计冒充板级接入；需要真实PLL/全局时钟网、联合冷复位、保持总线端点约束、资源预算和全帧deadline证明。
5. 最终组成版本重新跑必要回归/全帧/主机解码和输入绑定；可做整体SYN/MAP，不能整体PnR。满足功能、精度、同帧身份、服务期限、实际约束与资源预算后报告设计阶段结果。

## 监督、额度与Git

- watcher `optimization_status.py --session fpga/build/route_optimization/session_20261019 --watch` 每30秒观察真实Codex账户额度，10%写入整体及区域停止文件。不是上下文token额度；新鲜程度见`quota_observations.jsonl`。停止优化后保存进度、交接、提交和推送。
- 区域用`regional_stop_requested.json`，不得删除整体停止文件。显式分阶段预算prepare/PnR/STA为20/20/2分钟；有合格参考时PnR按2T+300秒与上限较小值。历史旧总流程预算不改写。TIMEOUT/STALLED不算成功，不承诺从最后路由迭代精确续跑。
- 只停止拥有的PID树，不按进程名杀PDS。原始参考及`E:\PDS_Pangu\PDS_2022.2-SP6.4\doc`只读，厂商专有模型不复制到公开Git。
- 每小时已汇报至03:48；下一次04:48。最近已推送`0586a64ff`，本次新增证明以随后commit/push核对为准。
- 初始存在212项tracked修改和大量产物，见`initial_git_status.txt`。必须精确scope暂存，禁止`git add .`，不增加忽略规则、不夹带无关修改。
- 冻结ZIP含逐成员SHA/PCF/原生依赖，不能覆盖；旧pending选择保留原字节，新终结另记。可变进度/交接以各Git提交字节为准。用`audit_staged_checkpoint.py <manifest>`核对工作树与暂存区每项哈希。
- 推送单次参数：`-c http.proxy=http://127.0.0.1:7897 -c http.sslBackend=openssl -c http.version=HTTP/1.1 -c http.postBuffer=104857600`；TLS偶发EOF可重试，不关闭证书检查/改全局设置。
- GUI曾遗留空`.git/index.lock`。只有确认原持有者退出、锁老化且当前进程均非持有者才清理，并保存审计，不能删除活动锁。

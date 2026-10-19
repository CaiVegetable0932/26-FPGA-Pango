# FPGA 布线专项优化交接

更新时间：2026-10-20 03:35，北京时间。整个优化方案未完成；主设计的现有 12 项修改已通过完整功能验证。禁止整体布线和完整位流生成。

## 项目与授权

- 项目地址：`D:\XDU\concept\26-FPGA-Pango`
- Git 分支：`codex/fpga-pds-project`
- 云端：<https://github.com/CaiVegetable0932/26-FPGA-Pango>
- 原方案：`output/FPGA布线效率与拥塞专项优化方案.md`
- 连续进度：`fpga/reports/route_optimization_progress_20261019.md`
- 区域矩阵：`fpga/reports/regional_verification_plan_20261019.md`
- 本会话：`fpga/build/route_optimization/session_20261019`

用户允许隔离模块/子系统的综合和区域布线验证。整个设计完成前不得整体 PnR 或生成位流；设计仿真通过后通知用户，由用户安排其他智能体监控整体布线。本轮没有启动子智能体或下载硬件。

原整机任务已于 10 月 19 日 21:46 停止，停止文件保留，未恢复。`fpga/config/implementation_readiness.json` 的全部整体放行条件仍关闭，不能为运行而改成 true；常用整体构建、恢复、bitgen 和便携 full/route 入口均有门槛。历史便携包不是本轮实现入口，不得用旧 runner 绕开监督。

## 当前主设计

主设计为 writer BRAM 等基线 11 项，加 unpack 局部捕获一项，共 12 项选定修改。分组 DMA、boot 捕获以及后续 DMA 实验均未留在主设计。

| 已完成证明 | 路径/结果 |
| --- | --- |
| 20 项集成回归 | `fpga/build/full_integration_20261013/sim_20261020_001153_047628`，PASS |
| 完整 1080p 控制/同帧快照/实际显示模型 | `verilator_20261020_001232_095496`，PASS；同属上述 build 根目录 |
| 显示逐像素检查 | 22,809,600 像素，失败 0、下溢 0，3 新帧/8 重复帧 |
| 几何作业周期 | 4,073,517 / 3,796,435 / 4,114,261，与基线相同 |
| 实际主机解码器离线校验 | `host/reports/fpga_rgb_vectors_20261020_003432_815058.json`，8,888 报文、12,441,600 图像字节，PASS |
| 输入绑定 | `session_20261019/unpack_finalist/sources.json`：290 项主设计输入与测试快照一致；HEAD 逐项核对无不同/缺失，见 `head_source_coherence_20261020.json` |
| 单文件合入记录 | `session_20261019/unpack_promotion_20261020/promotion.json`，只替换 unpack，保留 before 文件 |

00:35 已通知用户主设计完整功能仿真通过。它不是整个方案完成、150 MHz、板级时序或硬件验收结论。历史 Icarus 全帧补充场景 `sim_20261019_214646_986066` 为 TIMEOUT，不能改称 PASS。

现有处理/DDR/MAC 真实时钟为 125 MHz。六份生产约束及 186 项 DDR IP 输入与原基线哈希一致，官方 PHY 未修改。150 MHz 仍未实现或签核；独立处理域/CDC 的范围问题曾询问用户，尚无答复，不假定已同意延期或已完成。最坏几何模型仅剩约 52,405 周期/1.26% 服务余量，不能推断任意变换或硬件都满足期限。

## 已终结区域结果

下列实验均在 `fpga/build/route_optimization/`，不是整机物理签核。每个历史 case 的 budget_mode、引脚及时钟必须保持原记录。

| 对象 | 处置与证据 |
| --- | --- |
| unpack 实际 RGB reader | seed 11/7/13 两侧均布通且内部 STA 通过；PnR 44/45/44→36/38/39 秒，中位改善 13.64%，未达 30% 建议目标。经完整功能/字节证明后单文件合入，不推断整机收益 |
| writer BRAM | 保留已选基线。实际 ISP 常量连接两侧 STA 通过，PnR 49→48 秒，无显著时间收益；线长 16853→18376。通用动态参数两侧 STA 失败，关键路径在 span_end 合法性乘加，不能用 ISP 结果替代动态几何验证 |
| 第一轮 grouped DMA / boot | 已回退。DMA 停滞；boot 初筛未见收益，但自动引脚不同，不能将差异全部归因于结构 |
| 第二轮 DMA 局部等待统计 | 固定引脚候选 STALLED，最优剩余 1430；参考布通但 STA 未过，未合入 |
| 第三轮局部游标 A / A 加统计 B | A 两侧旧总流程预算超时；B 布通但 setup −0.482 ns、hold −0.029 ns。均不合入，见 `session_20261019/dma_round3_terminal_review_20261020.json` |
| 第四轮仅统计局部化 | 10 组差分、12 组参数、20 项回归、完整帧模型、主机解码、原始字节一致性全过。综合 LUT 3950→3584、FF 1508/DRM 28 不变，控制集 51→57。seed 11 PnR 291 秒且 setup +0.140/hold +0.122 ns；seed 7 在 PnR 840 秒 STALLED、最优剩余 1487。稳定性不通过，未合入，不再跑 seed 13，不计算加速比 |

第四轮 DMA 根目录 `dma_stats_only_20261020_013741_777089`，终结记录 `terminal_review_20261020.json`；全帧模型 `fpga/build/full_integration_20261013/verilator_20261020_020619_078621` 已通过，主机报告 `host/reports/fpga_rgb_vectors_20261020_022902_768761.json` 已通过。模型与主设计原始 datagrams/descriptor 哈希相同。历史 `finalist_selection_20261020.json` 保留 pending 原字节，以另列终结记录为准。


## 2026-10-20 03:35 当前状态

整个方案尚未完成；主设计仍为已经过完整功能验证的 12 项修改，没有合入以下实验。账户额度最近读数剩余 37%，10% 停止机制继续运行。整体 PnR / 位流门槛保持关闭。区域时钟统一 8 ns，不能据此宣称 150 MHz 或板级签核。

| 区域方案 | 最新证据与决策 |
| --- | --- |
| 帧池 slot-local flags | seed11 两侧完成；setup −0.450→−0.687 ns，候选时序失败，不合入，终止该候选 |
| snapshot-copy local capture | 两侧时序通过；PnR 37→38 秒、线长 10539→11165，无布线收益，保留原设计 |
| writer 完整 signed 乘积 A | 413798 次算术检查、31 组差分、20 项回归通过；APM 6→3，setup −7.796→−1.649 ns，仍失败，不单独合入 |
| 帧池 16 位分块完整 64 位计数器 | 11 组差分含 16/32/48 位进位与 64 位耗尽、20 项回归通过；256 个计数 FF 从 CE 改为连续更新，控制集 25→21。区域 slow setup +0.166 ns，但 fast hold −0.001 ns；不合入、不忽略违例。正在仅改变 decongestion 1→2 复核，RTL/引脚/seed11/8ns不变 |
| writer 两拍入口流水 B | 50 组独立字节记分板/范围/取消/延迟测试及20项集成回归通过。每帧入口多2拍，分段多0拍；不是逐周期等价。seed11 区域全角时序通过，slow setup +2.726 / slow hold +0.163 / fast hold +0.116 ns，线长22112。完整1080p控制/快照/显示模型正在运行，未合入；尚需有限seed7/13稳定性验证 |
| 独立150 MHz处理域 write CDC 原型 | 位于 `fpga/experiments/proc150/`，未实例化到生产工程。四组异步时钟/相位测试全部通过，每组32场景，覆盖数据/掩码、背压、取消、错误、复位。未做原生映射、CDC静态检查或整机吞吐验收，不能当作150MHz目标已实现 |

主要路径均相对于项目根目录：

- `fpga/build/route_optimization/session_20261019/control_writer_terminal_review_0323.json`：前三项物理终结结果。
- `fpga/build/route_optimization/pool_chunk16_20261020_025740_906990`：计数器候选及证明；screen `pool_unit_screen_20261020_030600_250387`。
- `fpga/build/route_optimization/writer_span_pipeline_20261020_031048_641108`：两拍 writer 候选290项输入、原始备份及语义证明。
- `fpga/build/route_optimization/writer_candidate_screen_20261020_032507_179978/unit_screen/regional_route_20261020_032713_550985`：writer B seed11物理结果。A参考输入、wrapper、引脚/时钟一致性见 screen 的 `physical_reference_reuse_20261020.json`；参考时序失败，不计算加速比。
- `fpga/build/full_integration_20261013/verilator_20261020_033308_185785`：writer B完整帧模型，03:35仍在运行，不计PASS。
- `fpga/build/route_optimization/proc150_write_cdc_20261020_031859_818696`：CDC原型独立测试。

续接先核对 quota / native_phase.lock / 活动进程，严格单个 PDS。当前唯一PDS是帧池 decongestion=2区域候选，writer完整帧模型可并行。计数器若通过，才做有限稳定性复验；writer也须完整帧和主机原始字节验证后才可单文件合入。已冻结ZIP/manifest不能覆盖；新检查点 `checkpoint_0335_manifest.json` 只归档已终结运行，活动任务排除。

处理域150MHz尚缺job CDC、联合复位/PLL接入、约束、全帧服务期限和资源验收，按原方案继续设计；生产DDR PHY和125MHz真实时钟保持原配置。不能以孤立桥接器通过代替整机设计完成。完成设计/仿真后通知用户，由用户安排其他智能体监控整体布线。

## 续接顺序

1. 读取当前帧池区域 `result.json`/各阶段 monitor，等两侧终结；保存成功/超时/停滞和内部 STA，不延长活动预算。
2. 串行验证 snapshot-copy 与 writer 的区域 A/B。示例：`python fpga/scripts/probe_regional_route.py --screen <上表screen> --phase-budgets --pause-file fpga/build/route_optimization/session_20261019/regional_stop_requested.json`。仅对值得保留的候选用固定 seed 11/7/13 复验；不要扫 seed 或因失败盲重跑。
3. 只将合格单文件差异组合到干净主设计快照，绝不整目录覆盖。重新跑组成版本的必要回归、全帧功能、主机解码及输入绑定，之后才考虑逐文件合入。控制实验 source 不含其他后续候选，不能混用旧模型冒充新组合通过。
4. 最终选定后可跑整机 SYN/MAP：`build_video_system.py --stage dev_map`，不得整体 PnR。旧 11 项 MAP 为 LUT 41341、FF 40430、APM 117、DRM 98，不是当前 12 项或未来组合的实测预算。
5. 处理时钟目标、未完成区域、资源/外部约束/CDC 与最终功能证明都有明确结论后，通知用户设计阶段结果并交接；整体布线由用户安排监控。150 MHz、完整 routed/STA、硬件 1080p30 尚未验收。

保持真实 1080p30、位精度、同帧身份与原图/全部生产功能。不修改官方 DDR PHY，不扩大 false path，不以降频、删掩码或关闭功能换取成绩。`E:\PDS_Pangu\PDS_2022.2-SP6.4\doc` 和原始 reference 只读；厂商模型只引用安装路径，不把专有明文复制到公开 Git。

## 停止、额度与 Git

- 02:39 最近账户额度剩余 38%，以 `session_20261019/quota_observations.jsonl` 的真实事件为准；不是上下文 token 百分比。到 10% 停止新增优化，保存进度/交接并提交推送。watcher 正在运行，写入整体和区域停止文件；监督器每 30 秒检查。
- 整体 `stop_requested.json` 保留；区域 `regional_stop_requested.json`。已有停止标记会阻止进程创建。不得删除整体停止文件来运行区域实验。
- 旧区域模式整个 compile/SYN/MAP/PnR/STA 共 20 分钟，原记录不变。显式 `--phase-budgets` 分别限制准备/PnR/STA 为 20/20/2 分钟，PnR 有合格参考时按原自适应公式收紧。不能混算预算模式或补签旧失败。
- 互斥锁 `fpga/build/route_optimization/native_phase.lock`；只清理自己拥有的 PID 树，不按进程名结束 PDS。超时没有保存内存布线状态，只有检查点，不能承诺从最后轮次精确续跑。
- 01:48 已按小时汇报，下一次约 02:48。进度文件持续更新；可运行 `optimization_status.py --session fpga/build/route_optimization/session_20261019` 读状态。
- 最近已推送 `dd78f8fd`；主设计完整功能合入点为 `20f5269f`，之后只有诊断/实验/文档。后续提交以 `git log`/远端核对为准。
- 初始有 212 项 tracked 修改及大量构建文件，见 `initial_git_status.txt`。按本轮明确 scope 暂存，禁止 `git add .`，不新增忽略项，不夹带 MCU 或无关改动。
- 冻结证据 manifest 以相应提交内的字节为准，mutable 交接/进度文档后续可更新；测试输入、历史 pending、ZIP 和原始结果不覆盖。native ZIP 带逐成员 SHA-256，并包含 PCF 与映射/布线依赖。早期 PCF 补充另列，不回写旧 ZIP。
- 推送采用单次代理 `-c http.proxy=http://127.0.0.1:7897 -c http.sslBackend=openssl -c http.version=HTTP/1.1`，必要时带 `-c http.postBuffer=104857600`，未关闭证书检查或更改全局配置。
- GUI 只读 Git diff 曾留下空索引锁；只有核对原持有者已退出、锁已老化且当前 Git 都是更晚的只读进程后才清理。不得删除活动锁；既有核查记录留存。

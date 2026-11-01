# GH2 外部计算机布线与监控交接

本轮交付 GH2 组合版，供另一台 Windows 计算机进行一次有界的完整布局布线及布线后 min/max STA。用户已授权提交云端并交给外机启动，无 GUI 审批要求。**GH2 已通过功能、SYN、MAP 和实际网表审核，但尚未进行 PnR；不能称为已布通或实板可用。**

本轮从 GH2 的新 MAP 重新布局并布线，**没有 PLC 输入，不恢复 DE 的十小时布线进度**。不得混入 DE、gray_optimized 或其他版本的 PLC/MAP。外机原 DE 任务与包保持独立；若它仍占用同一台机器，先处理该任务的真实终结与资源占用，不并发启动第二份 PDS。

## 交付身份与取用方式

云分支：`codex/gray-gh2-portable-20261101`。准确云端提交 SHA 由本轮最终交付回执给出；按回执核对，不能只凭分支名判断版本。ZIP 哈希读取发布后的同名 `.zip.sha256` 文件，包内 manifest 绑定源、数据库和工具。本说明不写入自身 ZIP 或提交 SHA，避免自引用。

- ZIP：`fpga/release/packages/gray_GH2_portable_20261101.zip`。
- ZIP 哈希：`fpga/release/packages/gray_GH2_portable_20261101.zip.sha256`。
- 发布清单：`fpga/release/gray_GH2_20261101/manifest.json`。
- 包内交接说明：`fpga/release/gray_GH2_20261101/README_交接.md`。
- 固定输入：同目录 `inputs/`；原始验证证据：同目录 `evidence/`。
- 本文中的路径均相对于解压包或该云分支的仓库根目录。建议使用全新、简短 ASCII 路径；完成 prepare 后不能移动目录。
- 任选 ZIP 或该云端提交，完整取得同一份工具、manifest、源与数据库。不要将工具覆盖到旧 DE 解压目录，也不要从主分支临时拼装文件。
- 云分支的主设计源码对应本次 GH2 验证字节；源机工作区 live 仍保持 DE。外机实际 PnR 输入由发布 manifest 的 `inputs` 绑定，不能把源机 live 当作 GH2 输入。

已固定的逻辑身份如下，包内离线 audit 会核对对应文件：

| 项目 | 精确身份 / SHA256 |
|---|---|
| 327 项源码清单 | `65f8ad8e8fa86b5169c15d3ec3b0549a6ba938ce0544099515c1d3f1d564333f` |
| 功能审核 | `b2b3e35a78c0532e479799a5d4bbf165d4f588234012b566b76ab17bb775390e` |
| 最终独立审核 | `66e8059e0244d2878dd58f945935e1c217684ab8e56f361e13151feec3c180be` |
| SYN ADF | `2a2384defad6a84ca3b274e1e9b5ccbf73eb2841f220814b79c47d663ed2e0dc` |
| MAP ADF | `ed57025f121c21140e04df1ba4fa06e298bdc3065e23a5376c6ae97219fa9e3d` |
| 原始 SYN | `board_20261101_103105_502401` |
| 原始 MAP | `board_postsyn_20261101_124125_148426` |

原证据里的源机绝对路径仅表示历史出处；目标机输入与运行路径以发布 manifest 和新 dispatch 为准。旧 `native/state.json` 的 `SYN_GATE_NEEDS_REVIEW` 是保留的历史停审，随后已补证并完成 MAP，**不要再次运行 evaluate_gh2_candidate.py/evaluate_gh2_map_only.py 或旧启动器**。

## 已完成的验证及其边界

GH2 相对 DE 仅改变 `frame_parameter_bank.sv`、`dma_write_cdc.sv` 和 `processing_cdc.fdc` 三文件。G 将参数 bank 使能局部化；H2 把结果写 CDC 读口实现为拥有事务时才使能的同步 SDP RAM，只退役已消失的两条 read_q 首跳例外。原始 pitch/yaw FPGA 解算、帧所有权、DDR 写完成、参数排空、完整旧帧保持及复位/握手 CDC 均保留。

新组合完整 1080p 仿真 `verilator_20261101_101757_763943` 已通过：3 个新帧、5 次重复帧、16588800 像素、0 欠流，以及更新排空和旧帧保护。G 的双宽度 80048 次检查、H2 的 538 场景/3199 beat/180 次立即复用与消费者专项按精确依赖复用；没有把它们说成组合后新跑的视频以外测试，也没有用视频顶层代替 UART/solver 专项。

同一份真实 GH2 SYN VM 已确认：4×72 bit SDP DRM、288 位输出、processing/DDR 双时钟、M_LOAD/M_SEND 所有权读使能、无原 word0/read_q fabric FF；1721344 组合法状态/输入转换审核通过，5 项故障注入均被拒绝。四组参数 CE 为 19/24/11/15 支，每支 CE 端点不超过 32；reference 一支加其他消费者总负载为 34，不能称全局 fanout≤32。

| MAP 资源 | DE | GH2 | GH2 对 DE |
|---|---:|---:|---:|
| LUT | 37592 | 37334 | −258 |
| FF | 41960 | 41380 | −580 |
| APM | 154 | 154 | 0 |
| DRM | 71.5 | 75.5 | +4 |
| 分布式 RAM | 1275 | 1131 | −144 |

SYN/MAP 均原生 exit0；MAP 耗时 300.640 秒。10 条 post-SYN SCF 实际加载，CCR 为零错误和 33 条既有 share-pin 诊断，MAP 无新增诊断。processing setup **综合估计**为 +0.787 ns，DDR 为 +0.094 ns；这些数值及资源减少不证明物理收敛。

现有 DDR 同域、OSERDES、DQS gate、复位 hold/removal 风险，以及 53 个输入、94 个输出未约束端口诊断仍保留。未约束诊断一致只表示本版没有扩大范围，并不等于外部时序已签核。原始最终审核：`fpga/build/gh2_integration_20261101/final_review_20261101/final_review.json`，发布包保留其副本。

## 目标机环境与一次启动

使用 **PDS 2022.2-SP6.4 build 146967**，目标器件 **Logos2 / PG2L100H / -6 / FBG676**，板卡是 PG2L100H MINI。需要 Python 3.12 与 psutil；需能读取 CIM 进程命令行和创建时间。安装路径可以不同，prepare 显式指定该机安装根目录并核验目标器件的原生命令帮助。

不要换用 PDS2025、PG2L200H 或 100Pro。已确认 2025.2 build211867 对本设计 100H HDMI 3.3V/TMDS 电气规则不兼容；不能改为 2.5V/LVDS、删除约束或使用 ignore-db-version 绕过。

在包/云端仓库根目录按顺序执行，**每一步退出码必须为 0，失败即停**：

```powershell
python -X utf8 -B fpga/scripts/portable_gh2.py --audit
python -X utf8 -B fpga/scripts/portable_gh2.py --prepare --pds-root E:/PDS_Pangu/PDS_2022.2-SP6.4
python -X utf8 -B fpga/scripts/portable_gh2.py --run
```

`--audit` 是离线完整性检查。`--prepare` 只做迁移、安装版帮助探针及预检，不开始布局布线；准确安装路径由目标机提供。`--run` 消费一次 dispatch，运行新布局/PnR，布通后继续真实 min/max STA，停在时序审核之后。后台执行时使用隐藏窗口并保存启动/退出证据，不弹 GUI；不能因命令暂时没有返回而再次运行。

若 `dispatch.json`、readiness 或一次性 claim 已存在，先检查其状态；不要删除记录重试、重跑 prepare、复用旧 scope 或修改运行中源码。任意错误先保留原日志和失败状态，不自行重综合、重 MAP 或改参数。

## 本轮参数与时间边界

首轮保持 DE 已用参数口径，以评估 GH2 结构改动的实际效果：

| 参数 | 本轮值 |
|---|---|
| 起点 | 精确 GH2 MAP，新布局；无 `input_place_db_file` |
| 模式 / seed / decongestion | normal / 7 / 2 |
| control chain / congest overlap | 500 / 200 |
| planning before place | TRUE |
| cell duplication | enabled |
| logic optimize / LUT6D strategy | enabled / 3 |
| pin cost increasing speed | 不额外传参，保持该工具版本原生默认 300 |
| 拥塞输出 | 开启逐轮 plot 与 net 信息 |
| 原生 PnR / 主机每阶段上限 | 180 分钟 / 185 分钟 |

不同时叠加 chain256、新 seed 或拥塞代价试验。之后的单变量试验需本次真实终结和证据评估，不能复用已消费 dispatch。源码/时钟/约束不随参数试验放宽。

监督器每 30 秒记录一次。沿用既有停滞规则：完成热身后，取最近 5 次已完成迭代转换的起点与窗口内最佳未布通数；最佳值仍大于 1000 且相对改善小于 1% 时判停滞。该规则不是“每轮必须改善 1%”，也不能用末轮临时回升掩盖窗口内改善。接近收敛时保留硬时限，不使用该百分比门限。监督器可能在 180 分钟前按已绑定规则结束，属于有界试验的正常停止机制。

运行中的 `action_timeout` 已提交，改磁盘 policy/Tcl 不会热更新当前预算。不自动延时、重启或取消停止规则；达到日历时间也不能单独证明进程已退出。

## 外部智能体监控入口

唯一指针是 `fpga/build/portable_gh2/dispatch.json`，其中的 `build` 和运行后 `resume` 指向本轮精确工程和证据目录；scope 位于 `fpga/build/portable_gh2/readiness.json`。禁止按“最新目录”猜测。

每次只作一次有界核查：

1. 读取 dispatch、工程 `launch.log`/`launch_exit.json`；运行时记录 PID、创建时间、命令及父子关系。
2. 读取精确 resume 的 `place_route_monitor.jsonl`、`place_route.log`、`result.json`；同时核查工程 `place_route/run.log`。进入 STA 后改看同次 resume 的 `report_timing_monitor.jsonl`、`report_timing.log` 与工程 `report_timing/`。
3. 记录阶段、已完成轮号、未布通子网数及其分母、单轮 CPU、最近 5 转换净改善、CPU/净清除、内存及日志更新时间。网/子网口径必须注明，不能混用。
4. 健康运行且无重要变化时保持静默，不长轮询。仅在阶段重要变化、结束、失败或需要用户动作时通知；若使用定时监控，终结报告完成后删除该跟进。

**根目录 result.json 故意保留输入 MAP 结果。** PnR 是否结束必须结合本次 resume 结果、launcher 退出、可见权限 CIM 进程身份、`native_phase.lock` 释放及本轮 scope 关闭；受限环境中空列表/命令不可见不等于退出。日志暂时没有增长不等于死锁，须结合 CPU 与实际阶段。`COMPLETE_REQUIRES_PHYSICAL_REVIEW` 或 `PNR_STA_COMPLETE_INDEPENDENT_REVIEW_REQUIRED` 仅表示进入独立物理审核，不能当作最终签核。

正常任务不人为干预。用户明确要求停止时，核准 dispatch 对应的 `build/stop_requested.json` 交给既有监督器，只停止它拥有的进程树；不得按 `pds` 名称批量杀进程或误停外机 DE。已触发暂停、超时或停滞后不能自动第二次启动。

## 终结审核与回传材料

布通的最低证据是本次未布通子网为 0、完整非空 PRR、正确器件及合法实际资源、真实 `_pnr.adf`。随后须有原生成功的 `report_timing` 和 min/max RTR，检查全部时钟组/时钟对、setup/hold/recovery/removal/pulse width 与未约束路径。特别核查 DDR 同域、OSERDES 输入、DQS gate 和复位路径，不能仅摘 processing 的正余量。

重新核对 10 条 post-SYN SCF、33 条既有 share-pin 的具体对象、camera ready_sync/active→paused_meta 首跳例外及后级普通时序、其余握手 CDC、RAM 写口/读地址/CE 和 RAM→DDR 消费者普通 setup/hold。新告警、丢失约束、空匹配、未约束范围变化单独列出；不能加整 RAM/整模块 false path、降低时钟或删约束掩盖失败。`All Constraints Met` 也不能替代未约束端口与例外范围审阅。

若超时或停滞失败，报告最后完成轮与未完成轮，保留近 5 转换的起点、最佳值和末值、绝对剩余、单轮 CPU 及 CPU/净清除（净改善≤0时写“不适用”），同时保存全量 `CongestionNetInfo_*`/`CongestionPlot_*`、模块热点和空间热点。低全局拥塞或 backward bucket 走势只能支持诊断，不能独自证明 rip-up 死循环或保证加时会收敛。新 PLC 只是这次布局产物；从 PLC 重路由不等于续接中断迭代。

回传以下原始文件及 SHA256 清单：发布 manifest 与安装帮助、dispatch/readiness、launch/exit、完整 resume、flow Tcl、PRR、PLC/PNR 数据库（实际存在才列出）、全部 STA/RTR、完整拥塞输出与 run.log。总结中区分“布线通过”“内部时序通过”“外部时序待审”和“硬件未测”。

**本次不生成位流、不下载、不烧录，不自动提交/推送新的设计或启动下一轮。** 审核未通过时写明确阻塞项；通过时交付真实 routed DB/STA 和结果，不再为了等待其他候选而重新布线。

## 参考与审查记录

官方来源：源机只读 `E:/PDS_Pangu/PDS_2022.2-SP6.4/doc/Pango_Design_Suite_User_Guide.pdf`，PDF 第 112 页说明 action_timeout 单位为分钟，第 253 页列出 PnR 参数，第 255 页列出 report_timing。具体器件可用选项仍须由目标机已安装 build146967 的帮助探针核实。

源机独立发布前核对：`fpga/build/gh2_release_preparation_20261101/independent_review/source_evidence_review.json`。原始 70 项最终证据哈希与 327 项源码/SYN/MAP 一致，实际资源/10SCF/CCR33 已复核；包/云端完整性另由最终发布回执和目标机 `--audit` 证明。
